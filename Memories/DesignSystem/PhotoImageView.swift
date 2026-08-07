import Photos
import SwiftUI

/// Draws one asset. Every photograph in the app goes through here.
///
/// Loading is asynchronous and the placeholder is a calm tone rather than a spinner: at feed
/// scale a screen full of spinners looks broken even when nothing is wrong. Assets that live
/// only in iCloud say so instead of hanging, because indexing never downloads them.
struct PhotoImageView: View {
    let identifier: String
    var targetSide: CGFloat = 400
    var purpose: ImagePurpose = .browsing
    var contentMode: ContentMode = .fill

    /// The scale of the display this view is actually on. `UIScreen.main` is the wrong
    /// answer to that question on modern iOS — it names one screen in a world where an app
    /// can be on several — and Apple deprecated it for exactly that reason.
    @Environment(\.displayScale) private var displayScale

    @State private var image: UIImage?
    @State private var isUnavailable = false
    /// Which photograph the frame on screen belongs to, so a reload triggered by a *resize*
    /// can tell itself apart from a reload triggered by a different picture arriving.
    @State private var lastLoadedIdentifier: String?

    /// Which photograph, and how big — the two things that decide whether what is on screen is
    /// still the right bitmap.
    ///
    /// The reload used to be keyed on the identifier alone, so a tile that changed size kept
    /// whatever it had already loaded: turn the phone, or pinch the grid one rung looser, and
    /// every visible photograph stayed at the smaller size it was fetched at and went soft. The
    /// size is bucketed rather than exact so a fraction of a point of layout drift does not
    /// throw away a perfectly good frame and start again.
    private struct ImageRequest: Hashable {
        var identifier: String
        var pixels: CGFloat
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Palette.surfaceSunk

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .transition(.opacity)
                } else if isUnavailable {
                    // Sized from the tile rather than from the type scale, so it comes through
                    // `Typo.glyph`: a placeholder that grew with Dynamic Type would be larger
                    // than the cell it is standing in for. Clamped at both ends because the
                    // same view draws a fifty-point grid tile and a full-bleed hero.
                    Image(systemName: "icloud.slash")
                        .font(Typo.glyph(placeholderGlyphSide(in: proxy.size), .regular))
                        .foregroundStyle(Palette.textTertiary)
                        // Left unlabelled, VoiceOver reads the symbol's own name — "icloud
                        // slash" — which describes the drawing rather than the situation. What
                        // the reader needs is the reason there is no photograph here.
                        .accessibilityLabel("Not downloaded from iCloud")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // Deliberately not gated on Reduce Motion. A cross-dissolve is what that setting
            // asks motion to be replaced *with*; nothing here travels, scales or springs, and
            // cutting the fade would only make a screen full of photographs snap in.
            .animation(.easeOut(duration: 0.22), value: image != nil)
            .task(id: request(for: proxy.size)) { await load(request(for: proxy.size)) }
        }
    }

    /// A symbol proportional to the tile, but never smaller than legible or larger than tidy.
    private func placeholderGlyphSide(in size: CGSize) -> CGFloat {
        let proportional = min(size.width, size.height) * 0.22
        return min(max(proportional, 13), 44)
    }

    private func request(for size: CGSize) -> ImageRequest {
        ImageRequest(
            identifier: identifier,
            // `max` over the container *and* the caller's hint: a caller that knows the tile
            // will grow says so, and a view that has been handed more room than that asks for
            // what it actually has. Before layout has happened the container is zero, and the
            // hint is what keeps the first request from being a one-pixel thumbnail.
            pixels: PhotoImageLoader.requestSide(
                forSide: max(size.width, size.height, targetSide),
                scale: displayScale
            )
        )
    }

    private func load(_ request: ImageRequest) async {
        let size = CGSize(width: request.pixels, height: request.pixels)

        // Ask the cache before clearing anything. This runs again every time a tile scrolls
        // back into view, and blanking to the placeholder first meant a long grid flickered
        // grey on the way back up even though every frame was already in memory.
        if let cached = PhotoImageLoader.shared.cachedImage(forIdentifier: request.identifier,
                                                            targetSize: size,
                                                            purpose: purpose) {
            image = cached
            isUnavailable = false
            return
        }

        // Only now, with a real wait ahead and a different photograph coming, is it right to
        // let go of the old one — keeping it would show the wrong picture under the new tile.
        // A *resize* of the same photograph is the exception: what is on screen is still the
        // right picture, merely at the wrong resolution, so it stays until the better one lands.
        if request.identifier != lastLoadedIdentifier { image = nil }
        isUnavailable = false
        lastLoadedIdentifier = request.identifier

        let loaded = await PhotoImageLoader.shared.image(
            forIdentifier: request.identifier,
            targetSize: size,
            purpose: purpose
        )
        if let loaded {
            image = loaded
        } else {
            isUnavailable = true
        }
    }
}

