import Foundation

/// How a finger on the glass is interpreted.
///
/// The fork's operator drives a Mac Studio from an 11" iPad Pro with a Magic
/// Keyboard, and the trackpad path (see REPORT-alfheim.md §6) is what that
/// hardware wants. But the glass is still there, and upstream's only answer for
/// it is "a finger is a mouse": tap is a click, a one-finger drag moves the
/// pointer with the button down, and scrolling needs two fingers. On an iPad
/// that is the wrong muscle memory — every other app on the device scrolls with
/// one finger.
///
/// So the finger behaviour is a setting, and the iPadOS-shaped one is the
/// default. Neither value touches the trackpad, the Pencil or the keyboard
/// paths: those are unchanged in both modes.
enum TouchMode: String, CaseIterable, Identifiable {
    /// iPadOS-like. One finger scrolls (with inertia), tap clicks, touch and
    /// hold is the context menu, hold then move drags, pinch zooms.
    case native
    /// Every finger is the mouse, the way upstream does it. One-finger drag
    /// moves the pointer with the button down; two fingers scroll.
    case trackpad

    var id: String { rawValue }

    var label: String {
        switch self {
        case .native:   return "Native"
        case .trackpad: return "Trackpad-style"
        }
    }

    var hint: String {
        switch self {
        case .native:
            return "One finger scrolls with inertia, like every other app on this \(deviceKind). Tap to click. Touch and hold to right-click — or keep moving, without lifting, to drag what you were holding. Two fingers scroll or tap to right-click; pinch to zoom."
        case .trackpad:
            return "A finger is the mouse: drag to move the pointer with the button down, two fingers to scroll, two-finger tap to right-click."
        }
    }

    /// The stored default. Native, because one-finger scrolling is the point
    /// of the setting; `AppStorage` writes the raw value, and an unknown string
    /// falls back here.
    static let `default` = TouchMode.native

    static let defaultsKey = "touchMode"
}
