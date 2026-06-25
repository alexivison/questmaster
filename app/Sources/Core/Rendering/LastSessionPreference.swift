import Foundation

public enum LastSessionPreference {
    public static let defaultsKey = "questmaster.lastSelectedSessionID"

    public static func storedSessionID(in defaults: UserDefaults = .standard) -> String? {
        clean(defaults.string(forKey: defaultsKey))
    }

    public static func store(sessionID: String?, in defaults: UserDefaults = .standard) {
        guard let sessionID = clean(sessionID) else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        defaults.set(sessionID, forKey: defaultsKey)
    }

    private static func clean(_ value: String?) -> String? {
        let cleanValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleanValue.isEmpty ? nil : cleanValue
    }
}
