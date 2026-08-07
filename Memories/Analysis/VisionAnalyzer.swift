import CoreImage
import Photos
import UIKit
import Vision

/// Everything the pipeline learns about a single frame, in one pass.
struct FrameAnalysis: Sendable {
    var featureVector: FeatureVector = FeatureVector(values: [])
    var aesthetics: Double?
    /// Vision's own judgement that a frame is a document, receipt or screenshot rather than
    /// a photograph. Useful beyond the screenshot flag, which only catches real screenshots.
    var isUtility: Bool = false
    var faceCount: Int = 0
    var bestFaceQuality: Double?
    var sharpness: Double?
    var averageColor: Int = 0
}

/// On-device analysis of one image. No network, no model downloads, no server.
///
/// Everything here is Apple's Vision framework running locally, which is the whole reason
/// the app can promise that nothing leaves the phone.
enum VisionAnalyzer {

    static func analyze(_ image: UIImage) async -> FrameAnalysis {
        guard let cgImage = image.cgImage else { return FrameAnalysis() }
        var result = FrameAnalysis()

        // Feature print — the basis for "these are the same shot".
        if let observation = try? await GenerateImageFeaturePrintRequest().perform(on: cgImage) {
            result.featureVector = observation.featureVector
        }

        // Aesthetics — Apple's own scoring of how good a frame looks.
        if let observation = try? await CalculateImageAestheticsScoresRequest().perform(on: cgImage) {
            result.aesthetics = Double(observation.overallScore)
            result.isUtility = observation.isUtility
        }

        // Face capture quality — designed exactly for "which of these near-identical
        // portraits is the one where their eyes are open and it isn't blurred".
        if let faces = try? await DetectFaceCaptureQualityRequest().perform(on: cgImage) {
            result.faceCount = faces.count
            result.bestFaceQuality = faces.compactMap { $0.captureQuality?.score }
                .map(Double.init)
                .max()
        }

        result.sharpness = sharpness(of: cgImage)
        result.averageColor = AmbientColor.average(of: image) ?? 0
        return result
    }

    /// Variance of the Laplacian, the standard cheap focus measure, computed on a small
    /// grayscale copy so it costs almost nothing next to the Vision requests.
    static func sharpness(of cgImage: CGImage) -> Double? {
        let side = 96
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(data: &pixels,
                                      width: side,
                                      height: side,
                                      bitsPerComponent: 8,
                                      bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var values: [Double] = []
        values.reserveCapacity((side - 2) * (side - 2))
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let index = y * side + x
                let laplacian = 4 * Double(pixels[index])
                    - Double(pixels[index - 1]) - Double(pixels[index + 1])
                    - Double(pixels[index - side]) - Double(pixels[index + side])
                values.append(laplacian)
            }
        }
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)

        // Squash into 0...1; 2000 is around the point where frames stop looking soft.
        return min(1, variance / 2000)
    }
}

/// Fetches images for indexing off the main actor, with the network firmly switched off.
///
/// The shared `PhotoImageLoader` is main-actor bound and keeps a UI cache; indexing wants
/// neither, so it has its own tiny path that never warms that cache.
enum IndexingImageProvider {
    /// `nil` here means "not available on this device", which is a normal outcome for an
    /// iCloud-only asset, not an error. Such assets keep their metadata and skip pixel work.
    static func image(for asset: PHAsset, side: CGFloat = 512) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false     // never pull originals down while indexing
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: side, height: side),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !degraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}
