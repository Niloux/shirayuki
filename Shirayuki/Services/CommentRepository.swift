import Foundation

nonisolated enum CommentMutation: Equatable, Sendable {
    case post(content: String)
    case reply(commentID: String, content: String)
    case delete(commentID: String)
    case toggleLike(commentID: String)
    case report(commentID: String)

    var commentID: String? {
        switch self {
        case .post: return nil
        case let .reply(commentID, _), let .delete(commentID), let .toggleLike(commentID), let .report(commentID):
            return commentID
        }
    }

    var content: String? {
        switch self {
        case let .post(content), let .reply(_, content): return content
        case .delete, .toggleLike, .report: return nil
        }
    }

    var operation: String {
        switch self {
        case .post: return "post"
        case .reply: return "reply"
        case .delete: return "delete"
        case .toggleLike: return "toggleLike"
        case .report: return "report"
        }
    }
}

nonisolated enum CommentInput {
    static let maximumLength = 2000
    static let maximumUTF8Bytes = 64 * 1024

    static func validatedContent(_ raw: String) throws -> String {
        guard raw.utf8.count <= maximumUTF8Bytes else { throw CommentOperationError.contentTooLong }
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw CommentOperationError.emptyContent }
        guard content.count <= maximumLength else { throw CommentOperationError.contentTooLong }
        return content
    }

    static func validateIdentifier(_ raw: String) throws {
        guard (1...128).contains(raw.unicodeScalars.count), raw.unicodeScalars.allSatisfy({
            ($0.value >= 48 && $0.value <= 57)
                || ($0.value >= 65 && $0.value <= 90)
                || ($0.value >= 97 && $0.value <= 122)
                || $0.value == 95
                || $0.value == 45
        }) else {
            throw CommentOperationError.invalidIdentifier
        }
    }
}

nonisolated enum CommentOperationError: Error, LocalizedError, Sendable {
    case emptyContent
    case contentTooLong
    case invalidIdentifier
    case commentingDisabled

    var errorDescription: String? {
        switch self {
        case .emptyContent: return AppLocalization.text("comments.error.empty")
        case .contentTooLong: return AppLocalization.text("comments.error.contentTooLong")
        case .invalidIdentifier: return AppLocalization.text("comments.error.invalidIdentifier")
        case .commentingDisabled: return AppLocalization.text("comments.error.disabled")
        }
    }
}

nonisolated protocol CommentRepository: Sendable {
    func comments(comicID: String, parentID: String?, page: Int) async throws -> PicaCommentsPage
    func perform(comicID: String, mutation: CommentMutation) async throws
}

nonisolated struct PicaCommentRepository: CommentRepository {
    private let service: PicaAPIService

    init(service: PicaAPIService = .shared) {
        self.service = service
    }

    func comments(comicID: String, parentID: String?, page: Int) async throws -> PicaCommentsPage {
        try CommentInput.validateIdentifier(comicID)
        guard page > 0 else { throw CommentOperationError.invalidIdentifier }
        if let parentID {
            try CommentInput.validateIdentifier(parentID)
            return try await service.fetchCommentReplies(id: parentID, page: page)
        }
        return try await service.fetchComicComments(id: comicID, page: page)
    }

    func perform(comicID: String, mutation: CommentMutation) async throws {
        try CommentInput.validateIdentifier(comicID)
        switch mutation {
        case let .post(content):
            let content = try CommentInput.validatedContent(content)
            try await ensureCommentingAllowed(comicID: comicID)
            try await service.postComment(comicID: comicID, content: content)
        case let .reply(commentID, content):
            try CommentInput.validateIdentifier(commentID)
            let content = try CommentInput.validatedContent(content)
            try await ensureCommentingAllowed(comicID: comicID)
            try await service.postCommentReply(commentID: commentID, content: content)
        case let .delete(commentID):
            try CommentInput.validateIdentifier(commentID)
            try await service.deleteComment(id: commentID)
        case let .toggleLike(commentID):
            try CommentInput.validateIdentifier(commentID)
            _ = try await service.toggleCommentLike(id: commentID)
        case let .report(commentID):
            try CommentInput.validateIdentifier(commentID)
            try await service.reportComment(id: commentID)
        }
        // Notify before returning so the sender can ignore its own invalidation.
        await MainActor.run {
            NotificationCenter.default.post(
                name: .commentRepositoryDidMutate,
                object: nil,
                userInfo: ["comicID": comicID]
            )
        }
    }

    private func ensureCommentingAllowed(comicID: String) async throws {
        let detail = try await service.fetchComicDetail(id: comicID)
        guard detail.allowComment else { throw CommentOperationError.commentingDisabled }
    }
}

extension Notification.Name {
    nonisolated static let commentRepositoryDidMutate = Notification.Name("commentRepositoryDidMutate")
}
