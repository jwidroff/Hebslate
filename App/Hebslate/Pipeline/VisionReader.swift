import CoreGraphics
import Foundation
import HebslateCore
import Vision

/// Reads a WhatsApp frame on-device: Apple Vision finds the text lines, and
/// `BubbleLineAssembler` turns them into a `FrameReading` using bubble colors
/// and WhatsApp's layout.
struct VisionReader {
    var layout: LineGrouper.Layout

    /// Hebrew recognition depends on the iOS version, so check at runtime.
    static var hebrewLanguageCode: String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        return supported.first { $0.hasPrefix("he") || $0.hasPrefix("iw") }
    }

    static var supportsHebrew: Bool { hebrewLanguageCode != nil }

    enum ReadError: LocalizedError {
        case hebrewUnsupported
        var errorDescription: String? {
            "On-device Hebrew text recognition isn't available on this iOS version. Choose Claude or Google as the reader in Settings."
        }
    }

    func read(_ frame: KeyFrame) throws -> FrameReading {
        guard let hebrew = Self.hebrewLanguageCode else { throw ReadError.hebrewUnsupported }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [hebrew, "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: frame.image, options: [:]).perform([request])

        let rawLines: [(text: String, box: NormRect)] = (request.results ?? []).compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let b = obs.boundingBox   // normalized, origin bottom-left
            let box = NormRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
            return (candidate.string, box)
        }
        return BubbleLineAssembler(layout: layout).assemble(rawLines, frame: frame)
    }
}
