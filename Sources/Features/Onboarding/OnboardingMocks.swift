import Foundation
import UIKit

enum OnboardingMockFactory {
    static func makeStore() -> OnboardingStore {
        OnboardingStore(
            dependencies: .mock,
            haptics: .noop
        )
    }
}

extension OnboardingDependencies {
    static let mock = OnboardingDependencies(
        authorizationStatus: { .limited },
        requestAuthorization: { .limited },
        loadAvatarCandidates: {
            [
                AvatarCandidate(
                    id: "mock-1",
                    assetIdentifier: "avatar-aurora",
                    title: "Aurora",
                    detail: "Live Photo",
                    kind: .livePhoto
                ),
                AvatarCandidate(
                    id: "mock-2",
                    assetIdentifier: "avatar-ocean",
                    title: "Ocean",
                    detail: "Photo",
                    kind: .photo
                ),
                AvatarCandidate(
                    id: "mock-3",
                    assetIdentifier: "avatar-city",
                    title: "City Night",
                    detail: "Video",
                    kind: .video
                ),
                AvatarCandidate(
                    id: "mock-4",
                    assetIdentifier: "avatar-forest",
                    title: "Forest",
                    detail: "Photo",
                    kind: .photo
                )
            ]
        },
        loadAvatarThumbnail: { identifier in
            OnboardingMockFactory.thumbnailData(for: identifier)
        }
    )

    private static func thumbnailData(for identifier: String) -> Data? {
        let size = CGSize(width: 180, height: 180)
        let renderer = UIGraphicsImageRenderer(size: size)

        let colors: [String: (UIColor, UIColor)] = [
            "avatar-aurora": (.systemIndigo, .systemMint),
            "avatar-ocean": (.systemBlue, .cyan),
            "avatar-city": (.darkGray, .systemPurple),
            "avatar-forest": (.systemGreen, .systemTeal)
        ]

        let pair = colors[identifier] ?? (.gray, .lightGray)
        let image = renderer.image { context in
            let cgContext = context.cgContext
            let gradientColors = [pair.0.cgColor, pair.1.cgColor] as CFArray
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0, 1])!

            cgContext.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 56, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]

            let initial = String(identifier.split(separator: "-").last?.prefix(1) ?? "A").uppercased()
            let rect = CGRect(x: 0, y: 52, width: size.width, height: 70)
            initial.draw(in: rect, withAttributes: attributes)
        }

        return image.pngData()
    }
}
