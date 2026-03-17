// MenuBarController.swift
// TypeBoost
//
// Manages the NSStatusItem (menu bar icon) and its dropdown menu.
// Provides quick access to:
//   • Enable / Disable toggle
//   • Pause for current application
//   • Prediction settings
//   • Appearance settings
//   • Permission status
//   • Launch at Login
//   • About / Quit

import Cocoa
import SwiftUI
import ServiceManagement

final class MenuBarController: NSObject {

    // MARK: – Dependencies

    private let settings: AppSettings
    private let permissionManager: PermissionManager
    private let appIgnoreList: AppIgnoreList
    private let userDictionary: UserDictionary

    // MARK: – UI

    private var statusItem: NSStatusItem!
    private var settingsWindowController: NSWindowController?

    // MARK: – Init

    init(settings: AppSettings,
         permissionManager: PermissionManager,
         appIgnoreList: AppIgnoreList,
         userDictionary: UserDictionary) {
        self.settings = settings
        self.permissionManager = permissionManager
        self.appIgnoreList = appIgnoreList
        self.userDictionary = userDictionary
        super.init()
        setupStatusItem()
    }

    // MARK: – Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "TypeBoost")
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = true
        }

        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "TypeBoost")

        // Enable / Disable
        let enableItem = NSMenuItem(
            title: settings.isEnabled ? "Disable TypeBoost" : "Enable TypeBoost",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        enableItem.target = self
        menu.addItem(enableItem)

        menu.addItem(.separator())

        // Disable / Enable for current app — label reflects current ignore state.
        let frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let isCurrentIgnored = appIgnoreList.isIgnored(frontBundleID)
        let pauseItem = NSMenuItem(
            title: isCurrentIgnored ? "Enable for Current App" : "Disable for Current App",
            action: isCurrentIgnored ? #selector(enableForCurrentApp) : #selector(pauseForCurrentApp),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        // Prediction submenu
        let predictionItem = NSMenuItem(title: "Prediction", action: nil, keyEquivalent: "")
        let predictionMenu = NSMenu()

        let learningItem = NSMenuItem(
            title: settings.isLearningEnabled ? "Disable Learning" : "Enable Learning",
            action: #selector(toggleLearning),
            keyEquivalent: ""
        )
        learningItem.target = self
        predictionMenu.addItem(learningItem)

        let resetItem = NSMenuItem(title: "Reset Learned Data…", action: #selector(resetLearnedData), keyEquivalent: "")
        resetItem.target = self
        predictionMenu.addItem(resetItem)

        predictionItem.submenu = predictionMenu
        menu.addItem(predictionItem)

        menu.addItem(.separator())

        // Permissions
        let permItem = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        let permMenu = NSMenu()

        let accItem = NSMenuItem(
            title: "Accessibility: \(permissionManager.isAccessibilityGranted ? "✓ Granted" : "✗ Not Granted")",
            action: #selector(openAccessibility),
            keyEquivalent: ""
        )
        accItem.target = self
        permMenu.addItem(accItem)

        let inputItem = NSMenuItem(
            title: "Input Monitoring: \(permissionManager.isInputMonitoringGranted ? "✓ Granted" : "✗ Not Granted")",
            action: #selector(openInputMonitoring),
            keyEquivalent: ""
        )
        inputItem.target = self
        permMenu.addItem(inputItem)

        permItem.submenu = permMenu
        menu.addItem(permItem)

        menu.addItem(.separator())

        // Settings
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Launch at Login
        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = settings.launchAtLogin ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())

        // About
        let aboutItem = NSMenuItem(title: "About TypeBoost", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit TypeBoost", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Rebuild menu each time it's opened so labels refresh.
        menu.delegate = self

        return menu
    }

    // MARK: – Actions

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
        settings.save()
    }

    @objc private func pauseForCurrentApp() {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        appIgnoreList.add(bundleID: bundleID)
    }

    @objc private func enableForCurrentApp() {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        appIgnoreList.remove(bundleID: bundleID)
    }

    @objc private func toggleLearning() {
        settings.isLearningEnabled.toggle()
        userDictionary.isLearningEnabled = settings.isLearningEnabled
        settings.save()
    }

    @objc private func resetLearnedData() {
        let alert = NSAlert()
        alert.messageText = "Reset Learned Data?"
        alert.informativeText = "This will erase all words TypeBoost has learned from your typing. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            userDictionary.resetAll()
        }
    }

    @objc private func openAccessibility() {
        permissionManager.openAccessibilitySettings()
    }

    @objc private func openInputMonitoring() {
        permissionManager.openInputMonitoringSettings()
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            let settingsView = SettingsView(
                settings: settings,
                appIgnoreList: appIgnoreList,
                userDictionary: userDictionary
            )
            let hostingView = NSHostingView(rootView: settingsView)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "TypeBoost Settings"
            window.contentView = hostingView
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleLaunchAtLogin() {
        settings.launchAtLogin.toggle()
        settings.save()

        if #available(macOS 13.0, *) {
            do {
                if settings.launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("[TypeBoost] Failed to update login item: \(error)")
            }
        }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "TypeBoost"
        alert.informativeText = """
        Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")

        Predictive typing for macOS.
        Fast, private, local-first.
        """
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: – NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Rebuild the menu so dynamic labels (permissions, toggles) are current.
        menu.removeAllItems()
        for item in buildMenu().items {
            menu.addItem(item.copy() as! NSMenuItem)
        }
    }
}
