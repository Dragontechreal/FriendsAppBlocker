import SwiftUI
import FamilyControls
import AuthenticationServices

struct ContentView: View {
    @StateObject private var blockingManager = BlockingManager.shared
    @AppStorage("appAppearance") private var appAppearanceRaw = AppAppearance.system.rawValue
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.enUS.rawValue

    @State private var selectedTab: AppTab = .request
    @State private var friendCode = ""
    @State private var requestMinutes = 15
    @State private var selectedRequestLimitID: UUID?
    @State private var showingPicker = false
    @State private var showingLimitEditor = false
    @State private var draftLimit = AppLimitPolicy.empty(ownerID: "", ownerName: "")

    private enum AppTab: Hashable {
        case friends
        case limits
        case request
        case approvals
        case settings
    }

    private var appAppearance: AppAppearance {
        AppAppearance(rawValue: appAppearanceRaw) ?? .system
    }

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .enUS
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if blockingManager.isAuthenticated {
                dashboard
            } else {
                loginView
            }
        }
        .preferredColorScheme(appAppearance.colorScheme)
        .task {
            if blockingManager.supportsFamilyControls && !blockingManager.isAuthorized {
                try? await blockingManager.requestAuthorization()
            }
            if blockingManager.isAuthenticated {
                await blockingManager.refreshAll()
            }
        }
        .sheet(isPresented: $showingPicker, onDismiss: {
            showingLimitEditor = true
        }) {
            NavigationStack {
                FamilyActivityPicker(selection: $draftLimit.selection)
                    .navigationTitle("Apps")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                showingPicker = false
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingLimitEditor) {
            limitEditor
        }
    }

    private var dashboard: some View {
        TabView(selection: $selectedTab) {
            friendsPage
                .tabItem { Label("Friends", systemImage: "person.2.fill") }
                .tag(AppTab.friends)

            limitsPage
                .tabItem { Label("Limits", systemImage: "hourglass.circle.fill") }
                .tag(AppTab.limits)

            requestPage
                .tabItem { Label("Request", systemImage: "paperplane.fill") }
                .tag(AppTab.request)

            approvalsPage
                .tabItem { Label("Requests", systemImage: "checkmark.seal.fill") }
                .tag(AppTab.approvals)

            settingsPage
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .tint(Theme.accent)
    }

    private var loginView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                Spacer(minLength: 32)
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("bound")
                        .font(Theme.Font.title(42))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Set app limits for yourself and let trusted friends approve extra time.")
                        .font(Theme.Font.body())
                        .foregroundStyle(Theme.textSecondary)
                }

                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    Task { await blockingManager.handleAuthorizationResult(result) }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))

                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Development login")
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.textSecondary)
                    HStack {
                        Button {
                            blockingManager.signInForDevelopment(asOwner: true)
                        } label: {
                            Label("Owner", systemImage: "crown.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryPillButtonStyle())

                        Button {
                            blockingManager.signInForDevelopment(asOwner: false)
                        } label: {
                            Label("Friend", systemImage: "person.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryPillButtonStyle())
                    }
                }
                .sectionPanel()

                statusMessages
            }
            .padding(Theme.Spacing.lg)
        }
    }

    private var friendsPage: some View {
        page {
            header("Friends", "Add friends with their Friend ID. Friends can only resolve requests for limits you assign to them.")

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle("Your Friend ID", icon: "number")
                Text(blockingManager.currentAppUserID)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .textSelection(.enabled)

                TextField("Friend ID", text: $friendCode)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()

                Button {
                    Task {
                        await blockingManager.addFriend(with: friendCode)
                        friendCode = ""
                    }
                } label: {
                    Label("Add friend", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(friendCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .sectionPanel()

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle("Current friends", icon: "person.2.fill")
                if blockingManager.friends.isEmpty {
                    statusBanner("No friends yet.", icon: "person.crop.circle.badge.questionmark", color: Theme.warning)
                } else {
                    ForEach(blockingManager.friends) { friend in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(friend.displayName)
                                    .font(Theme.Font.heading())
                                Text(friend.appUserID)
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button {
                                Task { await blockingManager.unfriend(friend) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(IconCircleButtonStyle(compact: true, tint: Theme.destructive))
                        }
                        .padding(Theme.Spacing.sm)
                        .background(Theme.controlBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                    }
                }
            }
            .sectionPanel()
        }
    }

    private var limitsPage: some View {
        page {
            header("Limits", "Create limits, choose apps, set minutes, and assign friends who can approve extra time.")

            HStack {
                Spacer()
                Button {
                    draftLimit = AppLimitPolicy.empty(ownerID: blockingManager.currentAppUserID, ownerName: blockingManager.currentUserDisplayName)
                    showingPicker = true
                } label: {
                    Label("New limit", systemImage: "plus")
                }
                .buttonStyle(PrimaryPillButtonStyle(compact: true))
            }

            if blockingManager.limits.isEmpty {
                statusBanner("No limits yet. Tap New limit to start.", icon: "plus.circle.fill", color: Theme.warning)
            } else {
                ForEach(blockingManager.limits) { limit in
                    limitRow(limit)
                }
            }
        }
    }

    private var requestPage: some View {
        page {
            header("Request Time", "Select one of your limits and ask assigned friends for extra minutes.")

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle("Limit", icon: "hourglass")
                Picker("Limit", selection: $selectedRequestLimitID) {
                    Text("Choose a limit").tag(UUID?.none)
                    ForEach(blockingManager.limits) { limit in
                        Text(limit.title).tag(Optional(limit.id))
                    }
                }
                .pickerStyle(.menu)

                Stepper("\(requestMinutes) minutes", value: $requestMinutes, in: 5...180, step: 5)
                    .font(Theme.Font.heading())

                if let limit = selectedRequestLimit {
                    if blockingManager.openOwnRequests.contains(where: { $0.limitID == limit.id }) {
                        statusBanner("You already have an open request for this limit.", icon: "clock.fill", color: Theme.warning)
                    }
                    Button {
                        Task { await blockingManager.requestMoreTime(limit: limit, minutes: requestMinutes) }
                    } label: {
                        Label("Request more time", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .disabled(blockingManager.openOwnRequests.contains(where: { $0.limitID == limit.id }))
                } else {
                    statusBanner("Create and select a limit first.", icon: "hourglass.badge.plus", color: Theme.warning)
                }
            }
            .sectionPanel()

            requestHistory
        }
    }

    private var approvalsPage: some View {
        page {
            header("Requests", "Approve or decline requests assigned to you.")

            if blockingManager.incomingRequests.isEmpty {
                statusBanner("No requests assigned to you.", icon: "checkmark.circle.fill", color: Theme.success)
            } else {
                ForEach(blockingManager.incomingRequests) { request in
                    requestApprovalRow(request)
                }
            }
        }
    }

    private var settingsPage: some View {
        page {
            header("Settings", blockingManager.isDeveloperSession ? "Development session" : "Signed in")
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle("Account", icon: "person.crop.circle")
                Text(blockingManager.currentUserDisplayName)
                    .font(Theme.Font.heading())
                Text(blockingManager.currentAppUserID)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .textSelection(.enabled)
            }
            .sectionPanel()

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle("Appearance", icon: "circle.lefthalf.filled")
                Picker("Appearance", selection: $appAppearanceRaw) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                sectionTitle("Language", icon: "globe")
                Picker("Language", selection: $appLanguageRaw) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
            .sectionPanel()

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle("Diagnostics", icon: "icloud.fill")
                Text("Version 1.0")
                    .font(Theme.Font.body())
                Button {
                    Task { await blockingManager.registerCloudSchemaForDevelopment() }
                } label: {
                    Label("Seed Development CloudKit schema", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryPillButtonStyle())
                Text("Run this from an Xcode Development build after deleting CloudKit schema, then deploy Development schema to Production for TestFlight.")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.textSecondary)
            }
            .sectionPanel()

            Button {
                blockingManager.signOut()
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryPillButtonStyle())

            statusMessages
        }
    }

    private var limitEditor: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        sectionTitle("Limit details", icon: "hourglass")
                        TextField("Title", text: $draftLimit.title)
                            .textFieldStyle(.roundedBorder)
                        Stepper("\(draftLimit.minutes) minutes", value: $draftLimit.minutes, in: 5...240, step: 5)
                        Picker("Mode", selection: $draftLimit.mode) {
                            ForEach(LimitMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        Button {
                            showingLimitEditor = false
                            showingPicker = true
                        } label: {
                            Label("Edit apps", systemImage: "app.badge")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryPillButtonStyle())
                    }
                    .sectionPanel()

                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        sectionTitle("Friends who can approve", icon: "person.2.fill")
                        if blockingManager.friends.isEmpty {
                            statusBanner("Add friends before assigning approvers.", icon: "person.badge.plus", color: Theme.warning)
                        } else {
                            ForEach(blockingManager.friends) { friend in
                                Toggle(friend.displayName, isOn: approverBinding(friend.appUserID))
                            }
                        }
                    }
                    .sectionPanel()
                }
                .padding(Theme.Spacing.md)
            }
            .navigationTitle(draftLimit.title.isEmpty ? "Limit" : draftLimit.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingLimitEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task {
                            await blockingManager.saveLimit(draftLimit)
                            showingLimitEditor = false
                        }
                    }
                    .disabled(draftLimit.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftLimit.approverIDs.isEmpty)
                }
            }
        }
    }

    private func limitRow(_ limit: AppLimitPolicy) -> some View {
        Button {
            draftLimit = limit
            showingLimitEditor = true
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text(limit.title)
                        .font(Theme.Font.heading())
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Theme.textSecondary)
                }
                Text("\(limit.minutes) min • \(limit.mode.title)")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.textSecondary)
                Text("\(limit.approverIDs.count) approver(s)")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(Theme.Spacing.md)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func requestApprovalRow(_ request: AppTimeRequest) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.requesterName)
                        .font(Theme.Font.heading())
                    Text("\(request.limitTitle) • \(request.requestedMinutes) minutes")
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(request.status.rawValue.capitalized)
                    .font(Theme.Font.caption())
                    .foregroundStyle(request.status == .open ? Theme.warning : Theme.textSecondary)
            }
            if request.status == .open {
                HStack {
                    Button("Approve") {
                        Task { await blockingManager.resolveRequest(request, approved: true) }
                    }
                    .buttonStyle(PrimaryPillButtonStyle(compact: true))

                    Button("Decline") {
                        Task { await blockingManager.resolveRequest(request, approved: false) }
                    }
                    .buttonStyle(SecondaryPillButtonStyle(compact: true))
                }
            } else if let resolvedByName = request.resolvedByName {
                Text("Resolved by \(resolvedByName)")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .sectionPanel()
    }

    private var requestHistory: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle("Your requests", icon: "clock.arrow.circlepath")
            if blockingManager.ownRequests.isEmpty {
                Text("No requests yet.")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(blockingManager.ownRequests) { request in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(request.limitTitle)
                                .font(Theme.Font.heading(16))
                            Text("\(request.requestedMinutes) min • \(request.status.rawValue.capitalized)")
                                .font(Theme.Font.caption())
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                    }
                }
            }
        }
        .sectionPanel()
    }

    private var selectedRequestLimit: AppLimitPolicy? {
        guard let selectedRequestLimitID else { return nil }
        return blockingManager.limits.first { $0.id == selectedRequestLimitID }
    }

    private var statusMessages: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if let info = blockingManager.infoMessage {
                statusBanner(info, icon: "info.circle.fill", color: Theme.accent)
            }
            if let error = blockingManager.authError {
                statusBanner(error, icon: "exclamationmark.triangle.fill", color: Theme.destructive)
            }
        }
    }

    private func approverBinding(_ friendID: String) -> Binding<Bool> {
        Binding {
            draftLimit.approverIDs.contains(friendID)
        } set: { isOn in
            if isOn {
                if !draftLimit.approverIDs.contains(friendID) {
                    draftLimit.approverIDs.append(friendID)
                }
            } else {
                draftLimit.approverIDs.removeAll { $0 == friendID }
            }
        }
    }

    private func page<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                content()
            }
            .padding(Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.xl)
        }
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Font.title(30))
                .foregroundStyle(Theme.textPrimary)
            Text(subtitle)
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
    }

    private func statusBanner(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(Theme.Spacing.md)
        .background(color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    }
}

private enum AppLanguage: String, CaseIterable, Identifiable {
    case enUS
    case de

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .enUS: return "English (US)"
        case .de: return "Deutsch"
        }
    }
}

private enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

private struct SectionPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            }
    }
}

private extension View {
    func sectionPanel() -> some View {
        modifier(SectionPanelModifier())
    }
}

private struct PrimaryPillButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.heading(compact ? 14 : 16))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? Theme.Spacing.md : Theme.Spacing.lg)
            .padding(.vertical, compact ? Theme.Spacing.sm : Theme.Spacing.md)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    }
}

private struct SecondaryPillButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Font.heading(compact ? 14 : 16))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, compact ? Theme.Spacing.md : Theme.Spacing.lg)
            .padding(.vertical, compact ? Theme.Spacing.sm : Theme.Spacing.md)
            .background(Theme.controlBackground.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            }
    }
}

private struct IconCircleButtonStyle: ButtonStyle {
    var compact = false
    var tint = Theme.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .frame(width: compact ? 34 : 44, height: compact ? 34 : 44)
            .background(Theme.controlBackground.opacity(configuration.isPressed ? 0.72 : 1))
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(Theme.border, lineWidth: 1)
            }
    }
}

#Preview {
    ContentView()
}
