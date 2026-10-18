import SwiftUI
import Combine

/// A single, replaceable page; replies reuse this surface without nesting threads.
struct ComicCommentsView: View {
    let comicID: String
    private let parent: PicaComment?
    private let allowComment: Bool
    @StateObject private var viewModel: CommentsViewModel
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var appState = AppState.shared
    @State private var selectedComment: PicaComment?
    @State private var requestedPage = 1
    @State private var requestID = UUID()
    @State private var submissionID: UUID?
    @State private var draft = ""
    @State private var submissionDraft = ""
    @State private var scrollMetrics = CommentScrollMetrics.zero
    @State private var pageSwipe = CommentPageSwipe()
    @State private var pendingRefresh = false


    init(comicID: String, parent: PicaComment? = nil, allowComment: Bool = true) {
        self.comicID = comicID
        self.parent = parent
        self.allowComment = allowComment
        _viewModel = StateObject(wrappedValue: CommentsViewModel(comicID: comicID, commentID: parent?.id))
    }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                scrollContent(proxy: proxy, viewport: viewport)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(parent == nil ? "comicCommentsPage" : "commentRepliesPage")
        .navigationTitle(localization.text(parent == nil ? "comments.title" : "comments.replies"))
        .toolbar {
            if parent == nil {
                ToolbarItem(placement: .automatic) {
                    Button {
                        guard !viewModel.isLoading else { return }
                        requestPage(viewModel.page, forceRefresh: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(localization.text("common.reload"))
                    .accessibilityIdentifier("commentsRefreshButton")
                    .disabled(viewModel.isLoading)
                }
            }
        }
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: requestID) {
            await viewModel.load(page: requestedPage)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .commentRepositoryDidMutate)
        ) { notification in
            guard notification.userInfo?["comicID"] as? String == comicID else { return }
            guard !viewModel.isSending, submissionID == nil else { return }
            if viewModel.isLoading {
                pendingRefresh = true
            } else {
                requestPage(viewModel.page, forceRefresh: true)
            }
        }
        .onChange(of: viewModel.isLoading) { _, isLoading in
            guard !isLoading, pendingRefresh, !viewModel.isSending else { return }
            pendingRefresh = false
            requestPage(viewModel.page, forceRefresh: true)
        }
        .task(id: submissionID) {
            guard let submissionID else { return }
            let succeeded = await viewModel.submit(content: submissionDraft)
            guard !Task.isCancelled else { return }
            if succeeded {
                draft = ""
                requestPage(1, forceRefresh: true)
            }
            if self.submissionID == submissionID {
                self.submissionID = nil
            }
        }
        .sheet(item: $selectedComment) { comment in
            NavigationStack {
                ComicCommentsView(comicID: comicID, parent: comment, allowComment: allowComment)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(localization.text("common.close")) { selectedComment = nil }
                        }
                    }
            }
            .frame(minWidth: 320, minHeight: 400)
            .agentSurfaceHost(
                context: .nonSettingsSheet(parent: .detail(comicID: comicID), kind: "commentReplies")
            )
        }
        .agentPageContext(.detail(comicID: comicID))
        .onDisappear { pageSwipe.reset() }
    }
    @ViewBuilder
    private func scrollContent(proxy: ScrollViewProxy, viewport: GeometryProxy) -> some View {
        if parent == nil {
            baseScrollContent(proxy: proxy, viewport: viewport)
        } else {
            baseScrollContent(proxy: proxy, viewport: viewport)
                .refreshable {
                    requestedPage = viewModel.page
                    await viewModel.load(page: requestedPage)
                }
        }
    }

    private func baseScrollContent(proxy: ScrollViewProxy, viewport: GeometryProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Color.clear.frame(height: 0).id("commentsTop")
                if let parent {
                    CommentCard(comment: parent)
                }
                if viewModel.isLoading && !viewModel.hasLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if viewModel.hasLoaded && viewModel.comments.isEmpty {
                    Text(localization.text(parent == nil ? "comments.empty" : "comments.replies.empty"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
                ForEach(viewModel.comments) { comment in
                    CommentCard(
                        comment: comment,
                        onReplies: parent == nil && !comment.isHidden ? {
                            selectedComment = comment
                        } : nil
                    )
                }
                .id(viewModel.page)
                if let error = viewModel.errorMessage {
                    VStack(spacing: 12) {
                        Text(verbatim: error)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(localization.text("common.reload")) {
                            requestID = UUID()
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isLoading)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                if viewModel.hasLoaded {
                    if parent == nil {
                        pageStatus
                    } else {
                        pagination
                    }
                }
            }
            .padding(16)
            .background {
                GeometryReader { content in
                    Color.clear.preference(
                        key: CommentScrollMetricsKey.self,
                        value: CommentScrollMetrics(
                            minY: content.frame(in: .named("commentsScroll")).minY,
                            contentHeight: content.size.height,
                            viewportHeight: viewport.size.height
                        )
                    )
                }
            }
        }
        .coordinateSpace(name: "commentsScroll")
        .onPreferenceChange(CommentScrollMetricsKey.self) {
            scrollMetrics = $0
        }
        .simultaneousGesture(edgeSwipeGesture)
        .onChange(of: viewModel.page) { _, _ in
            pageSwipe.reset()
            proxy.scrollTo("commentsTop", anchor: .top)
        }
        .accessibilityScrollAction { edge in
            guard parent == nil, canNavigate, !viewModel.isLoading else { return }
            switch edge {
            case .top:
                requestPage(viewModel.page - 1)
            case .bottom:
                requestPage(viewModel.page + 1)
            default:
                break
            }
        }
        .accessibilityHint(swipeStatusText)
        .accessibilityIdentifier(parent == nil ? "comicCommentsScroll" : "commentRepliesScroll")
    }


    private var canNavigate: Bool {
        viewModel.hasLoaded && viewModel.errorMessage == nil && viewModel.pages > 1
    }

    private var pageStatus: some View {
        VStack(spacing: 6) {
            if viewModel.isLoading { ProgressView() }
            Text(localization.text("comments.page", viewModel.page, viewModel.pages))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(localization.text("comments.total", viewModel.total))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(swipeStatusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("commentsSwipeStatus")
    }

    private var pagination: some View {
        VStack(spacing: 12) {
            if viewModel.isLoading { ProgressView() }
            HStack {
                Button {
                    requestPage(viewModel.page - 1)
                } label: {
                    Label(localization.text("comments.previous"), systemImage: "chevron.left")
                }
                .accessibilityIdentifier("commentsPreviousPage")
                .disabled(viewModel.isLoading || viewModel.page <= 1)

                Spacer(minLength: 8)
                Text(localization.text("comments.page", viewModel.page, viewModel.pages))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)

                Button {
                    requestPage(viewModel.page + 1)
                } label: {
                    Label(localization.text("comments.next"), systemImage: "chevron.right")
                }
                .accessibilityIdentifier("commentsNextPage")
                .disabled(viewModel.isLoading || viewModel.page >= viewModel.pages)
            }
            .buttonStyle(.bordered)
            Text(localization.text("comments.total", viewModel.total))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var edgeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { updateSwipe(translation: $0.translation, finished: false) }
            .onEnded { updateSwipe(translation: $0.translation, finished: true) }
    }

    private func updateSwipe(translation: CGSize, finished: Bool) {
        let enabled = parent == nil && canNavigate && !viewModel.isLoading
        if finished {
            if let target = pageSwipe.finish(
                translation: translation,
                atTop: scrollMetrics.isAtTop, atBottom: scrollMetrics.isAtBottom,
                page: viewModel.page, pages: viewModel.pages, enabled: enabled
            ) {
                requestPage(target)
            }
        } else {
            pageSwipe.update(
                translation: translation,
                atTop: scrollMetrics.isAtTop, atBottom: scrollMetrics.isAtBottom,
                page: viewModel.page, pages: viewModel.pages, enabled: enabled
            )
        }
    }

    private var swipeStatusText: String {
        guard canNavigate else {
            return localization.text("comments.swipe.first")
        }
        if let target = pageSwipe.destination {
            return localization.text(
                target < viewModel.page ? "comments.swipe.previousReady" : "comments.swipe.nextReady"
            )
        }
        if viewModel.pages <= 1 {
            return localization.text("comments.swipe.first")
        }
        if viewModel.page <= 1 {
            return "\(localization.text("comments.swipe.first")) \(localization.text("comments.swipe.next"))"
        }
        if viewModel.page >= viewModel.pages {
            return "\(localization.text("comments.swipe.last")) \(localization.text("comments.swipe.previous"))"
        }
        return "\(localization.text("comments.swipe.previous")) \(localization.text("comments.swipe.next"))"
    }

    private var canCompose: Bool {
        allowComment && appState.isLoggedIn && parent?.isHidden != true
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !appState.isLoggedIn {
                Text(localization.text("comments.compose.loginRequired"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !allowComment || parent?.isHidden == true {
                Text(localization.text("comments.compose.disabled"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    localization.text(parent == nil ? "comments.compose.placeholder" : "comments.compose.replyPlaceholder"),
                    text: $draft,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .disabled(!canCompose || viewModel.isSending || submissionID != nil)
                .accessibilityIdentifier("commentComposer")
                Button {
                    guard canCompose, submissionID == nil, !viewModel.isSending else { return }
                    pendingRefresh = false
                    submissionDraft = draft
                    submissionID = UUID()
                } label: {
                    Label(
                        localization.text(viewModel.isSending || submissionID != nil ? "comments.compose.sending" : "comments.compose.send"),
                        systemImage: "paperplane.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("commentSendButton")
                .disabled(
                    !canCompose || viewModel.isSending || submissionID != nil
                    || draft.utf8.count > CommentInput.maximumUTF8Bytes
                    || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || draft.count > CommentInput.maximumLength
                )
            }
            if let error = viewModel.submissionErrorMessage {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if canCompose {
                if draft.utf8.count > CommentInput.maximumUTF8Bytes {
                    Text(localization.text("comments.error.contentTooLong"))
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else {
                    let count = draft.count
                    Text(localization.text("comments.compose.limit", count, CommentInput.maximumLength))
                        .font(.caption2)
                        .foregroundStyle(count > CommentInput.maximumLength ? .red : .secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func requestPage(_ page: Int, forceRefresh: Bool = false) {
        let boundedPage = min(max(page, 1), max(viewModel.pages, 1))
        guard boundedPage != viewModel.page || !viewModel.hasLoaded else {
            guard forceRefresh else { return }
            requestedPage = boundedPage
            requestID = UUID()
            return
        }
        requestedPage = boundedPage
        requestID = UUID()
    }
}


private struct CommentScrollMetrics: Equatable {
    var minY: CGFloat
    var contentHeight: CGFloat
    var viewportHeight: CGFloat

    static let zero = CommentScrollMetrics(minY: 0, contentHeight: 0, viewportHeight: 0)

    var isAtTop: Bool { minY >= -2 }
    var isAtBottom: Bool {
        contentHeight <= viewportHeight + 2 || minY + contentHeight <= viewportHeight + 2
    }
}

private struct CommentScrollMetricsKey: PreferenceKey {
    static let defaultValue = CommentScrollMetrics.zero

    static func reduce(value: inout CommentScrollMetrics, nextValue: () -> CommentScrollMetrics) {
        value = nextValue()
    }
}

private struct CommentCard: View {
    let comment: PicaComment
    var onReplies: (() -> Void)?
    @ObservedObject private var localization = AppLocalization.shared
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if comment.isHidden {
                Label(localization.text("comments.hidden"), systemImage: "eye.slash")
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    if let avatar = comment.user?.avatar, !avatar.url.isEmpty {
                        ComicAsyncImage(url: avatar.url, maximumPixelDimension: 128)
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: comment.user.flatMap { $0.name.isEmpty ? nil : $0.name }
                             ?? localization.text("comments.unknownUser"))
                            .font(.subheadline.weight(.semibold))
                        if let title = comment.user?.title, !title.isEmpty {
                            Text(verbatim: title)
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                        Text(AppRelativeTime.string(from: comment.createdAt, locale: localization.locale))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if comment.isTop {
                        Text(localization.text("comments.pinned"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                let canExpand = comment.content.utf8.count > 240 || comment.content.contains("\n")
                Text(verbatim: comment.content)
                    .font(.body)
                    .lineSpacing(4)
                    .lineLimit(canExpand && !expanded ? 6 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                if canExpand {
                    Button(localization.text(expanded ? "comments.collapse" : "comments.expand")) {
                        expanded.toggle()
                    }
                    .font(.subheadline)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
                HStack(spacing: 16) {
                    Label("\(comment.likesCount)", systemImage: "heart")
                        .foregroundStyle(.secondary)
                    if let onReplies {
                        Button(action: onReplies) {
                            if comment.repliesCount > 0 {
                                Label(localization.text("comments.replies.count", comment.repliesCount), systemImage: "text.bubble")
                            } else {
                                Label(localization.text("comments.replies"), systemImage: "text.bubble")
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("commentRepliesButton-\(comment.id)")
                    }
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}
