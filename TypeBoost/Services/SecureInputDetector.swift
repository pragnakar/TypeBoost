// SecureInputDetector.swift
// TypeBoost
//
// Detects when macOS has activated "secure input" mode — a system-level
// flag that apps like password managers, login windows, and web browsers
// (for password fields) use to prevent other processes from reading
// keyboard events.
//
// When secure input is active, TypeBoost disables its suggestion bar
// and stops processing keystrokes to respect user privacy.

import Cocoa
import Carbon.HIToolbox

final class SecureInputDetector {

    /// Returns true if any application has enabled secure keyboard input.
    /// This is a lightweight check (single C function call) safe to call
    /// on every key event.
    var isSecureInputActive: Bool {
        IsSecureEventInputEnabled()
    }
}
