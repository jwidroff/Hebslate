import AVFoundation
import CoreGraphics
import HebslateCore

/// A frame of the screen recording that shows new chat content.
struct KeyFrame: @unchecked Sendable {
    let index: Int
    let time: Double
    let image: CGImage
}

/// Pulls frames out of a screen recording and keeps only the ones that show
/// new content: every time the chat has scrolled roughly half a screen (so
/// consecutive kept frames still overlap and can be stitched), or when the
/// picture jumps.
struct FrameExtractor {
    /// How often the video is sampled before filtering. Kept short so a fast
    /// scroll never moves more than a fraction of the chat height between two
    /// raw samples — otherwise the scroll estimate can't measure it and that
    /// content never appears in any frame at all.
    var sampleInterval: Double = 0.1
    var keepFraction: Double = 0.45
    var layout: LineGrouper.Layout = .init()

    enum ExtractError: LocalizedError {
        case noVideoTrack
        var errorDescription: String? { "That file doesn't contain a video." }
    }

    func keyFrames(from url: URL, progress: @Sendable (Double) -> Void) async throws -> [KeyFrame] {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw ExtractError.noVideoTrack }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ExtractError.noVideoTrack }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        var times: [CMTime] = []
        var t = 0.0
        while t < duration {
            times.append(CMTime(seconds: t, preferredTimescale: 600))
            t += sampleInterval
        }
        // Make sure the very end of the recording is included.
        times.append(CMTime(seconds: max(0, duration - 0.05), preferredTimescale: 600))

        var selector = ScrollEstimator.Selector(keepFraction: keepFraction)
        var kept: [KeyFrame] = []
        var pending: KeyFrame?   // last skipped frame, kept if the video ends mid-scroll
        var sampled = 0

        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            sampled += 1
            progress(Double(sampled) / Double(times.count))
            guard let image = try? result.image else { continue }
            let frame = KeyFrame(index: sampled - 1, time: (try? result.actualTime.seconds) ?? 0, image: image)
            let isLast = sampled == times.count
            if selector.shouldKeep(rowProfile(of: image), isLast: isLast) {
                kept.append(frame)
                pending = nil
            } else {
                pending = frame
            }
        }
        if let pending, kept.last?.index != pending.index { kept.append(pending) }
        return kept
    }

    /// Average brightness per row of the chat area, on a small thumbnail.
    func rowProfile(of image: CGImage) -> [Double] {
        let width = 48, height = 320
        let topPx = Int(Double(image.height) * layout.chatTop)
        let bottomPx = Int(Double(image.height) * layout.chatBottom)
        let crop = CGRect(x: 0, y: topPx, width: image.width, height: max(1, bottomPx - topPx))
        guard let chat = image.cropping(to: crop) else { return [] }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(chat, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        // Bitmap row 0 is the top of the image.
        return (0..<height).map { row in
            var sum = 0
            for x in 0..<width { sum += Int(pixels[row * width + x]) }
            return Double(sum) / Double(width)
        }
    }
}
