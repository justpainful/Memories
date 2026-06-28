import SwiftUI
import UIKit

enum AppMotion {
    static let reveal = Animation.spring(duration: 0.88, bounce: 0.18)
    static let card = Animation.spring(duration: 0.62, bounce: 0.12)
    static let emphasis = Animation.easeInOut(duration: 0.26)
}

struct MotionAwareModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let active: Bool
    let offset: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : opacity)
            .offset(y: active || reduceMotion ? 0 : offset)
            .animation(reduceMotion ? .default : AppMotion.card, value: active)
    }
}

extension View {
    func motionEntrance(
        active: Bool,
        offset: CGFloat = 24,
        opacity: Double = 0.35
    ) -> some View {
        modifier(MotionAwareModifier(active: active, offset: offset, opacity: opacity))
    }
}

struct AppHaptics: Sendable {
    var selection: @Sendable () -> Void
    var success: @Sendable () -> Void
    var warning: @Sendable () -> Void

    static let noop = AppHaptics(
        selection: {},
        success: {},
        warning: {}
    )

    static let live = AppHaptics(
        selection: {
            DispatchQueue.main.async {
                UISelectionFeedbackGenerator().selectionChanged()
            }
        },
        success: {
            DispatchQueue.main.async {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        },
        warning: {
            DispatchQueue.main.async {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    )
}

typealias MemoriesMotion = AppMotion
typealias MemoriesHapticsClient = AppHaptics
