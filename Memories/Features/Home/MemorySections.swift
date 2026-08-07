import SwiftData
import SwiftUI

/// The editorial furniture of the feed.
///
/// None of these are glass. Glass belongs to controls; content is photography on paper, and
/// putting every card behind a pane of it would turn the app into a WWDC demo.

// MARK: - Header

struct SectionHeader: View {
    let overline: String?
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let overline {
                Text(overline).overlineStyle()
            }
            Text(title)
                .font(Typo.sectionTitle)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.gutter)
    }
}

// MARK: - Hero

/// One photograph, edge to edge, with the memory's name written on it.
struct HeroMemoryCard: View {
    let candidate: MemoryCandidate

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .bottomLeading) {
                if let cover = candidate.coverIdentifier {
                    PhotoImageView(identifier: cover, targetSide: width, purpose: .display)
                } else {
                    Palette.surfaceSunk
                }

                LinearGradient(
                    colors: [.clear, .black.opacity(0.20), .black.opacity(0.68)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: Space.s) {
                    Text(candidate.kind.fallbackTitle)
                        .font(Typo.overline)
                        .textCase(.uppercase)
                        .kerning(0.7)
                        .foregroundStyle(.white.opacity(0.72))

                    Text(candidate.title)
                        .font(.system(size: 32, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    if let subtitle = candidate.subtitle {
                        Text(subtitle)
                            .font(Typo.label)
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.bottom, Space.xl)
            }
            .frame(width: width, height: width * 1.25)
            .clipped()
        }
        .aspectRatio(0.8, contentMode: .fit)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(candidate.title). \(candidate.subtitle ?? "")")
    }
}

// MARK: - Mosaic

/// An asymmetric cluster: one frame that carries the occasion, and the rest around it.
struct MosaicSection: View {
    let identifiers: [String]
    var spacing: CGFloat = 6

    var body: some View {
        let items = Array(identifiers.prefix(9))
        VStack(spacing: spacing) {
            if items.count >= 3 {
                HStack(spacing: spacing) {
                    tile(items[0], aspect: 1.0)
                        .frame(maxWidth: .infinity)
                    VStack(spacing: spacing) {
                        tile(items[1], aspect: 1.0)
                        tile(items[2], aspect: 1.0)
                    }
                    .frame(width: 118)
                }
                .frame(height: 246)

                if items.count >= 6 {
                    HStack(spacing: spacing) {
                        ForEach(items[3..<min(6, items.count)], id: \.self) { identifier in
                            tile(identifier, aspect: 1.0)
                        }
                    }
                    .frame(height: 112)
                }
                if items.count >= 9 {
                    HStack(spacing: spacing) {
                        ForEach(items[6..<9], id: \.self) { identifier in
                            tile(identifier, aspect: 1.0)
                        }
                    }
                    .frame(height: 112)
                }
            } else {
                HStack(spacing: spacing) {
                    ForEach(items, id: \.self) { identifier in
                        tile(identifier, aspect: 1.0)
                    }
                }
                .frame(height: 200)
            }
        }
        .padding(.horizontal, Space.gutter)
    }

    private func tile(_ identifier: String, aspect: CGFloat) -> some View {
        PhotoImageView(identifier: identifier, targetSide: 420)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: Radius.tile))
    }
}

// MARK: - Strip

/// A horizontal run of cards, for memories that are a set rather than a scene.
struct StripSection: View {
    let identifiers: [String]
    var cardWidth: CGFloat = 172
    var cardHeight: CGFloat = 216

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.m) {
                ForEach(identifiers.prefix(18), id: \.self) { identifier in
                    PhotoImageView(identifier: identifier, targetSide: cardWidth * 2)
                        .frame(width: cardWidth, height: cardHeight)
                        .clipShape(.rect(cornerRadius: Radius.card))
                }
            }
            .padding(.horizontal, Space.gutter)
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
    }
}

// MARK: - Through the years

/// Year-labelled columns. The point of the app in one control: the same week, stacked.
struct YearStripSection: View {
    let slices: [YearSlice]
    var cardWidth: CGFloat = 148

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Space.m) {
                ForEach(slices) { slice in
                    VStack(alignment: .leading, spacing: Space.s) {
                        if let cover = slice.coverIdentifier {
                            PhotoImageView(identifier: cover, targetSide: cardWidth * 2)
                                .frame(width: cardWidth, height: cardWidth * 1.25)
                                .clipShape(.rect(cornerRadius: Radius.card))
                        } else {
                            RoundedRectangle(cornerRadius: Radius.card)
                                .fill(Palette.surfaceSunk)
                                .frame(width: cardWidth, height: cardWidth * 1.25)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(slice.year))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Palette.textPrimary)
                            Text("\(slice.count) \(slice.count == 1 ? "moment" : "moments")")
                                .font(Typo.meta)
                                .foregroundStyle(Palette.textTertiary)
                        }
                    }
                }
            }
            .padding(.horizontal, Space.gutter)
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
    }
}

// MARK: - Empty and loading

struct QuietStatusView: View {
    let title: String
    var detail: String?
    var symbol: String = "sparkles"

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.textTertiary)
            Text(title)
                .font(Typo.quiet)
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(Typo.meta)
                    .foregroundStyle(Palette.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.section)
        .padding(.vertical, Space.section)
    }
}
