import UIKit

/// What to call the thing the app is running on, when the app is talking to the user about it.
///
/// The app said "iPhone" in twelve places — the privacy dashboard's counters, the promise on
/// the first screen, the details panel, the line under the indexing count, the label on a photo
/// this device's own camera took. Every one of those was written when the app could only run on
/// a phone, and every one of them became a lie the moment it was allowed onto an iPad: a
/// privacy page that says your photographs are examined on this iPhone, read on an iPad, is
/// not merely untidy. It is the one screen a reader is entitled to take literally.
///
/// `UIDevice.model` is not used, because it returns "iPod touch" and other names this app has
/// no business claiming, and because the interface idiom is the thing that is actually true:
/// it is what the layout is adapting to two files away.
enum DeviceName {

    /// "iPhone" or "iPad", for use inside a sentence.
    static var current: String {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: return "iPad"
        default:   return "iPhone"
        }
    }

    /// "this iPhone" / "this iPad" — the form nearly every one of these sentences wanted.
    static var thisDevice: String { "this \(current)" }
}
