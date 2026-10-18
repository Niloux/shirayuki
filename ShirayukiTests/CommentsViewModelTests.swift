import Foundation
import XCTest
@testable import Shirayuki

@MainActor
final class CommentsViewModelTests: XCTestCase {
    func testWriteResponseRejectsBusinessFailureAndAcceptsAbsentOrNullData() throws {
        let decoder = JSONDecoder()
        let rejected = try decoder.decode(
            CommentWriteResponse.self,
            from: Data(#"{"code":403,"message":"permission denied","data":{}}"#.utf8)
        )
        XCTAssertThrowsError(try rejected.validate()) { error in
            XCTAssertEqual(error as? APIError, .serverError(403, "permission denied"))
        }
        for json in [#"{"code":200,"message":"ok"}"#, #"{"code":200,"message":"ok","data":null}"#] {
            let response = try decoder.decode(CommentWriteResponse.self, from: Data(json.utf8))
            try response.validate()
        }
    }

    func testPageDecodingMapsStringNumbersAndHidesPrivateFields() throws {
        let json = """
        {
          "docs": [
            {
              "_id": "comment-1",
              "content": "hello",
              "_user": {
                "name": "reader",
                "title": "Member",
                "avatar": {"fileServer": "https://img", "path": "avatar.jpg", "originalName": "avatar.jpg"}
              },
              "created_at": "2026-01-01",
              "likesCount": "-2",
              "totalComments": "3",
              "isTop": true,
              "hide": false
            },
            {
              "_id": "hidden-1",
              "content": "private text",
              "_user": {"name": "private user", "title": "Private"},
              "created_at": "2026-01-02",
              "likesCount": "-1",
              "commentsCount": "-4",
              "hide": true
            }
          ],
          "page": "2",
          "pages": "3",
          "total": "-1"
        }
        """.data(using: .utf8)!

        let page = try JSONDecoder().decode(PicaCommentsPage.self, from: json)
        XCTAssertEqual(page.page, 2)
        XCTAssertEqual(page.pages, 3)
        XCTAssertEqual(page.total, 0)
        XCTAssertEqual(page.docs[0].id, "comment-1")
        XCTAssertEqual(page.docs[0].user?.name, "reader")
        XCTAssertEqual(page.docs[0].likesCount, 0)
        XCTAssertEqual(page.docs[0].repliesCount, 3)
        XCTAssertTrue(page.docs[0].isTop)
        XCTAssertFalse(page.docs[0].isHidden)
        XCTAssertEqual(page.docs[1].content, "")
        XCTAssertNil(page.docs[1].user)
        XCTAssertEqual(page.docs[1].likesCount, 0)
        XCTAssertEqual(page.docs[1].repliesCount, 0)
        XCTAssertTrue(page.docs[1].isHidden)
    }

    func testLoadReplacesPageInsteadOfAppendingAndDeduplicatesIDs() async {
        let repository = TestPageRepository { page in
            if page == 1 {
                return PicaCommentsPage(
                    docs: [TestCommentFactory.make(id: "one"), TestCommentFactory.make(id: "one")],
                    page: 1,
                    pages: 2,
                    total: 3
                )
            }
            return PicaCommentsPage(
                docs: [TestCommentFactory.make(id: "two")],
                page: 2,
                pages: 2,
                total: 3
            )
        }
        let viewModel = CommentsViewModel(comicID: "comic", repository: repository)

        await viewModel.load(page: 1)
        XCTAssertEqual(viewModel.comments.map(\.id), ["one"])
        await viewModel.load(page: 2)
        XCTAssertEqual(viewModel.comments.map(\.id), ["two"])
        XCTAssertEqual(viewModel.page, 2)
        XCTAssertEqual(viewModel.total, 3)
    }

    func testFailedLoadPreservesPageAndRetryCanSucceed() async {
        let fetcher = RetryFetcher()
        let viewModel = CommentsViewModel(comicID: "comic", repository: fetcher)

        await viewModel.load(page: 1)
        XCTAssertEqual(viewModel.comments.map(\.id), ["retry"])
        await viewModel.load(page: 2)
        XCTAssertEqual(viewModel.page, 1)
        XCTAssertEqual(viewModel.comments.map(\.id), ["retry"])
        XCTAssertNotNil(viewModel.errorMessage)

        await viewModel.load(page: 2)
        XCTAssertEqual(viewModel.page, 2)
        XCTAssertEqual(viewModel.comments.map(\.id), ["success"])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCancellationDoesNotCommit() async {
        let fetcher = BlockingFetcher()
        let viewModel = CommentsViewModel(comicID: "comic", repository: fetcher)

        await viewModel.load(page: 1)
        let task = Task { @MainActor in
            await viewModel.load(page: 2)
        }
        await fetcher.waitUntilBlocked()
        task.cancel()
        await fetcher.resume()
        await task.value

        XCTAssertEqual(viewModel.page, 1)
        XCTAssertEqual(viewModel.comments.map(\.id), ["initial"])
        let requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 2)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testNewerPageIsNotDroppedOrOverwrittenByOlderRequest() async {
        let repository = BlockingFetcher()
        let viewModel = CommentsViewModel(comicID: "comic", repository: repository)
        await viewModel.load(page: 1)
        let older = Task { await viewModel.load(page: 2) }
        await repository.waitUntilBlocked()
        await viewModel.load(page: 3)
        XCTAssertEqual(viewModel.page, 3)
        XCTAssertFalse(viewModel.isLoading)
        await repository.resume()
        await older.value
        XCTAssertEqual(viewModel.page, 3)
        XCTAssertEqual(viewModel.comments.map(\.id), ["newest"])
    }

    func testSubmitValidatesInputAndRetainsSubmissionError() async {
        let repository = SubmissionRepository(error: .invalidResponse)
        let viewModel = CommentsViewModel(comicID: "comic", repository: repository)

        let emptyResult = await viewModel.submit(content: " \n")
        XCTAssertFalse(emptyResult)
        XCTAssertFalse(viewModel.isSending)
        XCTAssertNotNil(viewModel.submissionErrorMessage)
        let emptyCount = await repository.performCount
        XCTAssertEqual(emptyCount, 0)

        let longResult = await viewModel.submit(content: String(repeating: "x", count: CommentInput.maximumLength + 1))
        XCTAssertFalse(longResult)
        let longCount = await repository.performCount
        XCTAssertEqual(longCount, 0)

        let combiningResult = await viewModel.submit(
            content: "a" + String(repeating: "\u{0301}", count: CommentInput.maximumUTF8Bytes)
        )
        XCTAssertFalse(combiningResult)
        let oversizedCount = await repository.performCount
        XCTAssertEqual(oversizedCount, 0)

        let failedResult = await viewModel.submit(content: "draft")
        XCTAssertFalse(failedResult)
        XCTAssertFalse(viewModel.isSending)
        XCTAssertNotNil(viewModel.submissionErrorMessage)
        let failedCount = await repository.performCount
        XCTAssertEqual(failedCount, 1)
    }

    func testSuccessfulSubmitUsesTrimmedDraftAndClearsError() async {
        let repository = SubmissionRepository()
        let viewModel = CommentsViewModel(comicID: "comic", commentID: "parent", repository: repository)

        let successResult = await viewModel.submit(content: "  reply  ")
        XCTAssertTrue(successResult)
        XCTAssertFalse(viewModel.isSending)
        XCTAssertNil(viewModel.submissionErrorMessage)
        let mutation = await repository.lastMutation
        XCTAssertEqual(mutation, .reply(commentID: "parent", content: "reply"))
    }

    func testCommentInputRejectsPathInjectionIdentifiers() {
        XCTAssertNoThrow(try CommentInput.validateIdentifier("comic_01-abc"))
        XCTAssertThrowsError(try CommentInput.validateIdentifier("../comments")) { error in
            XCTAssertTrue(error is CommentOperationError)
        }
        XCTAssertThrowsError(try CommentInput.validateIdentifier(String(repeating: "a", count: 129)))
    }
}

private enum TestCommentFactory {
    nonisolated static func make(id: String) -> PicaComment {
        PicaComment(
            id: id,
            content: id,
            user: nil,
            createdAt: "",
            likesCount: 0,
            repliesCount: 0,
            isTop: false,
            isHidden: false
        )
    }
}

private actor SubmissionRepository: CommentRepository {
    private let failure: APIError?
    private(set) var performCount = 0
    private(set) var lastMutation: CommentMutation?

    init(error: APIError? = nil) {
        self.failure = error
    }

    func comments(comicID: String, parentID: String?, page: Int) async throws -> PicaCommentsPage {
        PicaCommentsPage(docs: [], page: page, pages: 1, total: 0)
    }

    func perform(comicID: String, mutation: CommentMutation) async throws {
        performCount += 1
        if let failure { throw failure }
        lastMutation = mutation
    }
}

private actor TestPageRepository: CommentRepository {
    private let pageProvider: @Sendable (Int) -> PicaCommentsPage

    init(_ pageProvider: @escaping @Sendable (Int) -> PicaCommentsPage) {
        self.pageProvider = pageProvider
    }

    func comments(comicID: String, parentID: String?, page: Int) async throws -> PicaCommentsPage {
        pageProvider(page)
    }

    func perform(comicID: String, mutation: CommentMutation) async throws {}
}

private actor RetryFetcher {
    private var calls = 0

    func fetch(page: Int) throws -> PicaCommentsPage {
        calls += 1
        if page == 2, calls == 2 {
            throw APIError.invalidResponse
        }
        return PicaCommentsPage(
            docs: [PicaComment(
                id: page == 1 ? "retry" : "success",
                content: "",
                user: nil,
                createdAt: "",
                likesCount: 0,
                repliesCount: 0,
                isTop: false,
                isHidden: false
            )],
            page: page,
            pages: 2,
            total: 2
        )
    }
}

extension RetryFetcher: CommentRepository {
    func comments(comicID: String, parentID: String?, page: Int) async throws -> PicaCommentsPage {
        try fetch(page: page)
    }

    func perform(comicID: String, mutation: CommentMutation) async throws {}
}

private actor BlockingFetcher {
    private var continuation: CheckedContinuation<PicaCommentsPage, Never>?
    private(set) var requestCount = 0
    private var blockedWaiter: CheckedContinuation<Void, Never>?
    private var isBlocked = false

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { blockedWaiter = $0 }
    }

    func fetch(page: Int) async throws -> PicaCommentsPage {
        requestCount += 1
        if page == 1 {
            return PicaCommentsPage(
                docs: [PicaComment(
                    id: "initial",
                    content: "",
                    user: nil,
                    createdAt: "",
                    likesCount: 0,
                    repliesCount: 0,
                    isTop: false,
                    isHidden: false
                )],
                page: 1,
                pages: 3,
                total: 3
            )
        }
        if page == 3 {
            return PicaCommentsPage(
                docs: [TestCommentFactory.make(id: "newest")], page: 3, pages: 3, total: 3
            )
        }
        isBlocked = true
        blockedWaiter?.resume()
        blockedWaiter = nil
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume(returning: PicaCommentsPage(docs: [
            PicaComment(
                id: "cancelled",
                content: "",
                user: nil,
                createdAt: "",
                likesCount: 0,
                repliesCount: 0,
                isTop: false,
                isHidden: false
            )
        ], page: 2, pages: 3, total: 3))
        continuation = nil
    }
}

extension BlockingFetcher: CommentRepository {
    func comments(comicID: String, parentID: String?, page: Int) async throws -> PicaCommentsPage {
        try await fetch(page: page)
    }

    func perform(comicID: String, mutation: CommentMutation) async throws {}
}
