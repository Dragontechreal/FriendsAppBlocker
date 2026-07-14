import SwiftUI
import FamilyControls
import DeviceActivity
import AuthenticationServices
import UIKit

struct ContentView: View {
    @StateObject private var blockingManager = BlockingManager.shared
    @StateObject private var localization = LocalizationStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @AppStorage("appAppearance") private var appAppearanceRaw = AppAppearance.system.rawValue
    @AppStorage("appLanguage") private var appLanguageRaw = "en-US"

    @State private var selectedTab: AppTab = .request
    @State private var friendCode = ""
    @State private var requestMinutes = 15
    @State private var selectedRequestLimitID: UUID?
    @State private var showingPicker = false
    @State private var showingLimitEditor = false
    @State private var showingDeleteLimitConfirmation = false
    @State private var draftLimit = AppLimitPolicy.empty(ownerID: "", ownerName: "")
    @State private var profileNameDraft = ""
    @State private var editingProfileName = false
    @State private var pullDistance: CGFloat = 0
    @State private var maxPullDistance: CGFloat = 0
    @State private var isDraggingToRefresh = false
    @State private var isManualRefreshing = false
    @State private var didTriggerRefreshHaptic = false
    private let refreshRevealDistance: CGFloat = 58
    private let refreshTriggerDistance: CGFloat = 106
    private let usageMetadataSuiteName = "group.dev.supremezone.app.FriendsAppBlocker"
    private let usageTotalsBySelectionKey = "BoundUsageTotalsBySelection"
    private let usageTotalsByTokenKey = "BoundUsageTotalsByToken"

    private enum AppTab: Hashable {
        case friends
        case limits
        case request
        case approvals
        case settings
        #if DEBUG
        case dev
        #endif
    }

