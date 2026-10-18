import Foundation
import CoreGraphics

/// Counts only dragging beyond the reached edge, never ordinary content scrolling.
nonisolated struct CommentPageSwipe {
    static let threshold: CGFloat = 72
    private enum Edge: Equatable { case top, bottom }
    private var started = false
    private var edge: Edge?
    private var anchor: CGFloat = 0
    private(set) var destination: Int?

    mutating func update(
        translation: CGSize, atTop: Bool, atBottom: Bool,
        page: Int, pages: Int, enabled: Bool
    ) {
        guard enabled else { reset(); return }
        guard started || translation != .zero else { return }
        let reached: Edge?
        if atTop && atBottom {
            reached = translation.height > 0 ? .top : translation.height < 0 ? .bottom : nil
        } else {
            reached = atTop ? .top : atBottom ? .bottom : nil
        }
        if !started {
            started = true
            edge = reached
            anchor = 0
        } else if reached != edge {
            edge = reached
            anchor = translation.height
        }
        destination = nil
        guard let edge, abs(translation.height) >= abs(translation.width) else { return }
        switch edge {
        case .top where translation.height - anchor >= Self.threshold && page > 1:
            destination = page - 1
        case .bottom where anchor - translation.height >= Self.threshold && page < pages:
            destination = page + 1
        default:
            break
        }
    }

    mutating func finish(
        translation: CGSize, atTop: Bool, atBottom: Bool,
        page: Int, pages: Int, enabled: Bool
    ) -> Int? {
        guard started else { return nil }
        update(translation: translation, atTop: atTop, atBottom: atBottom, page: page, pages: pages, enabled: enabled)
        let target = destination
        reset()
        return target
    }

    mutating func reset() {
        started = false
        edge = nil
        anchor = 0
        destination = nil
    }
}
