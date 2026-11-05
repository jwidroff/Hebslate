import Foundation

/// Fuzzy text comparison tuned for OCR output of chat bubbles.
///
/// The same bubble read from two different frames rarely produces identical
/// strings: OCR may drop punctuation, confuse similar Hebrew letters, or split
/// lines differently. These helpers normalize text and score similarity in
/// 0...1 so the stitcher can tell "same message, read twice" apart from
/// "different message".
public enum TextSimilarity {

    /// Lower-cases, strips Hebrew niqqud / cantillation marks, punctuation,
    /// emoji-variation selectors and collapses whitespace.
    public static func normalize(_ s: String) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(s.unicodeScalars.count)
        var lastWasSpace = true
        for scalar in s.lowercased().unicodeScalars {
            let v = scalar.value
            // Hebrew points & cantillation (U+0591–U+05C7), bidi controls,
            // zero-width chars and variation selectors carry no meaning here.
            if (0x0591...0x05C7).contains(v) { continue }
            if (0x200B...0x200F).contains(v) || (0x202A...0x202E).contains(v)
                || (0x2066...0x2069).contains(v) || (0xFE00...0xFE0F).contains(v) { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace { out.append(" ") }
                lastWasSpace = true
                continue
            }
            if CharacterSet.punctuationCharacters.contains(scalar) { continue }
            out.append(scalar)
            lastWasSpace = false
        }
        if out.last == " " { out.removeLast() }
        return out
    }

    /// Classic Levenshtein edit distance with a single rolling row.
    public static func levenshtein(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            let ai = a[i - 1]
            for j in 1...b.count {
                let cost = ai == b[j - 1] ? 0 : 1
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// 1 = identical, 0 = completely different.
    public static func ratio(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Double {
        let longest = Swift.max(a.count, b.count)
        if longest == 0 { return 1 }
        // Cheap early-out: lengths too different to ever score well.
        if Double(Swift.min(a.count, b.count)) / Double(longest) < 0.5 { return 0 }
        return 1 - Double(levenshtein(a, b)) / Double(longest)
    }

    public static func ratio(_ a: String, _ b: String) -> Double {
        ratio(normalize(a), normalize(b))
    }

    /// Where the visible fragment of a cut-off bubble sits inside the full text.
    public enum FragmentPosition {
        /// Bubble cut at the bottom of the screen: we saw its beginning.
        case prefix
        /// Bubble cut at the top of the screen: we saw its end.
        case suffix
        /// Cut at both ends (very tall bubble): we saw some middle part.
        case anywhere
    }

    /// Scores how well `fragment` matches part of `full`.
    public static func fragmentRatio(_ fragment: [Unicode.Scalar],
                                     in full: [Unicode.Scalar],
                                     position: FragmentPosition) -> Double {
        guard !fragment.isEmpty, !full.isEmpty else { return 0 }
        if fragment.count >= full.count { return ratio(fragment, full) }
        // Very short fragments ("ok", one emoji) match too much by chance.
        let reliability = fragment.count < 4 ? 0.6 : 1.0
        let n = fragment.count
        var best = 0.0
        // Allow the window to be a bit longer/shorter than the fragment since
        // OCR may add/drop characters.
        let slack = Swift.max(1, n / 5)
        let lengths = Swift.max(1, n - slack)...Swift.min(full.count, n + slack)
        switch position {
        case .prefix:
            for len in lengths { best = Swift.max(best, ratio(fragment, Array(full.prefix(len)))) }
        case .suffix:
            for len in lengths { best = Swift.max(best, ratio(fragment, Array(full.suffix(len)))) }
        case .anywhere:
            let step = Swift.max(1, n / 8)
            var start = 0
            while start + n <= full.count {
                best = Swift.max(best, ratio(fragment, Array(full[start..<(start + n)])))
                if best > 0.97 { break }
                start += step
            }
            best = Swift.max(best, ratio(fragment, Array(full.suffix(n))))
        }
        return best * reliability
    }
}
