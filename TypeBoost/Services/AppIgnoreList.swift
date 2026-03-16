// AppIgnoreList.swift
// TypeBoost
//
// Manages the list of applications for which TypeBoost is disabled.
// Includes both user-configured exclusions and a set of hard-coded
// defaults (Terminal, iTerm, password managers).
//
// The list is persisted in UserDefaults and exposed as an
// ObservableObject for the SwiftUI settings panel.

import Cocoa
import Combine

final class AppIgnoreList: ObservableObject {

    // MARK: – Defaults

    /// Applications where predictions are disabled out-of-the-box.
    private static let defaultIgnored: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.sourceforge.iTerm",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword8",
        "com.1password.1password",
        "org.keepassxc.keepassxc",
        "com.lastpass.LastPass",
        "com.bitwarden.desktop",
    ]

    // MARK: – State

    @Published private(set) var ignoredBundleIDs: [String] = []
    private var ignoredSet: Set<String> = []
    private let settings: AppSettings

    private let userDefaultsKey = "ignoredBundleIDs"

    // MARK: – Init

    init(settings: AppSettings) {
        self.settings = settings
        load()
    }

    // MARK: – Queries

    /// Whether the currently frontmost application is on the ignore list.
    var isCurrentAppIgnored: Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return ignoredSet.contains(bundleID)
    }

    /// Whether the given bundle ID is ignored (user or default).
    func isIgnored(_ bundleID: String) -> Bool {
        ignoredSet.contains(bundleID)
    }

    // MARK: – Mutation

    func add(bundleID: String) {
        guard !ignoredSet.contains(bundleID) else { return }
        ignoredSet.insert(bundleID)
        ignoredBundleIDs = Array(ignoredSet).sorted()
        save()
    }

    func remove(bundleID: String) {
        ignoredSet.remove(bundleID)
        ignoredBundleIDs = Array(ignoredSet).sorted()
        save()
    }

    // MARK: – Persistence

    private func load() {
        var combined = Self.defaultIgnored
        if let saved = UserDefaults.standard.stringArray(forKey: userDefaultsKey) {
            combined.formUnion(saved)
        }
        ignoredSet = combined
        ignoredBundleIDs = Array(combined).sorted()
    }

    private func save() {
        // Only persist user additions (not defaults) so defaults can be
        // updated in future versions without being overridden.
        let userOnly = ignoredSet.subtracting(Self.defaultIgnored)
        UserDefaults.standard.set(Array(userOnly), forKey: userDefaultsKey)
    }
}
