import Foundation

/// API keys injected at build time from Config/Secrets.xcconfig via Config/Info.plist.
/// Never print or log these values.
enum Secrets {
    static var epidemicApiKey: String? { value(for: "EpidemicApiKey") }

    private static func value(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        // An unset xcconfig variable leaves the value empty.
        return trimmed.isEmpty ? nil : trimmed
    }
}
