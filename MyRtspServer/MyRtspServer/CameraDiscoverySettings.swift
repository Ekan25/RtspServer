import Foundation
import UIKit

enum CameraDiscoverySettings {
    private static let cameraNameDefaultsKey = "cameraDiscovery.name"
    private static let cameraIdentifierDefaultsKey = "cameraDiscovery.identifier"
    private static let maximumServiceNameBytes = 63

    static var cameraName: String {
        normalizedName(UserDefaults.standard.string(forKey: cameraNameDefaultsKey) ?? UIDevice.current.name)
    }

    static var cameraIdentifier: UUID {
        if let value = UserDefaults.standard.string(forKey: cameraIdentifierDefaultsKey),
           let identifier = UUID(uuidString: value) {
            return identifier
        }

        let identifier = UUID()
        UserDefaults.standard.set(identifier.uuidString.lowercased(), forKey: cameraIdentifierDefaultsKey)
        return identifier
    }

    @discardableResult
    static func saveCameraName(_ name: String) -> String {
        let normalized = normalizedName(name)
        UserDefaults.standard.set(normalized, forKey: cameraNameDefaultsKey)
        return normalized
    }

    private static func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "Camera" : trimmed
        var result = ""
        for character in source {
            let candidate = result + String(character)
            guard candidate.lengthOfBytes(using: .utf8) <= maximumServiceNameBytes else { break }
            result = candidate
        }
        return result.isEmpty ? "Camera" : result
    }
}
