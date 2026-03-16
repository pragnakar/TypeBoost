// StorageService.swift
// TypeBoost
//
// Utility for managing the app's local data directory and file encryption.
// All user data lives under ~/Library/Application Support/TypeBoost/.

import Foundation
import CryptoKit
import IOKit

enum StorageService {

    /// The root directory for all TypeBoost data.
    static var appSupportDirectory: URL {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("TypeBoost", isDirectory: true)
        }
        let dir = base.appendingPathComponent("TypeBoost", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: – File Helpers

    static func fileURL(_ name: String) -> URL {
        appSupportDirectory.appendingPathComponent(name)
    }

    static func write(_ data: Data, to name: String) throws {
        let url = fileURL(name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    static func read(_ name: String) throws -> Data {
        let url = fileURL(name)
        return try Data(contentsOf: url)
    }

    static func delete(_ name: String) {
        let url = fileURL(name)
        try? FileManager.default.removeItem(at: url)
    }

    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(name).path)
    }

    // MARK: – Encryption (AES-256-GCM via CryptoKit)

    /// Derives a symmetric key from the app's bundle ID + a device-specific
    /// identifier. In a production release this would use the Keychain.
    private static var encryptionKey: SymmetricKey {
        let seed = "com.typeboost.encryption.\(hardwareUUID())"
        let hash = SHA256.hash(data: Data(seed.utf8))
        return SymmetricKey(data: hash)
    }

    static func encrypt(_ data: Data) throws -> Data {
        let sealed = try AES.GCM.seal(data, using: encryptionKey)
        guard let combined = sealed.combined else {
            throw NSError(domain: "TypeBoost", code: 1, userInfo: [NSLocalizedDescriptionKey: "Encryption failed"])
        }
        return combined
    }

    static func decrypt(_ data: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: encryptionKey)
    }

    // MARK: – Device ID

    private static func hardwareUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        guard let uuidCF = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0) else {
            return "fallback-uuid"
        }
        return (uuidCF.takeRetainedValue() as? String) ?? "fallback-uuid"
    }
}
