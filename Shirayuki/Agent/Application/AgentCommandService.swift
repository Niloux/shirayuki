import Foundation
import Combine


struct AgentPageCapabilityRegistry {
    private struct PendingCapability {
        let nonce: String
        let turnID: String
        let contextFingerprint: String
        let providerKey: String
        let expiresAt: Date
    }

    private var pending: [String: PendingCapability] = [:]
    private var consumedNonces = Set<String>()

    mutating func issue(_ capability: AgentPageCapability, expiresAt: Date) {
        consumedNonces.remove(capability.nonce)
        pending[capability.nonce] = PendingCapability(
            nonce: capability.nonce,
            turnID: capability.turnID,
            contextFingerprint: capability.contextFingerprint,
            providerKey: capability.providerKey,
            expiresAt: expiresAt
        )
    }

    /// Atomically consumes a capability only when every live context field matches.
    @discardableResult
    mutating func consume(
        _ capability: AgentPageCapability,
        currentFingerprint: String,
        currentProviderKey: String,
        now: Date = Date()
    ) -> Bool {
        guard !consumedNonces.contains(capability.nonce),
              let stored = pending[capability.nonce],
              stored.turnID == capability.turnID,
              stored.contextFingerprint == capability.contextFingerprint,
              stored.providerKey == capability.providerKey,
              stored.contextFingerprint == currentFingerprint,
              stored.providerKey == currentProviderKey,
              stored.expiresAt > now else {
            return false
        }
        consumedNonces.insert(capability.nonce)
        return true
    }
}

/// Executes only typed, redacted Agent commands and keeps provider reads on demand.
@MainActor
final class AgentCommandService {

    private struct KnownCommentRecord {
        let comicID: String
        let parentID: String?
        let excerpt: String
        let isHidden: Bool
    }

    private struct CommentMutationCacheEntry {
        let comicID: String
        let mutation: CommentMutation
    }

    private struct SessionState {
        var knownComicIDs = Set<String>()
        var localComicIDs = Set<String>()
        var knownChapterIDs: [String: Set<String>] = [:]
        var knownComments: [String: KnownCommentRecord] = [:]
        var knownCommentOrder: [String] = []
        var inFlightCommentCommandIDs = Set<String>()
        var authorizationEpoch = UUID()
        var capabilityRegistry = AgentPageCapabilityRegistry()
        var confirmedResults: [String: AgentCommandResult] = [:]
        var confirmedCommentPayloads: [String: CommentMutationCacheEntry] = [:]
    }

    private let navigation: AppNavigationCoordinator
    private let userProvider: any AgentUserProvider
    private let libraryProvider: any AgentLibraryProvider
    private let downloadProvider: any AgentDownloadProvider
    private let blockedWords: UserDefaultsBlockedWordRepository
    private let pageContent: AgentPageContentStore
    private let commentRepository: any CommentRepository
    private let chapterProvider: (String) async throws -> [PicaChapter]
    private let comicDetailProvider: (String) async throws -> ComicDetail
    private let deleteOfflineComicProvider: (String) async throws -> Void
    private weak var readerSurface: (any AgentReaderSurface)?
    private var activeSessionID = UUID()
    private var states: [UUID: SessionState] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let sessionIsLoggedIn: () -> Bool
    private let llmConfiguration: () -> LLMConfiguration?
    private let llmHasAPIKey: () -> Bool

    private let riskAuthorizationEnabled: () -> Bool
    private var knownComicIDs: Set<String> {
        get { states[activeSessionID, default: SessionState()].knownComicIDs }
        set { states[activeSessionID, default: SessionState()].knownComicIDs = newValue }
    }
    private var localComicIDs: Set<String> {
        get { states[activeSessionID, default: SessionState()].localComicIDs }
        set { states[activeSessionID, default: SessionState()].localComicIDs = newValue }
    }
    private var knownChapterIDs: [String: Set<String>] {
        get { states[activeSessionID, default: SessionState()].knownChapterIDs }
        set { states[activeSessionID, default: SessionState()].knownChapterIDs = newValue }
    }
    private var capabilityRegistry: AgentPageCapabilityRegistry {
        get { states[activeSessionID, default: SessionState()].capabilityRegistry }
        set { states[activeSessionID, default: SessionState()].capabilityRegistry = newValue }
    }
    private var confirmedResults: [String: AgentCommandResult] {
        get { states[activeSessionID, default: SessionState()].confirmedResults }
        set { states[activeSessionID, default: SessionState()].confirmedResults = newValue }
    }

