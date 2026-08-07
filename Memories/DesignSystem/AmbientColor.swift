import CoreImage
import SwiftUI
import UIKit

/// Pulls a single representative colour out of a photograph.
///
/// This is what lets the photographs give the screen its colour: the hero memory's cover
/// tints a faint wash behind the top of the feed, so the app takes on the mood of what you
/// are looking at while the chrome itself stays neutral. The colour is deliberately pulled
/// well away from full saturation — it is atmosphere, not a brand gradient.
enum AmbientColor {
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])
    private static var cache: [String: Int] = [:]

    /// Packed 0xRRGGBB, or nil if the image cannot be reduced.
    static func average(of image: UIImage) -> Int? {
        guard let input = CIImage(image: image) else { return nil }
        let extent = CIVector(x: input.extent.origin.x, y: input.extent.origin.y,
                              z: input.extent.size.width, w: input.extent.size.height)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: input,
                                                 kCIInputExtentKey: extent]),
              let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output,
                       toBitmap: &pixel,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        return (Int(pixel[0]) << 16) | (Int(pixel[1]) << 8) | Int(pixel[2])
    }

    static func cachedAverage(forIdentifier identifier: String) -> Int? {
        cache[identifier]
    }

    static func store(_ packed: Int, forIdentifier identifier: String) {
        if cache.count > 400 { cache.removeAll(keepingCapacity: true) }
        cache[identifier] = packed
    }

    /// Turn a packed average into something usable behind content: keep the hue, discard the
    /// brightness and most of the saturation.
    static func wash(from packed: Int, in scheme: ColorScheme) -> Color {
        let base = UIColor(hex: UInt32(packed))
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return .clear
        }
        return Color(uiColor: UIColor(
            hue: hue,
            saturation: min(saturation, 0.42),
            brightness: scheme == .dark ? 0.30 : 0.92,
            alpha: 1
        ))
    }
}

/// The faint colour bleed behind the top of the feed. Sits under content, never over it.
struct AmbientWash: View {
    let identifier: String?

    /// The height of the container the wash bleeds down, not the height of the wash itself.
    ///
    /// The band used to be a flat 340 points, which is roughly a third of a portrait phone and
    /// was therefore right on exactly one shape of screen. Turned sideways it covered almost the
    /// whole of a 393-point-tall window, so the gradient's `Palette.canvas` end never arrived and
    /// the entire feed sat on a tinted field instead of on paper; on a 1366-point iPad it stopped
    /// a quarter of the way down, just under the date headline, as a visible horizontal seam. A
    /// fraction of the container is the same picture at every size.
    ///
    /// Zero means the caller has not measured yet — true for one frame and in previews — and
    /// falls back to the number the band has always been.
    var containerHeight: CGFloat = 0

    @Environment(\.colorScheme) private var scheme
    /// Increase Contrast exists to take decorative tints out from behind text, and this tint is
    /// drawn directly behind the feed's headline. Reduce Transparency asks for the same thing in
    /// different words.
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var packed: Int?

    var body: some View {
        LinearGradient(
            colors: [washColor.opacity(scheme == .dark ? 0.55 : 0.75), Palette.canvas],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: bandHeight)
        .frame(maxWidth: .infinity, alignment: .top)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: packed)
        .task(id: identifier) { await resolve() }
    }

    /// A third of the window, held between the two sizes at which the effect still reads as a
    /// bleed: below about 240 points it is a stripe, above about 460 it is a background.
    private var bandHeight: CGFloat {
        guard containerHeight > 0 else { return 340 }
        return min(max(containerHeight * 0.32, 240), 460)
    }

    private var washColor: Color {
        // The colour is sampled from whatever photograph happens to be the hero, at up to 42%
        // saturation, so the contrast ratio behind the date headline and the indexing line
        // changes with the reader's own library and can never be measured here. When either
        // setting is on, the wash is not drawn more faintly — it is not drawn. A weaker tint of
        // an unknown hue is still an unknown hue.
        guard !isMuted, let packed else { return Palette.canvas }
        return AmbientColor.wash(from: packed, in: scheme)
    }

    private var isMuted: Bool {
        contrast == .increased || reduceTransparency
    }

    private func resolve() async {
        guard let identifier else { packed = nil; return }
        if let cached = AmbientColor.cachedAverage(forIdentifier: identifier) {
            packed = cached
            return
        }
        guard let image = await PhotoImageLoader.shared.thumbnail(forIdentifier: identifier, side: 64),
              let average = AmbientColor.average(of: image) else { return }
        AmbientColor.store(average, forIdentifier: identifier)
        packed = average
    }
}