    private var appAppearance: AppAppearance {
        AppAppearance(rawValue: appAppearanceRaw) ?? .system
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
            normalizeSelectedLanguage()
            if blockingManager.supportsFamilyControls && !blockingManager.isAuthorized {
                try? await blockingManager.requestAuthorization()
            }
            if blockingManager.isAuthenticated {
                await blockingManager.refreshAll()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await blockingManager.refreshRemoteChanges() }
            }
        }
        .onChange(of: selectedTab) { _, _ in
            Task { await blockingManager.refreshRemoteChanges() }
        }
        .onChange(of: appLanguageRaw) { _, newValue in
            localization.loadLanguage(newValue)
        }
        .sheet(isPresented: $showingPicker, onDismiss: {
            showingLimitEditor = true
        }) {
            NavigationStack {
                FamilyActivityPicker(selection: $draftLimit.selection)
                    .navigationTitle(L("editor.apps", "Apps"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L("editor.done", "Done")) {
                                showingPicker = false
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingLimitEditor) {
            limitEditor
        }
        .sheet(isPresented: $blockingManager.needsDisplayName) {
            nameSetupSheet(canCancel: editingProfileName)
        }
    }

    private var dashboard: some View {
        TabView(selection: $selectedTab) {
            friendsPage
                .tabItem { Label(L("tab.friends", "Friends"), systemImage: "person.2.fill") }
                .tag(AppTab.friends)

            limitsPage
                .tabItem { Label(L("tab.limits", "Limits"), systemImage: "hourglass.circle.fill") }
                .tag(AppTab.limits)

            requestPage
                .tabItem { Label(L("tab.request", "Request"), systemImage: "paperplane.fill") }
                .tag(AppTab.request)

            approvalsPage
                .tabItem { Label(L("tab.requests", "Requests"), systemImage: "checkmark.seal.fill") }
                .tag(AppTab.approvals)

            settingsPage
                .tabItem { Label(L("tab.settings", "Settings"), systemImage: "gearshape.fill") }
                .tag(AppTab.settings)

            #if DEBUG
            devPage
                .tabItem { Label(L("tab.dev", "Dev"), systemImage: "hammer.fill") }
                .tag(AppTab.dev)
            #endif
        }
        .tint(Theme.accent)
    }

    private var loginView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                Spacer(minLength: 32)
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Bound")
                        .font(Theme.Font.title(42))
                        .foregroundStyle(Theme.textPrimary)
                    Text(L("login.subtitle", "Set app limits for yourself and let trusted friends approve extra time."))
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
                    Text(L("login.development", "Development login"))
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.textSecondary)
                    HStack {
                        Button {
                            blockingManager.signInForDevelopment(asOwner: true)
                        } label: {
                            Label(L("login.owner", "Owner"), systemImage: "crown.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryPillButtonStyle())

                        Button {
                            blockingManager.signInForDevelopment(asOwner: false)
                        } label: {
                            Label(L("login.friend", "Friend"), systemImage: "person.fill")
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
            header(L("friends.title", "Friends"), L("friends.subtitle", "Add friends with their Friend ID. Friends can only resolve requests for limits you assign to them."))

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(L("friends.your_id", "Your Friend ID"), icon: "number")
                Text(blockingManager.currentAppUserID)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .textSelection(.enabled)

                TextField(L("friends.friend_id_placeholder", "Friend ID"), text: $friendCode)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()

                Button {
                    Task {
                        await blockingManager.addFriend(with: friendCode)
                        friendCode = ""
                    }
                } label: {
                    Label(L("friends.add", "Add friend"), systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(friendCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .sectionPanel()

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(L("friends.current", "Current friends"), icon: "person.2.fill")
                if blockingManager.friends.isEmpty {
                    statusBanner(L("friends.none", "No friends yet."), icon: "person.crop.circle.badge.questionmark", color: Theme.warning)
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

            friendRequestsSection
        }
    }

    private var friendRequestsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle(L("friends.requests", "Friend requests"), icon: "envelope.badge.fill")

            if blockingManager.incomingFriendRequests.isEmpty && blockingManager.outgoingFriendRequests.isEmpty {
                statusBanner(L("friends.no_pending", "No pending friend requests."), icon: "checkmark.circle.fill", color: Theme.success)
            }

            ForEach(blockingManager.incomingFriendRequests) { request in
                HStack(spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.friend(for: blockingManager.currentAppUserID)?.displayName ?? "Friend")
                            .font(Theme.Font.heading())
                        Text(L("friends.wants_to_add_you", "Wants to add you"))
                            .font(Theme.Font.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button(L("common.accept", "Accept")) {
                        Task { await blockingManager.acceptFriendRequest(request) }
                    }
                    .buttonStyle(PrimaryPillButtonStyle(compact: true))
                    Button(L("common.decline", "Decline")) {
                        Task { await blockingManager.declineFriendRequest(request) }
                    }
                    .buttonStyle(SecondaryPillButtonStyle(compact: true))
                }
                .padding(Theme.Spacing.sm)
                .background(Theme.controlBackground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            }

            ForEach(blockingManager.outgoingFriendRequests) { request in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.friend(for: blockingManager.currentAppUserID)?.displayName ?? "Friend")
                            .font(Theme.Font.heading())
                        Text(L("friends.waiting", "Waiting for acceptance"))
                            .font(Theme.Font.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "clock.fill")
                        .foregroundStyle(Theme.warning)
                }
                .padding(Theme.Spacing.sm)
                .background(Theme.controlBackground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            }
        }
        .sectionPanel()
    }

    private var limitsPage: some View {
        page {
            header(L("limits.title", "Limits"), L("limits.subtitle", "Create limits, choose apps, set minutes, and assign friends who can approve extra time."))

            HStack {
                Spacer()
                Button {
                    draftLimit = AppLimitPolicy.empty(ownerID: blockingManager.currentAppUserID, ownerName: blockingManager.currentUserDisplayName)
                    showingPicker = true
                    Task { await blockingManager.refreshRemoteChanges() }
                } label: {
                    Label(L("limits.new", "New limit"), systemImage: "plus")
                }
                .buttonStyle(PrimaryPillButtonStyle(compact: true))
            }

            if blockingManager.limits.isEmpty {
                statusBanner(L("limits.none", "No limits yet. Tap New limit to start."), icon: "plus.circle.fill", color: Theme.warning)
            } else {
                ForEach(blockingManager.limits) { limit in
                    limitRow(limit)
                }
            }
        }
    }

    private var requestPage: some View {
        page {
            header(L("request.title", "Request Time"), L("request.subtitle", "Select one of your limits and ask assigned friends for extra minutes."))

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(L("request.limit", "Limit"), icon: "hourglass")
                Picker(L("request.limit", "Limit"), selection: $selectedRequestLimitID) {
                    Text(L("request.choose_limit", "Choose a limit")).tag(UUID?.none)
                    ForEach(blockingManager.limits) { limit in
                        Text(limit.title).tag(Optional(limit.id))
                    }
                }
                .pickerStyle(.menu)

                Stepper("\(requestMinutes) \(L("common.minutes", "minutes"))", value: $requestMinutes, in: 5...180, step: 5)
                    .font(Theme.Font.heading())

                if let limit = selectedRequestLimit {
                    if blockingManager.openOwnRequests.contains(where: { $0.limitID == limit.id }) {
                        statusBanner(L("request.open_exists", "You already have an open request for this limit."), icon: "clock.fill", color: Theme.warning)
                    }
                    Button {
                        Task { await blockingManager.requestMoreTime(limit: limit, minutes: requestMinutes) }
                    } label: {
                        Label(L("request.more_time", "Request more time"), systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .disabled(blockingManager.openOwnRequests.contains(where: { $0.limitID == limit.id }))
                } else {
                    statusBanner(L("request.create_first", "Create and select a limit first."), icon: "hourglass.badge.plus", color: Theme.warning)
                }
            }
            .sectionPanel()

            requestHistory
        }
    }

    private var approvalsPage: some View {
        page {
            header(L("approvals.title", "Requests"), L("approvals.subtitle", "Approve or decline requests assigned to you."))

            if blockingManager.incomingRequests.isEmpty {
                statusBanner(L("approvals.none", "No requests assigned to you."), icon: "checkmark.circle.fill", color: Theme.success)
            } else {
                ForEach(blockingManager.incomingRequests) { request in
                    requestApprovalRow(request)
                }
            }
        }
    }

    private var settingsPage: some View {
        page {
            header(L("settings.title", "Settings"), blockingManager.isDeveloperSession ? L("settings.dev_session", "Development session") : L("settings.signed_in", "Signed in"))
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(L("settings.account", "Account"), icon: "person.crop.circle")
                Text(blockingManager.currentUserDisplayName)
                    .font(Theme.Font.heading())
                Text(blockingManager.currentAppUserID)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .textSelection(.enabled)
                Button {
                    profileNameDraft = blockingManager.currentUserDisplayName == "Guest" ? "" : blockingManager.currentUserDisplayName
                    editingProfileName = true
                    blockingManager.needsDisplayName = true
                } label: {
                    Label(L("settings.change_name", "Change name"), systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryPillButtonStyle())
            }
            .sectionPanel()

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(L("settings.appearance", "Appearance"), icon: "circle.lefthalf.filled")
                Picker(L("settings.appearance", "Appearance"), selection: $appAppearanceRaw) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.localizedTitle { key, fallback in L(key, fallback) }).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                sectionTitle(L("settings.language", "Language"), icon: "globe")
                if localization.availableLanguages.count > 3 {
                    Picker(L("settings.language", "Language"), selection: $appLanguageRaw) {
                        ForEach(localization.availableLanguages) { language in
                            Text(language.displayName).tag(language.code)
                        }
                    }
                    .pickerStyle(.menu)
                } else {
                    Picker(L("settings.language", "Language"), selection: $appLanguageRaw) {
                        ForEach(localization.availableLanguages) { language in
                            Text(language.displayName).tag(language.code)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .sectionPanel()

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(L("settings.app", "App"), icon: "info.circle.fill")
                Text(L("settings.version", "Version 1.0"))
                    .font(Theme.Font.body())

                Button {
                    if let url = URL(string: "https://www.paypal.com/pool/9qSp2qBQ0Y?sr=wccr") {
                        openURL(url)
                    }
                } label: {
                    Label(L("settings.coffee", "Buy me a coffee"), systemImage: "cup.and.saucer.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryPillButtonStyle())
            }
            .sectionPanel()

            Button {
                blockingManager.signOut()
            } label: {
                Label(L("settings.sign_out", "Sign out"), systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryPillButtonStyle())

            statusMessages
        }
    }

    #if DEBUG
    private var devPage: some View {
        page {
            header(L("dev.title", "Dev"), L("dev.subtitle", "Debug-only checks for CloudKit, push notifications, schema, and refresh."))

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(L("dev.schema", "CloudKit schema"), icon: "icloud.and.arrow.up.fill")
                Button {
                    Task { await blockingManager.registerCloudSchemaForDevelopment() }
                } label: {
                    Label(L("dev.seed_schema", "Seed Development CloudKit schema"), systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryPillButtonStyle())
                Text(L("dev.schema_help", "Run this from an Xcode Development build after deleting CloudKit schema, then deploy Development schema to Production for TestFlight."))
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.textSecondary)
            }
            .sectionPanel()

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(L("dev.push", "Push notifications"), icon: "bell.badge.fill")
                Button {
                    Task { await blockingManager.configureNotificationsForDiagnostics() }
                } label: {
                    Label(L("dev.register_push", "Register APNs + check subscriptions"), systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryPillButtonStyle())

                Button {
                    Task { await blockingManager.scheduleLocalNotificationTest() }
                } label: {
                    Label(L("dev.test_local", "Test local notification"), systemImage: "bell.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryPillButtonStyle())

                Button {
                    Task { await blockingManager.createDevelopmentTimeRequestPushTest() }
                } label: {
                    Label(L("dev.test_time", "Create time request push test"), systemImage: "hourglass.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryPillButtonStyle())

                Button {
                    Task { await blockingManager.createDevelopmentFriendRequestPushTest() }
                } label: {
                    Label(L("dev.test_friend", "Create friend request push test"), systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryPillButtonStyle())
            }
            .sectionPanel()

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(L("dev.refresh", "Refresh"), icon: "arrow.clockwise")
                Button {
                    Task { await blockingManager.refreshRemoteChanges() }
                } label: {
                    Label(L("dev.refresh_now", "Refresh now"), systemImage: "arrow.clockwise.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryPillButtonStyle())

                Button {
                    Task { await blockingManager.loadNotificationDiagnostics() }
                } label: {
                    Label(L("dev.reload_diagnostics", "Reload diagnostics"), systemImage: "list.bullet.clipboard.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryPillButtonStyle())
            }
            .sectionPanel()

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(L("dev.diagnostics", "Diagnostics output"), icon: "stethoscope")
                Text(blockingManager.devDiagnostics)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .sectionPanel()

            statusMessages
        }
    }
    #endif

    private var limitEditor: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        sectionTitle(L("editor.details", "Limit details"), icon: "hourglass")
                        TextField(L("editor.title_placeholder", "Title"), text: $draftLimit.title)
                            .textFieldStyle(.roundedBorder)
                        Stepper("\(draftLimit.minutes) \(L("common.minutes", "minutes"))", value: $draftLimit.minutes, in: 5...240, step: 5)
                        Picker(L("editor.mode", "Mode"), selection: $draftLimit.mode) {
                            ForEach(LimitMode.allCases) { mode in
                                Text(limitModeTitle(mode)).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        Button {
                            showingLimitEditor = false
                            showingPicker = true
                        } label: {
                            Label(L("editor.edit_apps", "Edit apps"), systemImage: "app.badge")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryPillButtonStyle())
                    }
                    .sectionPanel()

                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        sectionTitle(L("editor.approvers", "Friends who can approve"), icon: "person.2.fill")
                        if blockingManager.friends.isEmpty {
                            statusBanner(L("editor.add_friends_first", "Add friends before assigning approvers."), icon: "person.badge.plus", color: Theme.warning)
                        } else {
                            ForEach(blockingManager.friends) { friend in
                                Toggle(friend.displayName, isOn: approverBinding(friend.appUserID))
                            }
                        }
                    }
                    .sectionPanel()

                    if isEditingExistingLimit {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            sectionTitle(L("editor.delete_section", "Delete limit"), icon: "trash.fill")
                            Button(role: .destructive) {
                                showingDeleteLimitConfirmation = true
                            } label: {
                                Label(L("editor.delete_button", "Delete this limit"), systemImage: "trash.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(SecondaryPillButtonStyle())
                        }
                        .sectionPanel()
                    }
                }
                .padding(Theme.Spacing.md)
            }
            .navigationTitle(draftLimit.title.isEmpty ? L("editor.limit", "Limit") : draftLimit.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("editor.cancel", "Cancel")) { showingLimitEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("editor.done", "Done")) {
                        Task {
                            await blockingManager.saveLimit(draftLimit)
                            showingLimitEditor = false
                        }
                    }
                    .disabled(draftLimit.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftLimit.approverIDs.isEmpty)
                }
            }
            .confirmationDialog(
                L("editor.delete_title", "Delete this limit?"),
                isPresented: $showingDeleteLimitConfirmation,
                titleVisibility: .visible
            ) {
                Button(L("editor.delete_confirm", "Delete limit"), role: .destructive) {
                    Task {
                        await blockingManager.deleteLimit(draftLimit)
                        showingLimitEditor = false
                    }
                }
                Button(L("editor.cancel", "Cancel"), role: .cancel) {}
            } message: {
                Text(L("editor.delete_message", "This removes the limit and stops its Screen Time tracking."))
            }
        }
    }

    private var isEditingExistingLimit: Bool {
        blockingManager.limits.contains { $0.id == draftLimit.id }
    }

    private func limitRow(_ limit: AppLimitPolicy) -> some View {
        let timeStatus = blockingManager.timeStatus(for: limit)
        storeUsageMetadata(for: limit, timeStatus: timeStatus)
        return Button {
            draftLimit = limit
            showingLimitEditor = true
            Task { await blockingManager.refreshRemoteChanges() }
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

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(timeStatus.totalAvailableMinutes)")
                            .font(Theme.Font.title(28))
                            .foregroundStyle(Theme.accent)
                        Text(L("limits.total_today", "min total today"))
                            .font(Theme.Font.caption())
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(L("limits.screen_time_active", "Screen Time active"))
                            .font(Theme.Font.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }

                    if blockingManager.isAuthorized && hasPreciseUsageSelection(limit) {
                        DeviceActivityReport(.boundLimitUsage, filter: activityReportFilter(for: limit))
                            .frame(height: 32)
                    } else if blockingManager.isAuthorized {
                        Text(L("limits.select_individual_apps", "Select individual apps to show exact app usage."))
                            .font(Theme.Font.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                HStack {
                    Text("\(limit.minutes) \(L("limits.limit_suffix", "min limit"))")
                    Text("•")
                    Text(limitModeTitle(limit.mode))
                    if timeStatus.approvedExtraMinutes > 0 {
                        Text("•")
                        Text("+\(timeStatus.approvedExtraMinutes) \(L("limits.approved_suffix", "approved"))")
                    }
                }
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.textSecondary)

                Text("\(limit.approverIDs.count) \(L("limits.approvers", "approver(s)"))")
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

    private func activityReportFilter(for limit: AppLimitPolicy) -> DeviceActivityFilter {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let interval = DateInterval(start: start, end: Date())
        return DeviceActivityFilter(
            segment: .daily(during: interval),
            users: .all,
            devices: .init([.iPhone, .iPad]),
            applications: limit.selection.applicationTokens,
            categories: [],
            webDomains: limit.selection.webDomainTokens
        )
    }

    private func hasPreciseUsageSelection(_ limit: AppLimitPolicy) -> Bool {
        !limit.selection.applicationTokens.isEmpty || !limit.selection.webDomainTokens.isEmpty
    }

    private func storeUsageMetadata(for limit: AppLimitPolicy, timeStatus: LimitTimeStatus) {
        guard hasPreciseUsageSelection(limit),
              let defaults = UserDefaults(suiteName: usageMetadataSuiteName) else { return }

        if let selectionKey = usageSelectionKey(for: limit) {
            var totalsBySelection = defaults.dictionary(forKey: usageTotalsBySelectionKey) as? [String: Int] ?? [:]
            totalsBySelection[selectionKey] = timeStatus.totalAvailableMinutes
            defaults.set(totalsBySelection, forKey: usageTotalsBySelectionKey)
        }

        var totalsByToken = defaults.dictionary(forKey: usageTotalsByTokenKey) as? [String: Int] ?? [:]
        for tokenKey in tokenKeys(for: limit).map({ "token:\($0)" }) {
            totalsByToken[tokenKey] = timeStatus.totalAvailableMinutes
        }
        defaults.set(totalsByToken, forKey: usageTotalsByTokenKey)
    }

    private func usageSelectionKey(for limit: AppLimitPolicy) -> String? {
        let keys = tokenKeys(for: limit)
        guard !keys.isEmpty else { return nil }
        return keys.map { "token:\($0)" }.sorted().joined(separator: "|")
    }

    private func tokenKeys(for limit: AppLimitPolicy) -> [String] {
        let appKeys = limit.selection.applicationTokens.compactMap(encodedTokenKey)
        let webKeys = limit.selection.webDomainTokens.compactMap(encodedTokenKey)
        return appKeys + webKeys
    }

    private func encodedTokenKey<T: Encodable>(_ token: T) -> String? {
        try? JSONEncoder().encode(token).base64EncodedString()
    }

    private func requestApprovalRow(_ request: AppTimeRequest) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.requesterName)
                        .font(Theme.Font.heading())
                    Text("\(request.limitTitle) • \(request.requestedMinutes) \(L("common.minutes", "minutes"))")
                        .font(Theme.Font.caption())
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(requestStatusTitle(request.status))
                    .font(Theme.Font.caption())
                    .foregroundStyle(request.status == .open ? Theme.warning : Theme.textSecondary)
            }
            if request.status == .open {
                HStack {
                    Button(L("approvals.approve", "Approve")) {
                        Task { await blockingManager.resolveRequest(request, approved: true) }
                    }
                    .buttonStyle(PrimaryPillButtonStyle(compact: true))

                    Button(L("approvals.decline", "Decline")) {
                        Task { await blockingManager.resolveRequest(request, approved: false) }
                    }
                    .buttonStyle(SecondaryPillButtonStyle(compact: true))
                }
            } else if let resolvedByName = request.resolvedByName {
                Text("\(L("approvals.resolved_by", "Resolved by")) \(resolvedByName)")
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .sectionPanel()
    }

    private var requestHistory: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle(L("request.history", "Your requests"), icon: "clock.arrow.circlepath")
            if blockingManager.ownRequests.isEmpty {
                Text(L("request.none_yet", "No requests yet."))
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(blockingManager.ownRequests) { request in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(request.limitTitle)
                                .font(Theme.Font.heading(16))
                            Text("\(request.requestedMinutes) min • \(requestStatusTitle(request.status))")
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

    private func nameSetupSheet(canCancel: Bool) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(L("name.title", "Choose your name"))
                        .font(Theme.Font.title(30))
                        .foregroundStyle(Theme.textPrimary)
                    Text(L("name.subtitle", "This name is shown in friend requests and time requests. It does not have to be unique."))
                        .font(Theme.Font.body())
                        .foregroundStyle(Theme.textSecondary)
                }

                TextField(L("name.placeholder", "Name"), text: $profileNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                    .onAppear {
                        if profileNameDraft.isEmpty && blockingManager.currentUserDisplayName != "Guest" && blockingManager.currentUserDisplayName != "Apple User" {
                            profileNameDraft = blockingManager.currentUserDisplayName
                        }
                    }

                Button {
                    Task {
                        await blockingManager.saveDisplayName(profileNameDraft)
                        editingProfileName = false
                    }
                } label: {
                    Label(L("name.save", "Save name"), systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                statusMessages
                Spacer()
            }
            .padding(Theme.Spacing.lg)
            .background(Theme.background)
            .interactiveDismissDisabled(!canCancel)
            .toolbar {
                if canCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("editor.cancel", "Cancel")) {
                            editingProfileName = false
                            blockingManager.needsDisplayName = false
                        }
                    }
                }
            }
        }
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
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: PullDistancePreferenceKey.self, value: max(0, proxy.frame(in: .named("refreshScroll")).minY))
                }
                .frame(height: 0)

                content()
            }
            .padding(Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .coordinateSpace(name: "refreshScroll")
        .onPreferenceChange(PullDistancePreferenceKey.self) { distance in
            pullDistance = distance
            if isDraggingToRefresh {
                maxPullDistance = max(maxPullDistance, distance)
                if !didTriggerRefreshHaptic && maxPullDistance >= refreshTriggerDistance {
                    didTriggerRefreshHaptic = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.8)
                }
            }
        }
        .simultaneousGesture(refreshDragGesture)
        .overlay(alignment: .top) {
            let visiblePullDistance = max(0, pullDistance - refreshRevealDistance)
            let showRefreshIndicator = visiblePullDistance > 0 || isManualRefreshing
            PullRefreshIndicator(
                progress: min(visiblePullDistance / (refreshTriggerDistance - refreshRevealDistance), 1),
                isRefreshing: isManualRefreshing
            )
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.sm)
            .opacity(showRefreshIndicator ? 1 : 0)
            .scaleEffect(showRefreshIndicator ? 1 : 0.92)
            .offset(y: showRefreshIndicator ? 0 : -8)
            .allowsHitTesting(false)
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: showRefreshIndicator)
            .animation(.easeInOut(duration: 0.18), value: isManualRefreshing)
        }
    }

    private var refreshDragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { _ in
                if !isManualRefreshing {
                    isDraggingToRefresh = true
                    maxPullDistance = max(maxPullDistance, pullDistance)
                    if !didTriggerRefreshHaptic && maxPullDistance >= refreshTriggerDistance {
                        didTriggerRefreshHaptic = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.8)
                    }
                }
            }
            .onEnded { _ in
                let shouldRefresh = max(maxPullDistance, pullDistance) >= refreshTriggerDistance
                isDraggingToRefresh = false
                maxPullDistance = 0
                didTriggerRefreshHaptic = false
                if shouldRefresh && !isManualRefreshing {
                    Task { await manuallyRefresh() }
                }
            }
    }

    private func manuallyRefresh() async {
        guard !isManualRefreshing else { return }
        isManualRefreshing = true
        await blockingManager.refreshRemoteChanges()
        try? await Task.sleep(nanoseconds: 350_000_000)
        isManualRefreshing = false
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

    private func L(_ key: String, _ fallback: String) -> String {
        localization.text(key, fallback: fallback)
    }

    private func limitModeTitle(_ mode: LimitMode) -> String {
        switch mode {
        case .shared:
            return L("mode.shared", "All apps together")
        case .individual:
            return L("mode.individual", "Each app individually")
        }
    }

    private func requestStatusTitle(_ status: TimeRequestStatus) -> String {
        switch status {
        case .open:
            return L("status.open", "Open")
        case .approved:
            return L("status.approved", "Approved")
        case .declined:
            return L("status.declined", "Declined")
        }
    }

    private func normalizeSelectedLanguage() {
        guard !localization.availableLanguages.contains(where: { $0.code == appLanguageRaw }) else {
            localization.loadLanguage(appLanguageRaw)
            return
        }
        appLanguageRaw = localization.availableLanguages.first(where: { $0.code == "en-US" })?.code ??
            localization.availableLanguages.first?.code ??
            "en-US"
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

    func localizedTitle(_ text: (String, String) -> String) -> String {
        switch self {
        case .system: return text("appearance.system", "System")
        case .light: return text("appearance.light", "Light")
        case .dark: return text("appearance.dark", "Dark")
        }
    }
}

private struct PullDistancePreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PullRefreshIndicator: View {
    var progress: CGFloat
    var isRefreshing: Bool

    var body: some View {
        let clampedProgress = min(max(progress, 0), 1)

        HStack(spacing: Theme.Spacing.sm) {
            ZStack {
                Circle()
                    .stroke(Theme.border, lineWidth: 3)
                    .frame(width: 30, height: 30)

                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.accent)
                } else {
                    Circle()
                        .trim(from: 0, to: max(0.08, clampedProgress))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 30, height: 30)
                        .rotationEffect(.degrees(Double(clampedProgress) * 250))
                        .animation(.spring(response: 0.26, dampingFraction: 0.72), value: clampedProgress)

                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .scaleEffect(0.75 + clampedProgress * 0.25)
                        .rotationEffect(.degrees(clampedProgress >= 1 ? 180 : 0))
                        .animation(.spring(response: 0.24, dampingFraction: 0.7), value: clampedProgress >= 1)
                }
            }

            Text(isRefreshing ? "Refreshing..." : (clampedProgress >= 1 ? "Release to refresh" : "Pull to refresh"))
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
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

extension DeviceActivityReport.Context {
    static let boundLimitUsage = Self("BoundLimitUsage")
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

#if !CODEX_TYPECHECK
#Preview {
    ContentView()
}
#endif
