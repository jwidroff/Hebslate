import Foundation

/// Rebuilds one continuous conversation out of overlapping frame readings.
///
/// While the user scrolls, consecutive frames show mostly the same bubbles,
/// shifted up or down. For every new frame the stitcher finds the offset at
/// which the frame's messages line up with the conversation built so far
/// (fuzzy text matching, same bubble side), then:
///
/// * messages that line up with existing ones are merged (a complete reading
///   replaces a cut-off one; translations are kept unless the text changed);
/// * messages hanging off the top are prepended, ones hanging off the bottom
///   are appended.
///
/// Only the newly added / changed messages have `translation == nil`, so the
/// translator only ever translates lines it has not translated before.
public struct ConversationStitcher: Sendable {

    public private(set) var messages: [ChatMessage] = []

    /// Similarity (0...1) needed to treat two readings as the same bubble.
    public var matchThreshold: Double = 0.72
    /// Share of overlapping positions that must match for an alignment to count.
    public var minimumMatchedFraction: Double = 0.6

    private var contactNameVotes: [String: Int] = [:]
    /// Position (in non-gap index space) where the previous frame's first
    /// message landed. Used to prefer nearby alignments.
    private var lastAnchor: Int?
    /// +1 scrolling toward newer messages, -1 toward older, 0 unknown.
    public private(set) var direction: Int = 0

    public init() {}

    public var contactName: String? {
        contactNameVotes.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key
    }

    public struct Result: Sendable, Equatable {
        public var matched = 0
        public var prepended = 0
        public var appended = 0
        public var updated = 0
        public var foundOverlap = true
    }

    @discardableResult
    public mutating func add(_ reading: FrameReading) -> Result {
        if let name = reading.contactName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            contactNameVotes[name, default: 0] += 1
        }
        let frame = reading.messages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !frame.isEmpty else { return Result(foundOverlap: false) }

        // Work in "non-gap" index space so gap markers never take part in matching.
        let real = messages.indices.filter { !messages[$0].isGapMarker }
        var result = Result()

        if real.isEmpty {
            messages.append(contentsOf: frame.map { ChatMessage($0) })
            lastAnchor = 0
            result.appended = frame.count
            return result
        }

        let frameNorm = frame.map { TextSimilarity.normalize($0.text) }
        let existingNorm = real.map { TextSimilarity.normalize(messages[$0].original) }

        guard let best = bestAlignment(frame: frame, frameNorm: frameNorm,
                                       existingIdx: real, existingNorm: existingNorm) else {
            // No overlap at all: the user scrolled faster than we sampled.
            result.foundOverlap = false
            if direction < 0 {
                messages.insert(contentsOf: frame.map { ChatMessage($0) } + [ChatMessage.gap()], at: 0)
                result.prepended = frame.count
                lastAnchor = 0
            } else {
                messages.append(ChatMessage.gap())
                messages.append(contentsOf: frame.map { ChatMessage($0) })
                result.appended = frame.count
                lastAnchor = real.count
            }
            return result
        }

        let k = best.offset
        let n = real.count

        // 1. Merge overlapping positions.
        for (i, f) in frame.enumerated() {
            let j = k + i
            guard j >= 0 && j < n else { continue }
            let existing = messages[real[j]]
            if best.matches.contains(i) {
                result.matched += 1
                if merge(f, fNorm: frameNorm[i], into: real[j]) { result.updated += 1 }
            } else if f.side == existing.side && (f.isPartial || existing.isPartial) {
                // The alignment is confirmed by the other messages, so a
                // cut-off bubble in this slot is the same bubble.
                if merge(f, fNorm: frameNorm[i], into: real[j]) { result.updated += 1 }
            }
            // Other positions inside the overlap that did not match are
            // treated as OCR noise; the existing reading is kept.
        }

        // 2. Append messages below the known conversation.
        let appendFrom = Swift.max(0, n - k)
        if appendFrom < frame.count {
            let tail = frame[appendFrom...].map { ChatMessage($0) }
            let insertAt = real[n - 1] + 1
            messages.insert(contentsOf: tail, at: insertAt)
            result.appended = tail.count
        }

