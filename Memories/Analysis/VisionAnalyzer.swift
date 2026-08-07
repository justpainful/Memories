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
    /// How the salient subject sits against classical placement, 0...1.
    var composition: Double?
    /// The share of the frame the salient subject occupies, 0...1.
    var subjectProminence: Double?
    var averageColor: Int = 0
}

/// On-device analysis of one image. No network, no model downloads, no server.
///
/// Everything here is Apple's Vision framework running locally, which is the whole reason
/// the app can promise that nothing leaves the phone.
enum VisionAnalyzer {

    /// Everything one decoded frame is worth: the measurements that describe the picture, and
    /// the people found in it.
    ///
    /// The two are returned together because they come out of the same requests. Faces used to
    /// be detected here for the capture-quality number and then detected all over again by the
    /// caller to crop the people out, which on a large library is an entire second face pass
    /// over every photograph — by some way the most expensive thing that was being repeated.
    static func analyze(_ image: UIImage) async -> (analysis: FrameAnalysis, faces: [DetectedFace]) {
        guard let cgImage = image.cgImage else { return (FrameAnalysis(), []) }
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
        // portraits is the one where their eyes are open and it isn't blurred". The same
        // detection also yields the crops that people grouping is built from.
        let findings = await FaceAnalyzer.detect(in: cgImage)
        result.faceCount = findings.count
        result.bestFaceQuality = findings.bestQuality

        // Saliency — what the frame is *of*, and where that thing sits in it.
        if let subject = await salientSubject(in: cgImage) {
            result.subjectProminence = min(1, Double(subject.width * subject.height))
            result.composition = composition(of: subject)
        }

        result.sharpness = sharpness(of: cgImage)
        result.averageColor = AmbientColor.average(of: image) ?? 0
        return (result, findings.faces)
    }

    /// The salient region that stands in for the subject: the largest box either saliency
    /// request can point at.
    ///
    /// Attention comes first because it answers the question the score is actually asking —
    /// where a viewer's eye goes. Objectness is the fallback rather than the default: it
    /// finds objects in frames nobody's eye settles on, which is exactly the case where
    /// attention alone would report no subject at all.
    private static func salientSubject(in cgImage: CGImage) async -> CGRect? {
        if let observation = try? await GenerateAttentionBasedSaliencyImageRequest().perform(on: cgImage),
           let box = largestSalientBox(in: observation) {
            return box
        }
        if let observation = try? await GenerateObjectnessBasedSaliencyImageRequest().perform(on: cgImage) {
            return largestSalientBox(in: observation)
        }
        return nil
    }

    private static func largestSalientBox(in observation: SaliencyImageObservation) -> CGRect? {
        observation.salientObjects
            .map { $0.boundingBox.cgRect }
            .filter { !$0.isEmpty }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    /// How closely the subject's centre lands on a placement people actually use: one of the
    /// four rule-of-thirds intersections, or dead centre.
    ///
    /// This is a rule of thumb about where photographers put things, not a judgement of
    /// whether a photograph works — plenty of good frames ignore it. It is scored shallowly
    /// and weighted lightly for that reason, and only the clearly bad case, a subject whose
    /// centre is hard against the frame edge, is treated as evidence of anything.
    static func composition(of box: CGRect) -> Double {
        let x = Double(box.midX), y = Double(box.midY)
        let third = 1.0 / 3.0
        let anchors: [(Double, Double)] = [
            (third, third), (2 * third, third),
            (third, 2 * third), (2 * third, 2 * third),
            (0.5, 0.5)
        ]

        // No point in the frame is further than about 0.47 from every anchor, so half the
        // frame is the distance at which "badly placed" has already saturated.
        let nearest = anchors.map { hypot(x - $0.0, y - $0.1) }.min() ?? 0.5
        var score = max(0, 1 - nearest / 0.5)

        // A subject centred on the edge is usually half out of shot, or the camera was
        // pointed at something else entirely.
        let edgeDistance = min(min(x, 1 - x), min(y, 1 - y))
        switch edgeDistance {
        case ..<0.08: score -= 0.35
        case ..<0.15: score -= 0.15
        default:      break
        }

        return min(1, max(0, score))
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

    /// Why a frame could not be analyzed, which is not the same question as whether it failed.
    enum Outcome {
        case image(UIImage)
        /// The original lives only in iCloud. Expected, and not an error: indexing does not
        /// download, so the asset keeps its metadata and stops being offered pixel work.
        case inCloud
        /// Photos could not produce a frame for some other reason. Distinguished from
        /// `inCloud` because conflating them was hiding assets from every memory: a single
        /// hiccup marked a perfectly local photo as unavailable, permanently.
        case unavailable
    }

    static func image(for asset: PHAsset, side: CGFloat = 512) async -> Outcome {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false     // never pull originals down while indexing
        // High quality rather than fast: `.fastFormat` can deliver a single result flagged
        // degraded, which a "wait for the final callback" guard then waits for forever.
        options.deliveryMode = .highQualityFormat
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
                guard !resumed else { return }

                // A degraded frame is a placeholder for a better one still on its way, so it
                // is skipped — unless it arrives carrying a cloud flag, an error or a
                // cancellation, which is Photos saying no better one is coming. Waiting for a
                // callback that will never arrive strands the continuation, and a stranded
                // continuation stops the batch, and a stopped batch stops the whole pass.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
                let finished = !degraded
                    || inCloud
                    || info?[PHImageErrorKey] != nil
                    || (info?[PHImageCancelledKey] as? Bool) == true
                guard finished else { return }
                resumed = true

                if let image {
                    continuation.resume(returning: .image(image))
                } else if inCloud {
                    continuation.resume(returning: .inCloud)
                } else {
                    continuation.resume(returning: .unavailable)
                }
            }
        }
    }
}