    init(
        navigation: AppNavigationCoordinator? = nil,
        userProvider: any AgentUserProvider = DefaultAgentUserProvider(),
        libraryProvider: (any AgentLibraryProvider)? = nil,
        downloadProvider: any AgentDownloadProvider = DefaultAgentDownloadProvider(),
        blockedWords: UserDefaultsBlockedWordRepository? = nil,
        pageContent: AgentPageContentStore? = nil,
        commentRepository: any CommentRepository = PicaCommentRepository(),
        sessionIsLoggedIn: @escaping () -> Bool,
        llmConfiguration: @escaping () -> LLMConfiguration? = { nil },
        llmHasAPIKey: @escaping () -> Bool = { false },
        riskAuthorizationEnabled: @escaping () -> Bool = { true },
        chapterProvider: ((String) async throws -> [PicaChapter])? = nil,
        comicDetailProvider: ((String) async throws -> ComicDetail)? = nil,
        deleteOfflineComicProvider: ((String) async throws -> Void)? = nil
    ) {
        let blockedWords = blockedWords ?? UserDefaultsBlockedWordRepository()
        self.navigation = navigation ?? AppNavigationCoordinator.shared
        self.userProvider = userProvider
        self.libraryProvider = libraryProvider ?? DefaultAgentLibraryProvider(blockedWords: blockedWords)
        self.downloadProvider = downloadProvider
        self.blockedWords = blockedWords
        self.pageContent = pageContent ?? AgentPageContentStore()
        self.commentRepository = commentRepository
        self.chapterProvider = chapterProvider ?? { id in
            try await PicaAPIService.shared.fetchChapters(id: id)
        }
        self.comicDetailProvider = comicDetailProvider ?? { id in
            try await PicaAPIService.shared.fetchComicDetail(id: id)
        }
        self.deleteOfflineComicProvider = deleteOfflineComicProvider ?? { comicID in
            try await OfflineComicStore.shared.delete(comicID: comicID)
        }
        self.sessionIsLoggedIn = sessionIsLoggedIn
        self.llmConfiguration = llmConfiguration
        self.llmHasAPIKey = llmHasAPIKey
        self.riskAuthorizationEnabled = riskAuthorizationEnabled
        blockedWords.$currentSnapshot.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            for id in self.states.keys {
                self.states[id]?.knownComicIDs.removeAll()
                self.states[id]?.knownChapterIDs.removeAll()
                self.states[id]?.knownComments.removeAll()
                self.states[id]?.knownCommentOrder.removeAll()
                self.states[id]?.confirmedResults.removeAll()
                self.states[id]?.confirmedCommentPayloads.removeAll()
                self.states[id]?.inFlightCommentCommandIDs.removeAll()
                self.states[id]?.authorizationEpoch = UUID()
            }
        }.store(in: &cancellables)
    }

    func registerReaderSurface(_ surface: any AgentReaderSurface) {
        readerSurface = surface
    }

    func unregisterReaderSurface(_ surface: any AgentReaderSurface) {
        guard readerSurface === surface else { return }
        readerSurface = nil
    }

    /// Called only after the user confirms current-page sharing for this turn.
    func issuePageCapability(sessionID: UUID, turnID: String) -> AgentPageCapability? {
        activeSessionID = sessionID
        guard let reader = readerSurface else { return nil }
        let snapshot = reader.agentReaderSnapshot
        guard snapshot.pageContentAvailable,
              let chapterID = snapshot.chapterID else { return nil }
        let fingerprint = "\(snapshot.comicID)|\(chapterID)|\(snapshot.pageIndex)"
        let providerKey = currentProviderKey
        let capability = AgentPageCapability(
            turnID: turnID,
            nonce: UUID().uuidString,
            contextFingerprint: fingerprint,
            providerKey: providerKey
        )
        capabilityRegistry.issue(
            capability,
            expiresAt: Date().addingTimeInterval(60)
        )
        return capability
    }
    private var currentProviderKey: String {
        guard let configuration = llmConfiguration() else { return "unconfigured" }
        return "\(configuration.provider.rawValue)|\(configuration.baseURL.host?.lowercased() ?? "")|\(configuration.baseURL.port ?? 443)"
    }
 
    func currentPageConfirmationPreview() -> AgentConfirmationPreview? {
        guard let reader = readerSurface,
              reader.agentReaderSnapshot.pageContentAvailable,
              reader.agentReaderSnapshot.chapterID != nil,
              let configuration = llmConfiguration(),
              let host = configuration.baseURL.host,
              !host.isEmpty else {
            return nil
        }
        let port = configuration.baseURL.port
        let displayHost = if let port, port != 443 {
            "\(host):\(port)"
        } else {
            host
        }
        return .currentPage(providerHost: displayHost)
    }


    func execute(
        _ command: AgentCommand,
        sessionID: UUID,
        capability: AgentPageCapability? = nil,
        confirmed: Bool = false,
        turnID: String? = nil
    ) async -> AgentCommandResult {
        activeSessionID = sessionID
        if Self.requiresRiskAuthorization(command), !riskAuthorizationEnabled() {
            return .failure(.riskAuthorizationRequired)
        }
        if case .mutateComment = command, !sessionIsLoggedIn() {
            return .loginRequired
        }
        if let commandID = commandID(for: command),
           let previous = states[sessionID]?.confirmedResults[commandID] {
            if case let .mutateComment(comicID, mutation, _) = command {
                guard let payload = states[sessionID]?.confirmedCommentPayloads[commandID],
                      payload.comicID == comicID,
                      payload.mutation == mutation,
                      validCommentMutationInput(comicID: comicID, mutation: mutation, commandID: commandID),
                      isAuthorizedCommentMutation(comicID: comicID, mutation: mutation, sessionID: sessionID) else {
                    return .failure(.invalidIdentifier)
                }
            }
            return previous
        }
        if states[sessionID] == nil {
            states[sessionID] = SessionState()
        }

        let result: AgentCommandResult
        switch command {
        case .currentContext:
            result = .context(baseSnapshot())
        case .currentUser:
            guard sessionIsLoggedIn() else { result = .loginRequired; break }
            do {
                result = .user(try await userProvider.currentUser())
            } catch {
                result = .failure(.providerFailure)
            }
        case let .favoritePage(page, sort):
            guard sessionIsLoggedIn() else { result = .loginRequired; break }
            guard (1...100).contains(page) else { result = .failure(.invalidPage); break }
            do {
                let items = try await libraryProvider.favoritePage(page: page, sort: sort)
                items.forEach { knownComicIDs.insert($0.comicID) }
                result = .favorites(items: items, page: page, sort: sort)
            } catch let error as AgentCommandError {
                result = .failure(error)
            } catch {
                result = .failure(.providerFailure)
            }
        case .offlineLibrary:
            let library = await libraryProvider.offlineLibrary()
            let items = library.limitedItems
            items.forEach { localComicIDs.insert($0.comicID) }
            result = .offlineLibrary(
                items: items,
                totalCount: library.totalCount,
                storageBytes: library.storageBytes
            )
        case let .downloadStatus(jobID):
            do {
                if let jobID {
                    result = .downloadStatus([try await downloadProvider.snapshot(jobID: jobID)])
                } else {
                    result = .downloadStatus(await downloadProvider.activeDownloads())
                }
            } catch let error as AgentCommandError {
                result = .failure(error)
            } catch {
                result = .failure(.invalidIdentifier)
            }
        case let .search(keyword, sort):
            guard sessionIsLoggedIn() else { result = .loginRequired; break }
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 100 else { result = .failure(.invalidIdentifier); break }
            do {
                let response = try await PicaAPIService.shared.searchComics(keyword: trimmed, page: 1, sort: sort)
                let items = PicaAgentAdapters.searchItems(
                    response.docs,
                    snapshot: await blockedWords.snapshot()
                )
                items.forEach { knownComicIDs.insert($0.comicID) }
                result = .search(items)
            } catch {
                result = .failure(.providerFailure)
            }
        case let .openComic(comicID):
            guard sessionIsLoggedIn() else { result = .loginRequired; break }
            guard isAuthorizedComicID(comicID) else {
                result = .failure(.invalidIdentifier)
                break
            }
            navigation.routeToComic(comicID)
            result = .openedComic(comicID: comicID)
        case let .startReading(comicID, chapterID, pageIndex):
            guard sessionIsLoggedIn() else { result = .loginRequired; break }
            guard isAuthorizedComicID(comicID) else {
                result = .failure(.invalidIdentifier)
                break
            }
            guard pageIndex.map({ $0 >= 0 }) ?? true else {
                result = .failure(.invalidPage)
                break
            }
            if let chapterID {
                do {
                    guard try await chapterIDs(for: comicID).contains(chapterID) else {
                        result = .failure(.invalidIdentifier)
                        break
                    }
                } catch {
                    result = .failure(.providerFailure)
                    break
                }
            }
            navigation.routeToReader(comicID: comicID, chapterID: chapterID, pageIndex: pageIndex)
            result = .startedReading(comicID: comicID, chapterID: chapterID, pageIndex: pageIndex ?? 0)
        case let .goToReaderPage(index):
            guard sessionIsLoggedIn() else { result = .loginRequired; break }
            guard index >= 0 else { result = .failure(.invalidPage); break }
            guard let reader = readerSurface else { result = .failure(.contextUnavailable); break }
            reader.agentGoToPage(index)
            result = .readerUpdated(reader.agentReaderSnapshot)
        case let .goToReaderChapter(chapterID, pageIndex):
            guard sessionIsLoggedIn() else { result = .loginRequired; break }
            guard pageIndex.map({ $0 >= 0 }) ?? true else {
                result = .failure(.invalidPage)
                break
            }
            guard let reader = readerSurface else { result = .failure(.contextUnavailable); break }
            guard await reader.agentGoToChapter(id: chapterID, pageIndex: pageIndex) else {
                result = .failure(.invalidIdentifier)
                break
            }
            result = .readerUpdated(reader.agentReaderSnapshot)
        case .currentPageContent:
            guard sessionIsLoggedIn() else { result = .loginRequired; break }
            guard llmConfiguration() != nil, llmHasAPIKey() else {
                result = .configurationRequired
                break
            }
            guard let capability,
                  let turnID,
                  capability.turnID == turnID else {
                result = .capabilityRequired
                break
            }
            guard let reader = readerSurface else { result = .failure(.contextUnavailable); break }
            let snapshot = reader.agentReaderSnapshot
            let fingerprint = "\(snapshot.comicID)|\(snapshot.chapterID ?? "")|\(snapshot.pageIndex)"
            guard capabilityRegistry.consume(
                capability,
                currentFingerprint: fingerprint,
                currentProviderKey: currentProviderKey
            ) else {
                result = .capabilityRequired
                break
            }
            do {
                result = .pageContent(try await reader.agentCurrentPageData(capability: capability))
            } catch let error as AgentImageError {
                result = .failure(Self.mapImageError(error))
            } catch {
                result = .failure(.pageImageUnavailable)
            }
        case let .commentPage(comicID, parentID, page):
            result = await commentPage(
                comicID: comicID,
                parentID: parentID,
                page: page,
                sessionID: sessionID
            )
        case let .mutateComment(comicID, mutation, commandID):
            result = await mutateComment(
                comicID: comicID,
                mutation: mutation,
                commandID: commandID,
                sessionID: sessionID,
                confirmed: confirmed
            )
        case let .startDownload(comicID, chapterIDs, quality, _):
            guard sessionIsLoggedIn() else { result = .loginRequired; break }
            guard isAuthorizedComicID(comicID) else {
                result = .failure(.invalidIdentifier)
                break
            }
            if confirmed {
                result = await startDownload(comicID: comicID, chapterIDs: chapterIDs, quality: quality)
            } else {
                result = await downloadConfirmation(
                    comicID: comicID,
                    chapterIDs: chapterIDs,
                    quality: quality
                )
            }
        case let .cancelDownload(jobID, commandID):
            guard sessionIsLoggedIn() else { result = .loginRequired; break }
            if confirmed {
                do {
                    try await DownloadCoordinator.shared.cancel(jobID: jobID)
                    result = .cancelledDownload(jobID: jobID)
                    confirmedResults[commandID] = result
                } catch {
                    result = .failure(.invalidIdentifier)
                }
            } else {
                result = await cancellationConfirmation(jobID: jobID)
            }
        case let .deleteOfflineComic(comicID, _):
            guard sessionIsLoggedIn() else { result = .loginRequired; break }
            guard localComicIDs.contains(comicID) else {
                result = .failure(.invalidIdentifier)
                break
            }
            if confirmed {
                do {
                    try await deleteOfflineComicProvider(comicID)
                    localComicIDs.remove(comicID)
                    result = .deletedOfflineComic(comicID: comicID)
                } catch {
                    result = .failure(.providerFailure)
                }
            } else {
                let library = await libraryProvider.offlineLibrary()
                guard let item = library.items.first(where: { $0.comicID == comicID }) else {
                    result = .failure(.invalidIdentifier)
                    break
                }
                result = .requiresConfirmation(
                    .deleteOfflineComic(comicID: comicID, comicTitle: item.title)
                )
            }
        case let .setLiked(comicID, isLiked, commandID):
            result = await applyDesiredLike(
                comicID: comicID,
                desired: isLiked,
                commandID: commandID,
                confirmed: confirmed
            )
        case let .setFavorited(comicID, isFavorited, commandID):
            result = await applyDesiredFavorite(
                comicID: comicID,
                desired: isFavorited,
                commandID: commandID,
                confirmed: confirmed
            )
        case .listBlockedWords:
            result = .blockedWords(snapshot: await blockedWords.snapshot(), operation: nil)
        case let .addBlockedWord(word, _):
            result = await mutateBlockedWordAdd(word: word, confirmed: confirmed)
        case let .updateBlockedWord(oldWord, newWord, _):
            result = await mutateBlockedWordUpdate(
                oldWord: oldWord,
                newWord: newWord,
                confirmed: confirmed
            )
        case let .removeBlockedWord(word, _):
            result = await mutateBlockedWordRemove(word: word, confirmed: confirmed)
        case .listIncludedWords:
            result = .blockedWords(
                snapshot: await blockedWords.snapshot(),
                operation: "include_list"
            )
        case let .addIncludedWord(word, _):
            result = await mutateIncludedWordAdd(word: word, confirmed: confirmed)
        case let .updateIncludedWord(oldWord, newWord, _):
            result = await mutateIncludedWordUpdate(
                oldWord: oldWord,
                newWord: newWord,
                confirmed: confirmed
            )
        case let .removeIncludedWord(word, _):
            result = await mutateIncludedWordRemove(word: word, confirmed: confirmed)
        }
        if let commandID = commandID(for: command),
           confirmed,
           isSuccessfulSideEffect(result),
           var state = states[sessionID] {
            state.confirmedResults[commandID] = result
            if case let .mutateComment(comicID, mutation, _) = command {
                state.confirmedCommentPayloads[commandID] = CommentMutationCacheEntry(
                    comicID: comicID,
                    mutation: mutation
                )
            }
            if state.confirmedResults.count > 256, let first = state.confirmedResults.keys.first {
                state.confirmedResults.removeValue(forKey: first)
                state.confirmedCommentPayloads.removeValue(forKey: first)
            }
            states[sessionID] = state
        }
        return result
    }

    private func baseSnapshot() -> AgentBaseSnapshot {
        let context = navigation.currentContext
        let content = pageContent.snapshot
        content.comicIDs.forEach { knownComicIDs.insert($0) }
        let page = AgentPageSnapshot(
            kind: Self.pageKind(for: context),
            title: Self.pageTitle(for: context),
            comicID: currentComicID,
            chapterID: readerSurface?.agentReaderSnapshot.chapterID
        )
        return AgentBaseSnapshot(
            isLoggedIn: sessionIsLoggedIn(),
            page: page,
            reader: readerSurface?.agentReaderSnapshot,
            pageContent: content
        )
    }

    private var currentComicID: String? {
        switch navigation.currentContext {
        case let .detail(comicID), let .reader(comicID, _, _): return comicID
        default: return readerSurface?.agentReaderSnapshot.comicID
        }
    }

    private func chapterIDs(for comicID: String) async throws -> Set<String> {
        if let known = knownChapterIDs[comicID] {
            return known
        }
        let chapters = try await chapterProvider(comicID)
        let ids = Set(chapters.map(\.id))
        knownChapterIDs[comicID] = ids
        return ids
    }
    private func commentPage(
        comicID: String,
        parentID: String?,
        page: Int,
        sessionID: UUID
    ) async -> AgentCommandResult {
        guard sessionIsLoggedIn() else { return .loginRequired }
        guard let epoch = states[sessionID]?.authorizationEpoch else {
            return .failure(.invalidIdentifier)
        }
        guard (1...1_000).contains(page) else { return .failure(.invalidPage) }
        guard validCommentIdentifier(comicID),
              isAuthorizedComicID(comicID, sessionID: sessionID) else {
            return .failure(.invalidIdentifier)
        }
        if let parentID {
            guard validCommentIdentifier(parentID),
                  let known = states[sessionID]?.knownComments[parentID],
                  known.comicID == comicID,
                  !known.isHidden else {
                return .failure(.invalidIdentifier)
            }
        }
        do {
            let response = try await commentRepository.comments(
                comicID: comicID,
                parentID: parentID,
                page: page
            )
            guard states[sessionID]?.authorizationEpoch == epoch else {
                return .failure(.invalidIdentifier)
            }
            guard sessionIsLoggedIn() else { return .loginRequired }
            let returnedDocs = response.docs
                .prefix(20)
                .filter { validCommentIdentifier($0.id) }
            let snapshots = returnedDocs.map { comment in
                AgentCommentSnapshot(
                    commentID: comment.id,
                    parentID: parentID,
                    displayName: comment.user?.name ?? "",
                    content: comment.content,
                    createdAt: comment.createdAt,
                    likesCount: comment.likesCount,
                    repliesCount: comment.repliesCount,
                    isTop: comment.isTop,
                    isHidden: comment.isHidden
                )
            }
            rememberComments(Array(returnedDocs), comicID: comicID, parentID: parentID, sessionID: sessionID)
            return .commentPage(
                AgentCommentPageSnapshot(
                    comicID: comicID,
                    parentID: parentID,
                    page: response.page,
                    pages: response.pages,
                    total: response.total,
                    comments: snapshots
                )
            )
        } catch let error as CommentOperationError {
            switch error {
            case .invalidIdentifier: return .failure(.invalidIdentifier)
            default: return .failure(.providerFailure)
            }
        } catch {
            return .failure(.providerFailure)
        }
    }

    private func mutateComment(
        comicID: String,
        mutation: CommentMutation,
        commandID: String,
        sessionID: UUID,
        confirmed: Bool
    ) async -> AgentCommandResult {
        guard let epoch = states[sessionID]?.authorizationEpoch else {
            return .failure(.invalidIdentifier)
        }
        guard sessionIsLoggedIn(),
              validCommentIdentifier(comicID),
              validCommentIdentifier(commandID),
              isAuthorizedComicID(comicID, sessionID: sessionID) else {
            return sessionIsLoggedIn()
                ? .failure(.invalidIdentifier)
                : .loginRequired
        }
        let target: KnownCommentRecord?
        if let commentID = mutation.commentID {
            guard validCommentIdentifier(commentID),
                  let known = states[sessionID]?.knownComments[commentID],
                  known.comicID == comicID,
                  !known.isHidden else {
                return .failure(.invalidIdentifier)
            }
            target = known
        } else {
            target = nil
        }
        do {
            if let content = mutation.content {
                _ = try CommentInput.validatedContent(content)
            }
        } catch {
            return .failure(.invalidIdentifier)
        }
        if !confirmed {
            return .requiresConfirmation(
                .commentMutation(
                    comicID: comicID,
                    commentID: mutation.commentID,
                    operation: mutation.operation,
                    content: mutation.content.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                    targetExcerpt: target?.excerpt
                )
            )
        }
        guard reserveCommentMutation(commandID, sessionID: sessionID) else {
            return .failure(.invalidIdentifier)
        }
        defer { releaseCommentMutation(commandID, sessionID: sessionID) }
        do {
            try await commentRepository.perform(comicID: comicID, mutation: mutation)
            guard states[sessionID]?.authorizationEpoch == epoch else {
                return .failure(.invalidIdentifier)
            }
            guard sessionIsLoggedIn() else { return .loginRequired }
            return .commentMutationApplied(
                comicID: comicID,
                commentID: mutation.commentID,
                operation: mutation.operation
            )
        } catch let error as CommentOperationError {
            switch error {
            case .invalidIdentifier: return .failure(.invalidIdentifier)
            default: return .failure(.providerFailure)
            }
        } catch {
            return .failure(.providerFailure)
        }
    }

    private func reserveCommentMutation(_ commandID: String, sessionID: UUID) -> Bool {
        guard var state = states[sessionID],
              !state.inFlightCommentCommandIDs.contains(commandID) else {
            return false
        }
        state.inFlightCommentCommandIDs.insert(commandID)
        states[sessionID] = state
        return true
    }

    private func releaseCommentMutation(_ commandID: String, sessionID: UUID) {
        guard var state = states[sessionID] else { return }
        state.inFlightCommentCommandIDs.remove(commandID)
        states[sessionID] = state
    }

    private func rememberComments(
        _ comments: [PicaComment],
        comicID: String,
        parentID: String?,
        sessionID: UUID
    ) {
        guard var state = states[sessionID] else { return }
        for comment in comments {
            state.knownComments.removeValue(forKey: comment.id)
            state.knownCommentOrder.removeAll { $0 == comment.id }
            guard validCommentIdentifier(comment.id) else { continue }
            state.knownComments[comment.id] = KnownCommentRecord(
                comicID: comicID,
                parentID: parentID,
                excerpt: comment.isHidden
                    ? ""
                    : AgentCommentSnapshot.boundedText(comment.content, maxBytes: 1_024, maxCharacters: 240),
                isHidden: comment.isHidden
            )
            state.knownCommentOrder.append(comment.id)
        }
        while state.knownCommentOrder.count > 100 {
            let evicted = state.knownCommentOrder.removeFirst()
            state.knownComments.removeValue(forKey: evicted)
        }
        states[sessionID] = state
    }

    private func validCommentIdentifier(_ value: String) -> Bool {
        do {
            try CommentInput.validateIdentifier(value)
            return true
        } catch {
            return false
        }
    }
    private func validCommentMutationInput(
        comicID: String,
        mutation: CommentMutation,
        commandID: String
    ) -> Bool {
        guard validCommentIdentifier(comicID), validCommentIdentifier(commandID) else { return false }
        if let commentID = mutation.commentID, !validCommentIdentifier(commentID) {
            return false
        }
        if let content = mutation.content {
            do {
                _ = try CommentInput.validatedContent(content)
            } catch {
                return false
            }
        }
        return true
    }

    private func isAuthorizedCommentMutation(
        comicID: String,
        mutation: CommentMutation,
        sessionID: UUID
    ) -> Bool {
        guard validCommentIdentifier(comicID),
              isAuthorizedComicID(comicID, sessionID: sessionID) else {
            return false
        }
        guard let commentID = mutation.commentID else { return true }
        guard let known = states[sessionID]?.knownComments[commentID] else { return false }
        return known.comicID == comicID && !known.isHidden
    }


    private func isAuthorizedComicID(_ comicID: String, sessionID: UUID) -> Bool {
        states[sessionID]?.knownComicIDs.contains(comicID) == true || currentComicID == comicID
    }

    private func downloadConfirmation(
        comicID: String,
        chapterIDs: [String],
        quality: AppImageQuality
    ) async -> AgentCommandResult {
        guard !chapterIDs.isEmpty, Set(chapterIDs).count == chapterIDs.count else {
            return .failure(.invalidIdentifier)
        }
        do {
            let comic = try await comicDetailProvider(comicID)
            guard comic.allowDownload else { return .failure(.invalidIdentifier) }
            let chapters = try await chapterProvider(comicID)
            knownChapterIDs[comicID] = Set(chapters.map(\.id))
            guard chapterIDs.allSatisfy({ id in chapters.contains { $0.id == id } }) else {
                return .failure(.invalidIdentifier)
            }
            let selectedTitles = chapterIDs.compactMap { id in
                chapters.first { $0.id == id }?.title
            }
            return .requiresConfirmation(
                .download(
                    comicID: comic.id,
                    comicTitle: comic.title,
                    chapterTitles: selectedTitles,
                    quality: quality,
                    estimatedPages: comic.pagesCount > 0 ? comic.pagesCount : nil
                )
            )
        } catch {
            return .failure(.providerFailure)
        }
    }

    private func cancellationConfirmation(jobID: String) async -> AgentCommandResult {
        do {
            let snapshot = try await downloadProvider.snapshot(jobID: jobID)
            guard snapshot.state == .queued || snapshot.state == .downloading else {
                return .failure(.invalidIdentifier)
            }
            return .requiresConfirmation(
                .cancelDownload(
                    jobID: snapshot.id,
                    title: snapshot.title,
                    completedImages: snapshot.completedImages,
                    totalImages: snapshot.totalImages,
                    state: snapshot.state
                )
            )
        } catch {
            return .failure(.invalidIdentifier)
        }
    }

    private func desiredStateConfirmation(
        comicID: String,
        action: AgentDesiredState,
        desired: Bool
    ) async -> AgentCommandResult {
        do {
            let detail = try await comicDetailProvider(comicID)
            return .requiresConfirmation(
                .desiredState(
                    comicID: comicID,
                    comicTitle: detail.title,
                    action: action,
                    desired: desired
                )
            )
        } catch {
            return .failure(.providerFailure)
        }
    }

    private func startDownload(comicID: String, chapterIDs: [String], quality: AppImageQuality) async -> AgentCommandResult {
        guard !chapterIDs.isEmpty, Set(chapterIDs).count == chapterIDs.count else { return .failure(.invalidIdentifier) }
        do {
            let comic = try await comicDetailProvider(comicID)
            guard comic.allowDownload else { return .failure(.invalidIdentifier) }
            let chapters = try await chapterProvider(comicID)
            knownChapterIDs[comicID] = Set(chapters.map(\.id))
            guard chapterIDs.allSatisfy({ id in chapters.contains(where: { $0.id == id }) }) else {
                return .failure(.invalidIdentifier)
            }
            let selected = chapterIDs.compactMap { id in chapters.first(where: { $0.id == id }) }
            let request = DownloadRequest(
                comicID: comic.id,
                title: comic.title,
                thumbURL: comic.thumb.url,
                createdAt: comic.createdAt,
                updatedAt: comic.updatedAt,
                chapters: selected,
                quality: quality,
                allChapters: chapters,
                allowDownload: comic.allowDownload
            )
            return .queuedDownload(jobID: try await DownloadCoordinator.shared.start(request: request))
        } catch let error as DownloadCoordinatorError {
            if case let .conflict(existingJobIDs) = error {
                return .downloadConflict(existingJobIDs: existingJobIDs)
            }
            return .failure(.providerFailure)
        } catch {
            return .failure(.providerFailure)
        }
    }

    private func applyDesiredLike(comicID: String, desired: Bool, commandID: String, confirmed: Bool) async -> AgentCommandResult {
        guard sessionIsLoggedIn() else { return .loginRequired }
        guard isAuthorizedComicID(comicID) else { return .failure(.invalidIdentifier) }
        guard confirmed else {
            return await desiredStateConfirmation(comicID: comicID, action: .liked, desired: desired)
        }
        do {
            let detail = try await comicDetailProvider(comicID)
            if detail.isLiked != desired { _ = try await PicaAPIService.shared.likeComic(id: comicID) }
            let result: AgentCommandResult = .desiredStateApplied(comicID: comicID, isLiked: desired, isFavorited: nil)
            confirmedResults[commandID] = result
            return result
        } catch { return .failure(.providerFailure) }
    }

    private func applyDesiredFavorite(comicID: String, desired: Bool, commandID: String, confirmed: Bool) async -> AgentCommandResult {
        guard sessionIsLoggedIn() else { return .loginRequired }
        guard isAuthorizedComicID(comicID) else { return .failure(.invalidIdentifier) }
        guard confirmed else {
            return await desiredStateConfirmation(comicID: comicID, action: .favorited, desired: desired)
        }
        do {
            let detail = try await comicDetailProvider(comicID)
            if detail.isFavourite != desired { _ = try await PicaAPIService.shared.favoriteComic(id: comicID) }
            let result: AgentCommandResult = .desiredStateApplied(comicID: comicID, isLiked: nil, isFavorited: desired)
            confirmedResults[commandID] = result
            return result
        } catch { return .failure(.providerFailure) }
    }

    private func mutateBlockedWordAdd(word: String, confirmed: Bool) async -> AgentCommandResult {
        do {
            let rule = try BlockedWordCanonicalizer.rule(from: word)
            if !confirmed {
                return .requiresConfirmation(.blockedWordAdd(
                    displayValue: rule.displayValue,
                    normalizedKey: rule.normalizedKey
                ))
            }
            return blockedWordResult(
                try await blockedWords.add(display: rule.displayValue),
                operation: "add"
            )
        } catch let error as BlockedWordValidationError {
            return .failure(.blockedWord(error))
        } catch {
            return .failure(.providerFailure)
        }
    }

    private func mutateBlockedWordUpdate(
        oldWord: String,
        newWord: String,
        confirmed: Bool
    ) async -> AgentCommandResult {
        do {
            let oldRule = try BlockedWordCanonicalizer.rule(from: oldWord)
            let newRule = try BlockedWordCanonicalizer.rule(from: newWord)
            let snapshot = await blockedWords.snapshot()
            guard let existing = snapshot.rules.first(where: {
                $0.normalizedKey == oldRule.normalizedKey
            }) else {
                throw BlockedWordValidationError.notFound
            }
            if !confirmed {
                return .requiresConfirmation(.blockedWordUpdate(
                    oldDisplayValue: existing.displayValue,
                    oldNormalizedKey: existing.normalizedKey,
                    newDisplayValue: newRule.displayValue,
                    newNormalizedKey: newRule.normalizedKey
                ))
            }
            return blockedWordResult(
                try await blockedWords.update(
                    normalizedOld: existing.normalizedKey,
                    newDisplay: newRule.displayValue
                ),
                operation: "update"
            )
        } catch let error as BlockedWordValidationError {
            return .failure(.blockedWord(error))
        } catch {
            return .failure(.providerFailure)
        }
    }

    private func mutateBlockedWordRemove(word: String, confirmed: Bool) async -> AgentCommandResult {
        do {
            let rule = try BlockedWordCanonicalizer.rule(from: word)
            let snapshot = await blockedWords.snapshot()
            guard let existing = snapshot.rules.first(where: {
                $0.normalizedKey == rule.normalizedKey
            }) else {
                throw BlockedWordValidationError.notFound
            }
            if !confirmed {
                return .requiresConfirmation(.blockedWordRemove(
                    displayValue: existing.displayValue,
                    normalizedKey: existing.normalizedKey
                ))
            }
            return blockedWordResult(
                try await blockedWords.remove(normalizedKey: existing.normalizedKey),
                operation: "remove"
            )
        } catch let error as BlockedWordValidationError {
            return .failure(.blockedWord(error))
        } catch {
            return .failure(.providerFailure)
        }
    }

    private func mutateIncludedWordAdd(
        word: String,
        confirmed: Bool
    ) async -> AgentCommandResult {
        do {
            let rule = try BlockedWordCanonicalizer.rule(from: word)
            if !confirmed {
                return .requiresConfirmation(.includedWordAdd(
                    displayValue: rule.displayValue,
                    normalizedKey: rule.normalizedKey
                ))
            }
            return blockedWordResult(
                try blockedWords.addIncluded(display: rule.displayValue),
                operation: "include_add"
            )
        } catch let error as BlockedWordValidationError {
            return .failure(.blockedWord(error))
        } catch {
            return .failure(.providerFailure)
        }
    }

    private func mutateIncludedWordUpdate(
        oldWord: String,
        newWord: String,
        confirmed: Bool
    ) async -> AgentCommandResult {
        do {
            let oldRule = try BlockedWordCanonicalizer.rule(from: oldWord)
            let newRule = try BlockedWordCanonicalizer.rule(from: newWord)
            let snapshot = await blockedWords.snapshot()
            guard let existing = snapshot.includeRules.first(where: {
                $0.normalizedKey == oldRule.normalizedKey
            }) else {
                throw BlockedWordValidationError.notFound
            }
            if !confirmed {
                return .requiresConfirmation(.includedWordUpdate(
                    oldDisplayValue: existing.displayValue,
                    oldNormalizedKey: existing.normalizedKey,
                    newDisplayValue: newRule.displayValue,
                    newNormalizedKey: newRule.normalizedKey
                ))
            }
            return blockedWordResult(
                try blockedWords.updateIncluded(
                    normalizedOld: existing.normalizedKey,
                    newDisplay: newRule.displayValue
                ),
                operation: "include_update"
            )
        } catch let error as BlockedWordValidationError {
            return .failure(.blockedWord(error))
        } catch {
            return .failure(.providerFailure)
        }
    }

    private func mutateIncludedWordRemove(
        word: String,
        confirmed: Bool
    ) async -> AgentCommandResult {
        do {
            let rule = try BlockedWordCanonicalizer.rule(from: word)
            let snapshot = await blockedWords.snapshot()
            guard let existing = snapshot.includeRules.first(where: {
                $0.normalizedKey == rule.normalizedKey
            }) else {
                throw BlockedWordValidationError.notFound
            }
            if !confirmed {
                return .requiresConfirmation(.includedWordRemove(
                    displayValue: existing.displayValue,
                    normalizedKey: existing.normalizedKey
                ))
            }
            return blockedWordResult(
                try blockedWords.removeIncluded(normalizedKey: existing.normalizedKey),
                operation: "include_remove"
            )
        } catch let error as BlockedWordValidationError {
            return .failure(.blockedWord(error))
        } catch {
            return .failure(.providerFailure)
        }
    }

    private func blockedWordResult(
        _ write: BlockedWordWriteResult,
        operation name: String
    ) -> AgentCommandResult {
        let state: String
        switch write {
        case .changed: state = "\(name)_changed"
        case let .unchanged(reason, _): state = "\(name)_unchanged_\(reason.rawValue)"
        }
        return .blockedWords(snapshot: write.snapshot, operation: state)
    }

    private func isAuthorizedComicID(_ comicID: String) -> Bool {
        knownComicIDs.contains(comicID)
            || localComicIDs.contains(comicID)
            || currentComicID == comicID
    }

    private static func requiresRiskAuthorization(_ command: AgentCommand) -> Bool {
        switch command {
        case .cancelDownload,
             .deleteOfflineComic,
             .setLiked,
             .setFavorited,
             .addBlockedWord,
             .updateBlockedWord,
             .removeBlockedWord,
             .addIncludedWord,
             .updateIncludedWord,
             .removeIncludedWord,
             .mutateComment:
            true
        default:
            false
        }
    }

    private func isSuccessfulSideEffect(_ result: AgentCommandResult) -> Bool {
        switch result {
        case .queuedDownload, .cancelledDownload, .deletedOfflineComic,
             .desiredStateApplied, .blockedWords, .commentMutationApplied:
            true
        default:
            false
        }
    }

    func clearSession(_ sessionID: UUID) {
        states.removeValue(forKey: sessionID)
        if activeSessionID == sessionID { activeSessionID = UUID() }
    }

    func clearAllAuthorization() {
        states.removeAll()
        activeSessionID = UUID()
    }

    private func commandID(for command: AgentCommand) -> String? {
        switch command {
        case let .startDownload(_, _, _, commandID),
             let .cancelDownload(_, commandID),
             let .deleteOfflineComic(_, commandID),
             let .setLiked(_, _, commandID),
             let .setFavorited(_, _, commandID),
             let .addBlockedWord(_, commandID),
             let .updateBlockedWord(_, _, commandID),
             let .removeBlockedWord(_, commandID),
             let .addIncludedWord(_, commandID),
             let .updateIncludedWord(_, _, commandID),
             let .removeIncludedWord(_, commandID),
             let .mutateComment(_, _, commandID):
            commandID
        default:
            nil
        }
    }

    private static func mapImageError(_ error: AgentImageError) -> AgentCommandError {
        switch error {
        case .unavailable, .unsupported: return .pageImageUnavailable
        case .tooLarge: return .pageImageTooLarge
        case .rateLimited: return .pageImageRateLimited
        }
    }

    private static func pageKind(for context: AgentPageContext) -> AgentPageKind {
        switch context {
        case .startup: return .startup
        case .failed: return .failed
        case .login: return .login
        case .tab: return .tab
        case .detail: return .detail
        case .offlineLibrary: return .offlineLibrary
        case .reader: return .reader
        case .nonSettingsSheet: return .sheet
        }
    }

    private static func pageTitle(for context: AgentPageContext) -> String {
        switch context {
        case let .startup(phase): return phase.rawValue
        case .failed: return "Failed"
        case .login: return "Login"
        case let .tab(tab): return tab
        case let .detail(comicID): return comicID
        case .offlineLibrary: return "Offline Library"
        case let .reader(_, chapterID, page): return "Reader \(chapterID ?? "") \(page + 1)"
        case let .nonSettingsSheet(_, kind): return kind
        }
    }
}
