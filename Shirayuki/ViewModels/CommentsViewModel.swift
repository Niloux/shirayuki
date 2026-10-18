import Foundation
import Combine

/// Coordinates one page of comments or replies without retaining earlier pages.
@MainActor
final class CommentsViewModel: ObservableObject {
    let comicID: String
    let commentID: String?

    @Published private(set) var comments: [PicaComment] = []
    @Published private(set) var page = 1
    @Published private(set) var pages = 1
    @Published private(set) var total = 0
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSending = false
    @Published private(set) var submissionErrorMessage: String?

    private let repository: any CommentRepository
    private var loadGeneration = 0

    init(
        comicID: String,
        commentID: String? = nil,
        repository: any CommentRepository = PicaCommentRepository()
    ) {
        self.comicID = comicID
        self.commentID = commentID
        self.repository = repository
    }

    /// Replaces the current page after a successful, non-cancelled request.
    func load(page requestedPage: Int) async {
        guard requestedPage > 0, !Task.isCancelled else { return }

        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }

        do {
            let response = try await repository.comments(
                comicID: comicID,
                parentID: commentID,
                page: requestedPage
            )
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }

            var seen = Set<String>()
            comments = response.docs.filter { seen.insert($0.id).inserted }
            page = max(1, response.page)
            pages = max(1, response.pages)
            total = max(0, response.total)
            hasLoaded = true
            errorMessage = nil
        } catch is CancellationError {
            // Cancellation never commits a partial page or an error state.
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            errorMessage = (error as? APIError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// Sends one comment or reply. The caller owns the draft and may clear it only on success.
    func submit(content: String) async -> Bool {
        guard !isSending, !Task.isCancelled else { return false }
        let draft = content

        do {
            let validated = try CommentInput.validatedContent(draft)
            let mutation: CommentMutation
            if let commentID {
                mutation = .reply(commentID: commentID, content: validated)
            } else {
                mutation = .post(content: validated)
            }

            isSending = true
            defer { isSending = false }
            try await repository.perform(comicID: comicID, mutation: mutation)
            submissionErrorMessage = nil
            return true
        } catch {
            submissionErrorMessage = error.localizedDescription
            return false
        }
    }

    func clearSubmissionError() {
        submissionErrorMessage = nil
    }
}
