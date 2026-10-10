import Foundation

struct TranscriptFollow {
    private(set) var isFollowing = true
    mutating func pause() { isFollowing = false }
    mutating func resume() { isFollowing = true }
}

enum CarouselIndex {
    static func wrapped(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index % count) + count) % count
    }
}
