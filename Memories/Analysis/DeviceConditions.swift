import Foundation
import UIKit

/// Whether the device can currently afford heavy analysis.
///
/// Indexing a large library is the most expensive thing this app ever does, and it is never
/// urgent. If the phone is hot, nearly empty, or in Low Power Mode, the pixel stages step
/// back and wait rather than competing with whatever the user is actually doing.
enum WorkAllowance: Sendable {
    /// Full speed: run the heavy stages with normal concurrency.
    case full
    /// Keep going but slower and narrower — smaller batches, longer pauses.
    case reduced
    /// Metadata only. Nothing that decodes pixels.
    case metadataOnly
    /// Stop entirely until conditions improve.
    case suspended

    var allowsPixelWork: Bool { self == .full || self == .reduced }

    var batchSize: Int {
        switch self {
        case .full:         return 24
        case .reduced:      return 8
        case .metadataOnly: return 0
        case .suspended:    return 0
        }
    }

    /// Breathing room between batches so the main thread keeps its frames.
    var pauseBetweenBatches: Duration {
        switch self {
        case .full:         return .milliseconds(40)
        case .reduced:      return .milliseconds(320)
        case .metadataOnly: return .seconds(2)
        case .suspended:    return .seconds(10)
        }
    }
}

@MainActor
enum DeviceConditions {
    static func current() -> WorkAllowance {
        let thermal = ProcessInfo.processInfo.thermalState
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel          // -1 when unknown
        let state = UIDevice.current.batteryState
        let charging = state == .charging || state == .full

        switch thermal {
        case .critical:
            return .suspended
        case .serious:
            return .metadataOnly
        default:
            break
        }

        if lowPower && !charging { return .metadataOnly }
        if level >= 0 && level < 0.15 && !charging { return .metadataOnly }
        if level >= 0 && level < 0.30 && !charging { return .reduced }
        if thermal == .fair && !charging { return .reduced }
        return .full
    }

    /// Human-readable reason, for the indexing status line in Settings.
    static func explanation(for allowance: WorkAllowance) -> String? {
        switch allowance {
        case .full, .reduced: return nil
        case .metadataOnly:   return "Paused heavy analysis to save power"
        case .suspended:      return "Paused while your iPhone cools down"
        }
    }
}
