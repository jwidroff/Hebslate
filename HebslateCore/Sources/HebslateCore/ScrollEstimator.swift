import Foundation

/// Estimates how far the chat scrolled between two frames, so the app only
/// reads frames that actually show new content (while keeping enough overlap
/// for the stitcher to line them up).
///
/// Each frame is reduced to a "row profile": the average brightness of every
/// row of a small grayscale thumbnail of the chat area. Scrolling shifts that
/// profile up or down; the shift with the lowest difference wins.
public enum ScrollEstimator {

    public struct Estimate: Sendable, Equatable {
        /// Rows the content moved. Positive = content moved up (user scrolled
        /// toward newer messages), negative = moved down (toward older ones).
        public var shift: Int
        /// Mean absolute brightness difference (0...255) at that shift.
        /// Large values mean the frames don't really overlap.
        public var error: Double
    }

    public static func estimate(previous: [Double], current: [Double], maxShift: Int? = nil) -> Estimate {
        let n = Swift.min(previous.count, current.count)
        guard n > 4 else { return Estimate(shift: 0, error: .infinity) }
        let limit = Swift.min(maxShift ?? (n * 3 / 4), n - n / 5)
        var best = Estimate(shift: 0, error: .infinity)
        for s in -limit...limit {
            // current[r] should equal previous[r + s]
            let lo = Swift.max(0, -s), hi = Swift.min(n, n - s)
            let overlap = hi - lo
            guard overlap >= n / 5 else { continue }
            var sum = 0.0
            for r in lo..<hi { sum += abs(current[r] - previous[r + s]) }
            // Tiny bias toward small shifts so flat regions don't cause jumps.
            let err = sum / Double(overlap) + Double(abs(s)) * 0.0005
            if err < best.error { best = Estimate(shift: s, error: err) }
        }
        return best
    }

    /// Decides which sampled frames to keep.
    ///
    /// A frame is kept when the content scrolled at least `keepFraction` of
    /// the chat height since the last kept frame, when the frames no longer
    /// match (`error` above `jumpError`, i.e. a fast fling or a different
    /// screen), or when it is the last frame. The first frame is always kept.
    public struct Selector: Sendable {
        public var keepFraction: Double
        public var jumpError: Double
        private var lastKeptProfile: [Double]?
        private var previousProfile: [Double]?

        public init(keepFraction: Double = 0.45, jumpError: Double = 18) {
            self.keepFraction = keepFraction
            self.jumpError = jumpError
        }

        public mutating func shouldKeep(_ profile: [Double], isLast: Bool = false) -> Bool {
            defer { previousProfile = profile }
            guard let anchor = lastKeptProfile, let prev = previousProfile else {
                lastKeptProfile = profile
                return true
            }
            // How far content has moved since the last kept frame, measured
            // directly against that frame's own profile — not accumulated
            // from many small steps — so there's no drift and no guessing
            // about which raw sample marks "a full screen of new content."
            // The next kept frame starts right at that measured point, with
            // only a small overlap left for the stitcher to align on.
            let sinceAnchor = ScrollEstimator.estimate(previous: anchor, current: profile)
            // A fling or scene change is still judged frame-to-frame: nearby
            // raw samples that suddenly stop correlating, independent of how
            // far the anchor comparison above thinks things have moved.
            let stepError = ScrollEstimator.estimate(previous: prev, current: profile).error
            let needed = Int(Double(profile.count) * keepFraction)
            if abs(sinceAnchor.shift) >= needed || stepError > jumpError || (isLast && abs(sinceAnchor.shift) > 0) {
                lastKeptProfile = profile
                return true
            }
            return false
        }
    }
}
