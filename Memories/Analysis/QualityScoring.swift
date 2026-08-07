import Foundation

/// The Memory Quality Score.
///
/// No single measure decides whether a frame is worth remembering — a tack-sharp photo of a
/// parking meter is not a memory, and a slightly soft photo of someone laughing is. So the
/// score blends what Vision can judge (aesthetics, face capture quality), what the pixels
/// can tell us (sharpness, exposure), what the file says (resolution, screenshot, burst
/// position), and the one unambiguous human signal available (the user favourited it).
///
/// The result is internal ranking only. The user never sees a number next to a photo.
struct QualityInputs {
    var aesthetics: Double?        // -1...1 from Vision
    var isUtility: Bool = false    // Vision says: document/receipt/screenshot, not a photograph
    var sharpness: Double?         // 0...1
    var faceCount: Int = 0
    var bestFaceQuality: Double?   // 0...1
    var averageColor: Int = 0
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var isScreenshot: Bool = false
    var isVideo: Bool = false
    var isFavorite: Bool = false
    var duplicateCount: Int = 1    // size of this frame's similarity cluster
    var burstPosition: Int = 0     // 0 = first frame of a burst
}

enum QualityScorer {

    static func score(_ input: QualityInputs) -> Double {
        var score = 0.5

        // Aesthetics carries the most weight: it is the only measure that has any opinion
        // about whether a picture is *good* rather than merely well-exposed.
        if let aesthetics = input.aesthetics {
            score += ((aesthetics + 1) / 2 - 0.5) * 0.46
        }

        if let sharpness = input.sharpness {
            score += (sharpness - 0.45) * 0.20
        }

        score += exposureAdjustment(for: input.averageColor)

        // People. A well-captured face is the strongest reason a frame becomes a memory.
        if input.faceCount > 0 {
            score += 0.06
            if let quality = input.bestFaceQuality {
                score += (quality - 0.4) * 0.24
            }
            // A crowd of tiny faces is a group shot, not a portrait; don't over-reward count.
            if input.faceCount > 4 { score -= 0.02 }
        }

        score += resolutionAdjustment(width: input.pixelWidth, height: input.pixelHeight)

        // Penalties.
        if input.isScreenshot { score -= 0.34 }
        if input.isUtility { score -= 0.18 }
        if input.duplicateCount > 1 {
            score -= min(0.10, 0.02 * Double(input.duplicateCount - 1))
        }
        if input.burstPosition > 0 {
            // Later frames of a burst are usually the ones that were meant to be deleted.
            score -= min(0.06, 0.015 * Double(input.burstPosition))
        }

        // The user's own signal outranks anything computed.
        if input.isFavorite { score += 0.18 }

        return min(1, max(0, score))
    }

    /// Very dark and blown-out frames both read as mistakes. Mid-tones sit at no penalty.
    private static func exposureAdjustment(for packed: Int) -> Double {
        guard packed > 0 else { return 0 }
        let red = Double((packed >> 16) & 0xFF) / 255
        let green = Double((packed >> 8) & 0xFF) / 255
        let blue = Double(packed & 0xFF) / 255
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue

        switch luminance {
        case ..<0.06:  return -0.16
        case ..<0.14:  return -0.07
        case 0.94...:  return -0.14
        case 0.86...:  return -0.05
        default:       return 0.02
        }
    }

    /// Rewards real captures over thumbnails and tiny saved images, then stops caring —
    /// a 48MP photo is not twice the memory a 12MP one is.
    private static func resolutionAdjustment(width: Int, height: Int) -> Double {
        let megapixels = Double(width * height) / 1_000_000
        switch megapixels {
        case ..<0.4:  return -0.20
        case ..<1.2:  return -0.08
        case ..<3.0:  return -0.02
        case ..<8.0:  return 0.02
        default:      return 0.05
        }
    }
}