        // 3. Prepend messages above the known conversation.
        if k < 0 {
            let head = frame[0..<Swift.min(-k, frame.count)].map { ChatMessage($0) }
            messages.insert(contentsOf: head, at: real[0])
            result.prepended = head.count
        }

        if let last = lastAnchor {
            let delta = k - last
            if delta > 0 { direction = 1 } else if delta < 0 { direction = -1 }
        }
        lastAnchor = Swift.max(k, 0)
        return result
    }

    /// Adds every reading in order.
    public mutating func add(contentsOf readings: [FrameReading]) {
        for r in readings { add(r) }
    }

    /// Replace translations (by message id) coming back from the translator.
    public mutating func applyTranslations(_ translations: [UUID: String]) {
        for i in messages.indices {
            if let t = translations[messages[i].id] { messages[i].translation = t }
        }
    }

    /// Replace per-overlay translations (by message id, then overlay index)
    /// for image messages. Once every overlay of a message has a
    /// translation, `translation` itself is set to their join, so sharing /
    /// copying the transcript still has something to show for that bubble.
    public mutating func applyOverlayTranslations(_ translations: [UUID: [String]]) {
        for i in messages.indices {
            guard let list = translations[messages[i].id] else { continue }
            for j in messages[i].imageOverlays.indices where j < list.count {
                messages[i].imageOverlays[j].translation = list[j]
            }
            if messages[i].translation == nil, !messages[i].imageOverlays.isEmpty,
               messages[i].imageOverlays.allSatisfy({ $0.translation != nil }) {
                messages[i].translation = messages[i].imageOverlays.compactMap(\.translation).joined(separator: "\n")
            }
        }
    }

    public var untranslated: [ChatMessage] { messages.filter(\.needsTranslation) }

    /// Removes a message the user deleted (e.g. junk read from a non-chat frame).
    public mutating func remove(id: UUID) {
        messages.removeAll { $0.id == id }
    }

    // MARK: - Alignment

    struct Alignment {
        var offset: Int
        var matches: Set<Int>
        var score: Double
    }

    func similarity(_ f: FrameMessage, _ fNorm: [Unicode.Scalar],
                    _ a: ChatMessage, _ aNorm: [Unicode.Scalar]) -> Double {
        guard f.side == a.side else { return 0 }
        if !f.isPartial && !a.isPartial {
            let r = TextSimilarity.ratio(fNorm, aNorm)
            if r >= matchThreshold { return r }
            // Edge detection is heuristic: a bubble may have been cut off
            // without being flagged. If one text is clearly the start or end
            // of the other, still treat them as the same bubble.
            let (short, long) = fNorm.count <= aNorm.count ? (fNorm, aNorm) : (aNorm, fNorm)
            guard short.count >= 8 else { return r }
            let p = TextSimilarity.fragmentRatio(short, in: long, position: .prefix)
            let s = TextSimilarity.fragmentRatio(short, in: long, position: .suffix)
            return Swift.max(r, Swift.max(p, s) * 0.95)
        }
        // At least one side is a fragment: compare it against the matching
        // part (start / end / middle) of the other.
        if fNorm.count <= aNorm.count && f.isPartial {
            return TextSimilarity.fragmentRatio(fNorm, in: aNorm, position: Self.position(top: f.cutOffTop, bottom: f.cutOffBottom))
        }
        if a.isPartial {
            return TextSimilarity.fragmentRatio(aNorm, in: fNorm, position: Self.position(top: a.cutOffTop, bottom: a.cutOffBottom))
        }
        return TextSimilarity.fragmentRatio(fNorm, in: aNorm, position: Self.position(top: f.cutOffTop, bottom: f.cutOffBottom))
    }

    static func position(top: Bool, bottom: Bool) -> TextSimilarity.FragmentPosition {
        switch (top, bottom) {
        case (true, true): return .anywhere
        case (true, false): return .suffix
        default: return .prefix
        }
    }

    func bestAlignment(frame: [FrameMessage], frameNorm: [[Unicode.Scalar]],
                       existingIdx: [Int], existingNorm: [[Unicode.Scalar]]) -> Alignment? {
        let m = frame.count
        let n = existingIdx.count
        let fullRange = (-(m - 1))...(n - 1)

        var simCache: [Int: Double] = [:]
        func sim(_ i: Int, _ j: Int) -> Double {
            let key = i &* 1_000_003 &+ j
            if let v = simCache[key] { return v }
            let v = similarity(frame[i], frameNorm[i], messages[existingIdx[j]], existingNorm[j])
            simCache[key] = v
            return v
        }

        func evaluate(_ range: ClosedRange<Int>) -> Alignment? {
            var best: Alignment?
            for k in range {
                var matches = Set<Int>()
                var overlap = 0
                var simSum = 0.0
                for i in 0..<m {
                    let j = k + i
                    guard j >= 0 && j < n else { continue }
                    let s = sim(i, j)
                    if s >= matchThreshold {
                        matches.insert(i); simSum += s; overlap += 1
                    } else if !frame[i].isPartial && !messages[existingIdx[j]].isPartial {
                        // Cut-off bubbles (often just a word or two) are too
                        // unreliable to count against an alignment.
                        overlap += 1
                    }
                }
                guard !matches.isEmpty,
                      Double(matches.count) / Double(overlap) >= minimumMatchedFraction else { continue }
                // Reward matched messages, punish mismatches inside the
                // overlap, and slightly prefer offsets near the previous frame
                // (frames are consecutive, so big jumps are unlikely).
                let mismatches = overlap - matches.count
                var score = simSum * 2 - Double(mismatches)
                if let last = lastAnchor {
                    score -= Double(abs(k - last)) * 0.01
                }
                if best == nil || score > best!.score {
                    best = Alignment(offset: k, matches: matches, score: score)
                }
            }
            return best
        }

        // Search close to the last position first (fast path for long chats),
        // then fall back to the whole conversation.
        if let last = lastAnchor {
            let window = m + 30
            let lo = Swift.max(fullRange.lowerBound, last - window)
            let hi = Swift.min(fullRange.upperBound, last + window)
            if lo <= hi, let a = evaluate(lo...hi), a.matches.count >= Swift.min(2, m) {
                return a
            }
        }
        return evaluate(fullRange)
    }

    // MARK: - Merging

    /// Returns true when the stored message changed.
    private mutating func merge(_ f: FrameMessage, fNorm: [Unicode.Scalar], into index: Int) -> Bool {
        var a = messages[index]
        var changed = false
        let aLen = TextSimilarity.normalize(a.original).count

        let replace: Bool
        switch (a.isPartial, f.isPartial) {
        case (true, false):
            replace = true                                     // complete beats cut-off
        case (true, true):
            replace = fNorm.count > aLen                       // longer fragment wins
        case (false, false):
            replace = Double(fNorm.count) > Double(aLen) * 1.15 // much longer = better read
        case (false, true):
            replace = false
        }

        if replace && a.original != f.text {
            let same = TextSimilarity.ratio(TextSimilarity.normalize(a.original), fNorm) > 0.98
            a.original = f.text
            if !same { a.translation = nil }
            changed = true
        }
        if replace {
            if a.cutOffTop != f.cutOffTop || a.cutOffBottom != f.cutOffBottom { changed = true }
            a.cutOffTop = f.cutOffTop
            a.cutOffBottom = f.cutOffBottom
            // A fresh OCR pass over the same photo; take its crop and
            // overlays wholesale rather than trying to merge them piecemeal.
            a.imageData = f.imageData
            a.imageOverlays = f.imageOverlays
        }
        if a.time == nil, let t = f.time { a.time = t; changed = true }
        if a.sender == nil, let s = f.sender { a.sender = s; changed = true }

        messages[index] = a
        return changed
    }
}
