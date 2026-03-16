// AppSettings.swift
// TypeBoost
//
// Application-wide settings persisted via UserDefaults.
// Conforms to ObservableObject so SwiftUI settings views
// can bind directly to these properties.

import Foundation
import Combine

final class AppSettings: ObservableObject {

    // MARK: – Keys

    private enum Key: String {
        case isEnabled
        case isLearningEnabled
        case launchAtLogin
        case ignoredBundleIDs
    }

    // MARK: – Published Properties

    @Published var isEnabled: Bool = true
    @Published var isLearningEnabled: Bool = true
    @Published var launchAtLogin: Bool = false

    // MARK: – Load / Save

    static func load() -> AppSettings {
        let s = AppSettings()
        let d = UserDefaults.standard
        s.isEnabled = d.object(forKey: Key.isEnabled.rawValue) as? Bool ?? true
        s.isLearningEnabled = d.object(forKey: Key.isLearningEnabled.rawValue) as? Bool ?? true
        s.launchAtLogin = d.object(forKey: Key.launchAtLogin.rawValue) as? Bool ?? false
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(isEnabled, forKey: Key.isEnabled.rawValue)
        d.set(isLearningEnabled, forKey: Key.isLearningEnabled.rawValue)
        d.set(launchAtLogin, forKey: Key.launchAtLogin.rawValue)
    }
}
