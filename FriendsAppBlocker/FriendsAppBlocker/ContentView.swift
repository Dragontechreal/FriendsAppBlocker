import SwiftUI
import FamilyControls

struct ContentView: View {
    @StateObject private var blockingManager = BlockingManager.shared
    @State private var showingAppPicker = false
    @State private var scanResult: ScanResult?

    enum ScanResult {
        case success
        case failure(String)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    headerSection

                    if blockingManager.isBlocking {
                        lockedView
                    } else {
                        setupView
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.md)
                .padding(.bottom, 100)
            }

            VStack {
                Spacer()
                actionButton
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.bottom, Theme.Spacing.lg)
            }
        }
        .sheet(isPresented: $showingAppPicker, onDismiss: {
            blockingManager.saveState()
        }) {
            NavigationStack {
                FamilyActivityPicker(selection: $blockingManager.selectedApps)
                    .navigationTitle("Select to Block")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showingAppPicker = false
                            }
                            .foregroundStyle(Theme.accent)
                        }
                    }
            }
        }
        .alert("Scan Result", isPresented: .constant(scanResult != nil)) {
            Button("OK") { scanResult = nil }
        } message: {
            switch scanResult {
            case .success:
                Text("Apps unblocked successfully!")
            case .failure(let reason):
                Text(reason)
            case .none:
                Text("")
            }
        }
        .task {
            if !blockingManager.isAuthorized {
                try? await blockingManager.requestAuthorization()
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                Text("Blocker")
                    .font(Theme.Font.title())
                    .foregroundStyle(Theme.textPrimary)

                Circle()
                    .fill(blockingManager.isBlocking ? Theme.accent : Theme.border)
                    .frame(width: 12, height: 14)
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 15 }
            }
            Spacer()
        }
        .padding(.top, Theme.Spacing.md)
    }

    // MARK: - Setup View (Unlocked)

    private var setupView: some View {
        VStack(spacing: Theme.Spacing.md) {
            appsSection
        }
    }

    private var appsSection: some View {
        Button {
            if blockingManager.isAuthorized {
                showingAppPicker = true
            } else {
                Task {
                    try? await blockingManager.requestAuthorization()
                }
            }
        } label: {
            HStack {
                Text(blockingManager.isAuthorized
                     ? (blockingManager.hasItemsToBlock ? selectionSummary : "Select apps & sites to block")
                     : "Tap to authorize Screen Time")
                    .foregroundStyle(blockingManager.isAuthorized && !blockingManager.hasItemsToBlock ? Theme.textSecondary : Theme.accent)
                Spacer()
                Image(systemName: blockingManager.isAuthorized ? "chevron.right" : "lock.open")
                    .foregroundStyle(Theme.accent)
            }
            .font(Theme.Font.heading())
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground)
            .cornerRadius(Theme.Radius.lg)
        }
    }

    private var selectionSummary: String {
        let apps = blockingManager.selectedApps.applicationTokens.count
        let sites = blockingManager.selectedApps.webDomainTokens.count
        var parts: [String] = []
        if apps > 0 { parts.append("\(apps) app\(apps == 1 ? "" : "s")") }
        if sites > 0 { parts.append("\(sites) site\(sites == 1 ? "" : "s")") }
        return parts.joined(separator: ", ") + " selected"
    }

    private var blockedSummary: String {
        let apps = blockingManager.selectedApps.applicationTokens.count
        let sites = blockingManager.selectedApps.webDomainTokens.count
        var parts: [String] = []
        if apps > 0 { parts.append("\(apps) app\(apps == 1 ? "" : "s")") }
        if sites > 0 { parts.append("\(sites) site\(sites == 1 ? "" : "s")") }
        return parts.joined(separator: ", ") + " blocked"
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Locked View

    private var lockedView: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ZStack(alignment: .bottom) {
                InlineQRScanner { code in
                    handleScannedCode(code)
                }

                Text("Scan QR to unlock")
                    .font(Theme.Font.heading())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Color.black.opacity(0.5))
            }
            .frame(height: 450)
            .cornerRadius(Theme.Radius.lg)

            HStack {
                Text(blockedSummary)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Image(systemName: "lock.fill")
                    .foregroundStyle(Theme.accent)
            }
            .font(Theme.Font.heading())
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground)
            .cornerRadius(Theme.Radius.lg)
        }
    }

    // MARK: - Action Button

    private var actionButton: some View {
        Button {
            if !blockingManager.isBlocking {
                blockingManager.enableBlocking()
            }
        } label: {
            HStack {
                Image(systemName: blockingManager.isBlocking ? "lock.fill" : "lock.open.fill")
                Text(blockingManager.isBlocking ? "Locked" : "Start Focus")
            }
            .font(Theme.Font.heading())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.md)
            .background(
                blockingManager.isBlocking
                    ? Theme.textSecondary
                    : (blockingManager.hasItemsToBlock ? Theme.accent : Theme.border)
            )
            .cornerRadius(Theme.Radius.lg)
        }
        .disabled(blockingManager.isBlocking || !blockingManager.hasItemsToBlock)
    }

    // MARK: - Actions

    private func handleScannedCode(_ code: String) {
        let verifier = TOTPVerifier()
        if verifier.verifyQRContent(code) {
            blockingManager.disableBlocking()
            scanResult = .success
        } else {
            scanResult = .failure("Invalid or expired code. Try again.")
        }
    }
}

#Preview {
    ContentView()
}