/// A square thumbnail with the app's standard corner treatment.
struct PhotoThumbnail: View {
    let identifier: String
    var side: CGFloat = 84
    var radius: CGFloat = Radius.thumb

    var body: some View {
        PhotoImageView(identifier: identifier, targetSide: side)
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Palette.hairline, lineWidth: 0.5)
            }
    }
}

/// Marks videos and Live Photos without covering the image.
///
/// This is furniture, not content, and the distinction decides everything about it. The badge
/// sits in the corner of a thumbnail that is barely fifty points across at the densest grid
/// rung, and it is attached as an overlay *outside* the tile's clip, so a label that grew all
/// the way to the accessibility sizes would be wider than the photograph it belongs to and
/// would come to rest on its neighbour's badge — at which point neither duration names a clip.
/// So the type answers Dynamic Type and then stops, and the reader who needs larger text is
/// served instead by the spoken label, which is where the whole of this badge's meaning lives.
struct MediaBadge: View {
    let record: AssetRecord

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if record.isVideo {
                Label(record.duration.shortDuration, systemImage: "play.fill")
            } else if record.isLivePhoto {
                // Not "LIVE" typed in capitals. Capitals are a convention of the Latin
                // alphabet — a script without case cannot reproduce them and has nothing to
                // gain by trying — where `textCase` is simply a no-op there.
                Label("Live", systemImage: "livephoto")
                    .textCase(.uppercase)
            }
        }
        .font(Typo.scaled(11, .semibold))
        .chromeTypeSize(.xxLarge)
        // No `fixedSize` with these: an overlay is offered its host's size, so a badge that is
        // allowed to shrink stays inside the photograph it belongs to, and one that insists on
        // its ideal width walks out over the neighbouring tile.
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.white)
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
        .background(scrim, in: .capsule)
        // Read as it stands, this is a play glyph followed by "0:41" — VoiceOver announces a
        // bare number and never says the word "video", so the one thing the badge exists to
        // tell you is the one thing it did not. Both facts, in words, and the clock-shaped
        // string replaced by a spoken length.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    /// `labelScrim` is the value the app already settled on for a small white label over an
    /// unknown photograph, and it is a compromise: dark enough to read against most pictures,
    /// light enough to leave the picture bright. A reader who has asked for more contrast, or
    /// for less transparency, has asked for that compromise to stop being one.
    private var scrim: Color {
        contrast == .increased || reduceTransparency
            ? Color.black.opacity(0.82)
            : Palette.labelScrim
    }

    private var spokenLabel: String {
        if record.isVideo { return "Video, \(record.duration.spokenDuration)" }
        if record.isLivePhoto { return "Live Photo" }
        return ""
    }
}

extension TimeInterval {
    /// `2:07`, or `1:04:22` for anything over an hour.
    ///
    /// Formatted rather than printed. `String(format: "%d:%02d")` emits ASCII digits whatever
    /// the locale, so an app that writes its dates and counts in Arabic-Indic numerals wrote
    /// every clip's length in Western ones — on every video thumbnail in every grid, and twice
    /// in the video transport. `Duration`'s time style follows the locale for digits and
    /// separators and keeps exactly the same shape in English.
    var shortDuration: String {
        let total = wholeSeconds
        let duration = Duration.seconds(total)
        return total >= 3600
            ? duration.formatted(.time(pattern: .hourMinuteSecond))
            : duration.formatted(.time(pattern: .minuteSecond))
    }

    /// The same length in words, for VoiceOver.
    ///
    /// A clock-shaped string is written to be *seen*: spoken, "0:41" is read out as a number
    /// and a punctuation mark, and the listener has to reassemble a duration from it. The units
    /// style says "41 seconds", in the reader's language.
    var spokenDuration: String {
        Duration.seconds(wholeSeconds)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    /// A whole number of seconds that is safe to convert.
    ///
    /// `Int(someDouble)` traps on a value that is not finite or does not fit, and a duration
    /// arrives here from a media file's metadata — which is to say from a container written by
    /// software nobody in this project controls. A malformed clip should show `0:00`, not take
    /// the app down with it.
    private var wholeSeconds: Int {
        guard isFinite, self > 0 else { return 0 }
        return Int(min(rounded(), 359_999))   // 99:59:59, past any plausible clip
    }
}
