import Foundation
import FamilyControls
import ManagedSettings
import ManagedSettingsUI
import DeviceActivity

@MainActor
class BlockingManager: ObservableObject {
    static let shared = BlockingManager()

    @Published var isAuthorized = false
    @Published var isBlocking = false
    @Published var selectedApps = FamilyActivitySelection()

    private let store = ManagedSettingsStore()
    private let center = AuthorizationCenter.shared

    private let isBlockingKey = "isBlocking"
    private let selectedAppsKey = "selectedApps"

    private init() {
        updateAuthorizationStatus()
        loadState()
    }

    private func updateAuthorizationStatus() {
        isAuthorized = center.authorizationStatus == .approved
    }

    /// Request Screen Time authorization
    func requestAuthorization() async throws {
        try await center.requestAuthorization(for: .individual)
        updateAuthorizationStatus()
    }

    /// Enable blocking for selected apps and websites
    func enableBlocking() {
        applyBlocking()
        isBlocking = true
        saveState()
    }

    private func applyBlocking() {
        // Shield apps
        if !selectedApps.applicationTokens.isEmpty {
            store.shield.applications = selectedApps.applicationTokens
            store.shield.applicationCategories = .specific(selectedApps.categoryTokens)
        }

        // Shield web domains (selected via FamilyActivityPicker)
        if !selectedApps.webDomainTokens.isEmpty {
            store.shield.webDomains = selectedApps.webDomainTokens
        }
    }

    /// Disable blocking (called after QR scan verification)
    func disableBlocking() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil

        isBlocking = false
        saveState()
    }

    /// Check if any apps are currently blocked
    func checkBlockingStatus() {
        isBlocking = store.shield.applications != nil || store.shield.webDomains != nil
    }

    /// Check if there's anything to block
    var hasItemsToBlock: Bool {
        !selectedApps.applicationTokens.isEmpty || !selectedApps.webDomainTokens.isEmpty
    }

    // MARK: - Persistence

    func saveState() {
        UserDefaults.standard.set(isBlocking, forKey: isBlockingKey)

        // Save selected apps
        if let encoded = try? JSONEncoder().encode(selectedApps) {
            UserDefaults.standard.set(encoded, forKey: selectedAppsKey)
        }
    }

    func loadState() {
        isBlocking = UserDefaults.standard.bool(forKey: isBlockingKey)

        // Load selected apps
        if let data = UserDefaults.standard.data(forKey: selectedAppsKey),
           let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            selectedApps = decoded
        }

        checkBlockingStatus()
    }
}
