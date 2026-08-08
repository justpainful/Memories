import AVFoundation
import Foundation
import Photos

/// Where a file came from, as far as its name and metadata will admit.
///
/// Photos records when an asset entered *your library*, which for anything saved from
/// another app is the day you saved it, not the day it was taken. That is why a clip a
/// friend sent from a holiday three years ago lands in Memories as if it happened last
/// Tuesday. Nothing in PhotoKit reports this, so it has to be inferred — and inference is
/// exactly the kind of thing that should be shown to the user rather than acted on silently.
enum SourcePlatform: String, Codable, CaseIterable, Sendable {
    case camera
    case whatsapp
    case telegram
    case snapchat
    case instagram
    case facebook
    case messenger
    case twitter
    case tiktok
    case screenshot
    case screenRecording
    case airdrop
    case download

    var title: String {
        switch self {
        case .camera:          return "This \(DeviceName.current)"
        case .whatsapp:        return "WhatsApp"
        case .telegram:        return "Telegram"
        case .snapchat:        return "Snapchat"
        case .instagram:       return "Instagram"
        case .facebook:        return "Facebook"
        case .messenger:       return "Messenger"
        case .twitter:         return "X"
        case .tiktok:          return "TikTok"
        case .screenshot:      return "Screenshot"
        case .screenRecording: return "Screen Recording"
        case .airdrop:         return "AirDrop"
        case .download:        return "Saved from another app"
        }
    }

    var symbol: String {
        switch self {
        case .camera:          return "camera"
        case .screenshot:      return "camera.viewfinder"
        case .screenRecording: return "record.circle"
        case .airdrop:         return "airplayaudio"
        default:               return "square.and.arrow.down"
        }
    }

    /// True when the asset was made by this phone's camera, which is the only case where the
    /// library's own date can be trusted without further checking.
    var isOriginalCapture: Bool { self == .camera }
}

/// What could be worked out about one asset's origin.
struct AssetProvenance: Sendable {
    var platform: SourcePlatform = .camera
    var originalFilename: String?
    /// The date the footage was actually recorded, when it can be recovered and it disagrees
    /// with the date Photos holds.
    var capturedDate: Date?
}

enum ProvenanceReader {

    // MARK: Filenames

    /// Messaging apps encode their origin, and often the original date, straight into the
    /// filename. It is the only trace that survives being saved to the camera roll.
    ///
    /// These are patterns, not guarantees — a file can always be renamed — so what comes out
    /// of here is labelled "saved from" in the UI and never used to overrule anything.
    static func platform(forFilename name: String) -> SourcePlatform? {
        let lower = name.lowercased()

        // IMG-20230101-WA0001.jpg / VID-20230101-WA0002.mp4
        if lower.contains("-wa") && (lower.hasPrefix("img-") || lower.hasPrefix("vid-")) {
            return .whatsapp
        }
        if lower.hasPrefix("snapchat") { return .snapchat }
        if lower.hasPrefix("fb_img") || lower.hasPrefix("fb_vid") { return .facebook }
        if lower.hasPrefix("received_") { return .messenger }
        // photo_2023-01-01_12-00-00.jpg / video_2023-...
        if lower.hasPrefix("photo_20") || lower.hasPrefix("video_20") { return .telegram }
        if lower.contains("instagram") { return .instagram }
        if lower.contains("tiktok") || lower.hasPrefix("ssstik") { return .tiktok }
        if lower.hasPrefix("twitter") || lower.hasPrefix("gif_") { return .twitter }
        if lower.hasPrefix("rpreplay") { return .screenRecording }
        if lower.hasPrefix("screenshot") || lower.hasPrefix("simulator screen") { return .screenshot }
        // IMG_1234.HEIC, IMG_1234.MOV, IMG_E1234.JPG (edited) — the camera's own naming.
        if lower.hasPrefix("img_") || lower.hasPrefix("dsc") || lower.hasPrefix("mvimg") {
            return .camera
        }
        return nil
    }

    /// WhatsApp writes the send date into the name: `IMG-20230101-WA0001.jpg`. That date is
    /// closer to the truth than the day it was saved, though it is still the day it was sent.
    static func dateFromFilename(_ name: String) -> Date? {
        let digits = name.drop { !$0.isNumber }.prefix(8)
        guard digits.count == 8, let value = Int(digits) else { return nil }

        let year = value / 10_000
        let month = (value / 100) % 100
        let day = value % 100
        guard (1990...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        return Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
    }

    // MARK: Reading an asset

    /// Everything that can be learned without decoding pixels.
    ///
    /// Resource metadata is cheap; the video container is not, so it is only opened when the
    /// asset is a video and the cheaper answers disagree or run out.
    static func read(_ asset: PHAsset, includeVideoContainer: Bool = true) async -> AssetProvenance {
        var result = AssetProvenance()

        let resources = PHAssetResource.assetResources(for: asset)
        let filename = resources.first?.originalFilename
        result.originalFilename = filename

        if asset.mediaSubtypes.contains(.photoScreenshot) {
            result.platform = .screenshot
        } else if let filename, let guess = platform(forFilename: filename) {
            result.platform = guess
        } else if asset.sourceType.contains(.typeCloudShared) {
            result.platform = .airdrop
        } else {
            result.platform = .download
        }

        if let filename, !result.platform.isOriginalCapture,
           let named = dateFromFilename(filename) {
            result.capturedDate = named
        }

        if includeVideoContainer, asset.mediaType == .video, !result.platform.isOriginalCapture {
            if let recorded = await recordingDate(of: asset) {
                result.capturedDate = recorded
            }
        }
        return result
    }

    /// The date written inside the video file itself.
    ///
    /// QuickTime and MP4 both carry a creation date in the container, set by whatever recorded
    /// it. It survives being sent through a messaging app when the library's own date does
    /// not, which makes it the best answer available for "when did this actually happen".
    static func recordingDate(of asset: PHAsset) async -> Date? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false   // never pull the original down to read a date
        options.deliveryMode = .fastFormat

        let avAsset: AVAsset? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
        guard let avAsset else { return nil }

        if let date = try? await avAsset.load(.creationDate),
           let value = try? await date.load(.dateValue) {
            return value
        }

        // Some encoders write the date only into the QuickTime-specific key.
        guard let metadata = try? await avAsset.load(.metadata) else { return nil }
        for item in metadata where item.identifier == .quickTimeMetadataCreationDate {
            if let value = try? await item.load(.dateValue) { return value }
        }
        return nil
    }
}
