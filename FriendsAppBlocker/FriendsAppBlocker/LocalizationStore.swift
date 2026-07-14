import Foundation
import Combine

struct LocalizationLanguage: Identifiable, Hashable {
    let code: String
    let displayName: String

    var id: String { code }
}

@MainActor
final class LocalizationStore: ObservableObject {
    static let shared = LocalizationStore()

    @Published private(set) var availableLanguages: [LocalizationLanguage] = []
    @Published private var strings: [String: String] = [:]

    private let selectedLanguageKey = "appLanguage"
    private let fallbackCode = "en-US"

    private init() {
        availableLanguages = loadAvailableLanguages()
        loadLanguage(UserDefaults.standard.string(forKey: selectedLanguageKey) ?? fallbackCode)
    }

    func loadLanguage(_ code: String) {
        let normalizedCode = normalizedLanguageCode(code)
        strings = loadStrings(for: normalizedCode)
        UserDefaults.standard.set(normalizedCode, forKey: selectedLanguageKey)
    }

    func text(_ key: String, fallback: String) -> String {
        strings[key] ?? fallback
    }

    private func normalizedLanguageCode(_ code: String) -> String {
        if availableLanguages.contains(where: { $0.code == code }) {
            return code
        }
        return fallbackCode
    }

    private func loadAvailableLanguages() -> [LocalizationLanguage] {
        let languages = localizationFileURLs().compactMap { url -> LocalizationLanguage? in
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(LocalizationFile.self, from: data) else { return nil }
            return LocalizationLanguage(code: decoded.language.code, displayName: decoded.language.name)
        }
        let unique = Dictionary(grouping: languages, by: \.code).compactMap { $0.value.first }
        let sorted = unique.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        if sorted.contains(where: { $0.code == fallbackCode }) {
            return sorted
        }
        return [LocalizationLanguage(code: fallbackCode, displayName: "English (US)")] + sorted
    }

    private func loadStrings(for code: String) -> [String: String] {
        guard let url = localizationFileURLs().first(where: { $0.deletingPathExtension().lastPathComponent == code }),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(LocalizationFile.self, from: data) else { return [:] }
        return decoded.strings
    }

    private func localizationFileURLs() -> [URL] {
        let direct = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Localizations") ?? []
        if !direct.isEmpty { return direct }

        guard let resourceURL = Bundle.main.resourceURL,
              let enumerator = FileManager.default.enumerator(
                at: resourceURL,
                includingPropertiesForKeys: nil
              ) else { return [] }

        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension == "json",
                  url.deletingLastPathComponent().lastPathComponent == "Localizations" else { return nil }
            return url
        }
    }
}

private struct LocalizationFile: Decodable {
    let language: LocalizationLanguageInfo
    let strings: [String: String]
}

private struct LocalizationLanguageInfo: Decodable {
    let code: String
    let name: String
}
