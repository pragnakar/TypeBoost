// SettingsView.swift
// TypeBoost
//
// A SwiftUI-based settings panel hosted inside an NSWindow via NSHostingView.
// Provides controls for:
//   • General (enable/disable, launch at login)
//   • Prediction (learning toggle, reset)
//   • Application Ignore List management
//   • About / version info

import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var appIgnoreList: AppIgnoreList
    let userDictionary: UserDictionary

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(0)

            predictionTab
                .tabItem { Label("Prediction", systemImage: "text.magnifyingglass") }
                .tag(1)

            appsTab
                .tabItem { Label("Applications", systemImage: "app.badge.checkmark") }
                .tag(2)
        }
        .frame(minWidth: 460, minHeight: 340)
        .padding()
    }

    // MARK: – General

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Enable TypeBoost", isOn: $settings.isEnabled)
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
            }

            Section("Keyboard Shortcuts") {
                Text("↑  Activate suggestions")
                    .font(.system(.body, design: .monospaced))
                Text("← →  Navigate suggestions")
                    .font(.system(.body, design: .monospaced))
                Text("Enter  Accept highlighted suggestion")
                    .font(.system(.body, design: .monospaced))
                Text("1  2  3  Quick-select suggestion")
                    .font(.system(.body, design: .monospaced))
                Text("Esc  Dismiss suggestions for current word")
                    .font(.system(.body, design: .monospaced))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: – Prediction

    private var predictionTab: some View {
        Form {
            Section {
                Toggle("Learn from my typing", isOn: $settings.isLearningEnabled)

                HStack {
                    Text("Words learned: \(userDictionary.learnedWords.count)")
                    Spacer()
                    Button("Reset…") {
                        showResetConfirmation()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Section("Information") {
                Text("TypeBoost improves predictions by learning words you type frequently. All data is stored locally and never leaves your device.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: – Applications

    private var appsTab: some View {
        Form {
            Section("Ignored Applications") {
                if appIgnoreList.ignoredBundleIDs.isEmpty {
                    Text("No applications are currently ignored.")
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(appIgnoreList.ignoredBundleIDs, id: \.self) { bundleID in
                            HStack {
                                Text(appName(for: bundleID) ?? bundleID)
                                Spacer()
                                Button("Remove") {
                                    appIgnoreList.remove(bundleID: bundleID)
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                            }
                        }
                    }
                    .frame(minHeight: 100)
                }
            }

            Section {
                Text("Use the menu bar → \u{201C}Disable for Current App\u{201D} to quickly add applications to this list.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: – Helpers

    private func showResetConfirmation() {
        let alert = NSAlert()
        alert.messageText = "Reset Learned Data?"
        alert.informativeText = "This will erase all words TypeBoost has learned. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            userDictionary.resetAll()
        }
    }

    private func appName(for bundleID: String) -> String? {
        let workspace = NSWorkspace.shared
        guard let url = workspace.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }
}
