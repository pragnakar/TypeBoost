// PermissionManager.swift
// TypeBoost
//
// Checks and requests the two macOS permissions TypeBoost needs:
//   1. Accessibility   – to read the focused text field and insert text
//   2. Input Monitoring – to observe global keyboard events via CGEventTap
//
// Both permissions must be granted in System Settings → Privacy & Security.

import Cocoa
import Combine

final class PermissionManager: ObservableObject {

    @Published private(set) var isAccessibilityGranted: Bool = false
    @Published private(set) var isInputMonitoringGranted: Bool = false

    /// True when both required permissions are active.
    var hasRequiredPermissions: Bool {
        isAccessibilityGranted && isInputMonitoringGranted
    }

    private var timer: Timer?

    init() {
        refresh()
        // Poll every 2 seconds while permissions are missing, so the UI
        // updates as soon as the user grants them in System Settings.
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: – Checking

    func refresh() {
        isAccessibilityGranted = AXIsProcessTrusted()
        // Input Monitoring cannot be queried directly; a successful
        // CGEventTap creation is the canonical check. We use a lightweight
        // test tap that is immediately destroyed.
        isInputMonitoringGranted = canCreateEventTap()
    }

    // MARK: – Requesting

    /// Opens System Settings → Privacy & Security → Accessibility and
    /// shows an alert explaining what to do.
    func requestPermissions() {
        let alert = NSAlert()
        alert.messageText = "TypeBoost Needs Permissions"
        alert.informativeText = """
        TypeBoost requires two permissions to function:

        1. Accessibility – to read text fields and insert suggestions.
        2. Input Monitoring – to observe your typing.

        Please grant both in System Settings → Privacy & Security.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    // MARK: – Private

    private func canCreateEventTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else {
            return false
        }
        // Immediately disable and discard the test tap.
        CGEvent.tapEnable(tap: tap, enable: false)
        return true
    }
}
