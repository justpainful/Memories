import Foundation
import UIKit

/// Whether the device can currently afford heavy analysis.
///
/// Indexing a large library is the most expensive thing this app ever does, and it is never
/// urgent. If the phone is hot, nearly empty, in Low Power Mode, or simply in the user's hand
/// on battery, the pixel stages step back and wait rather than competing with whatever the
/// user is actually doing.
enum WorkAllowance: Sendable {
    /// Full speed: run the heavy stages with normal concurrency.
    case full
    /// Keep going but slower and narrower — smaller batches, one frame at a time, long rests.
    case reduced
    /// Metadata only. Nothing that decodes pixels.
    case metadataOnly
    /// Stop entirely until conditions improve.
    case suspended

    var allowsPixelWork: Bool { self == .full || self == .reduced }

    /// How many frames may be decoded and analysed at the same time.
    ///
    /// Every frame in flight is a decoded bitmap held in memory and half a dozen Vision
    /// requests contending for the same cores and the same Neural Engine, so the ceiling is a
    /// fraction of the machine rather than all of it: past that point nothing finishes any
    /// sooner and the only thing that climbs is the temperature. Taken from the core count so
    /// the same code is not three-wide on a phone that has two cores to give.
    var concurrency: Int {
        switch self {
        case .full:
            return max(1, min(3, ProcessInfo.processInfo.activeProcessorCount / 3))
        case .reduced:
            // The whole point of this state is to leave the device to the user.
            return 1
        case .metadataOnly, .suspended:
            return 0
        }
    }

    var batchSize: Int {
        switch self {
        case .full:         return 12
        case .reduced:      return 4
        case .metadataOnly: return 0
        case .suspended:    return 0
        }
    }

    /// The share of wall-clock time the pixel stages are allowed to spend working.
    ///
    /// Rationed by time rather than trusted to be short, because on a library of this size the
    /// pass is not short. A fixed pause could not express this: the same forty milliseconds is
    /// a real rest after a batch that took a tenth of a second and no rest at all after one
    /// that took four.
    var dutyCycle: Double {
        switch self {
        case .full:         return 0.75
        case .reduced:      return 0.30
        case .metadataOnly: return 0
        case .suspended:    return 0
        }
    }

    /// Never shorter than this, so even an instant batch lets a frame through — and, in the
    /// states where nothing is being decoded at all, this is simply how long to wait before
    /// asking again whether the phone has cooled down or been plugged in.
    var minimumPause: Duration {
        switch self {
        case .full:         return .milliseconds(150)
        case .reduced:      return .milliseconds(500)
        case .metadataOnly: return .seconds(5)
        case .suspended:    return .seconds(20)
        }
    }

    /// How long to stand down after a batch that took this long to analyse.
    func pause(after elapsed: Duration) -> Duration {
        guard dutyCycle > 0 else { return minimumPause }
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        return max(minimumPause, .seconds(seconds * (1 / dutyCycle - 1)))
    }
}

@MainActor
enum DeviceConditions {
    /// Battery monitoring is a switch on the device, not a question asked of it. It was being
    /// thrown once per batch to read a level that had not moved since the batch before.
    private static var isMonitoringBattery = false

    static func current() -> WorkAllowance {
        if !isMonitoringBattery {
            UIDevice.current.isBatteryMonitoringEnabled = true
            isMonitoringBattery = true
        }

        let thermal = ProcessInfo.processInfo.thermalState
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
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

        // Low Power Mode is the user saying so out loud. It is honoured on the charger too,
        // just less severely: they asked for less work, not for none.
        if lowPower { return charging ? .reduced : .metadataOnly }

        if level >= 0 && level < 0.15 && !charging { return .metadataOnly }
        if level >= 0 && level < 0.30 && !charging { return .reduced }
        if thermal == .fair && !charging { return .reduced }

        // On screen and on battery is the one case where full speed is paid for twice: the
        // pass takes cores away from the frames the user is watching, and the drain lands
        // while they are holding the phone rather than while it is charging overnight. So the
        // foreground gets the quiet setting, and the scheduled background task — which iOS
        // only grants on external power — gets the fast one.
        if UIApplication.shared.applicationState == .active && !charging { return .reduced }

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
