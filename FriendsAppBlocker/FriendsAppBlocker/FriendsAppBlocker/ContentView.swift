import SwiftUI
import FamilyControls
import AuthenticationServices

struct ContentView: View {
    @StateObject private var blockingManager = BlockingManager.shared
    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.enUS.rawValue
    @AppStorage("appAppearance") private var appAppearanceRaw = AppAppearance.system.rawValue
    @State private var showingAppPicker = false
    @State private var inviteName = ""
    @State private var joinName = ""
    @State private var joinCode = ""
    @State private var inviteUserID = ""
    @State private var timeRequestMinutes = 15
    @State private var responseMinutes = 15
    @State private var focusLimitMinutes = 30
    @State private var selectedTab: AppTab = .request

    private enum AppTab: Hashable {
        case request
        case manager
        case people
        case pulse
        case settings
    }

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRaw) ?? .enUS
    }

    private var appAppearance: AppAppearance {
        AppAppearance(rawValue: appAppearanceRaw) ?? .system
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding {
            appLanguage
        } set: { newValue in
            appLanguageRaw = newValue.rawValue
        }
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding {
            appAppearance
        } set: { newValue in
            appAppearanceRaw = newValue.rawValue
        }
    }

    private func t(_ key: String) -> String {
        L10n.text(key, language: appLanguage)
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
        .sheet(isPresented: $showingAppPicker, onDismiss: {
            blockingManager.selectionDidChange()
        }) {
            NavigationStack {
                FamilyActivityPicker(selection: $blockingManager.selectedApps)
                    .navigationTitle(t("appsSites"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(t("done")) {
                                showingAppPicker = false
                            }
                            .foregroundStyle(Theme.accent)
                        }
                    }
            }
        }
        .task {
            if blockingManager.supportsFamilyControls && !blockingManager.isAuthorized {
                try? await blockingManager.requestAuthorization()
            }
            focusLimitMinutes = blockingManager.familyState.focusLimitMinutes
            if blockingManager.isAuthenticated {
                await blockingManager.loadPendingInvites()
            }
        }
        .preferredColorScheme(appAppearance.colorScheme)
    }

    private var loginView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                Spacer(minLength: 34)

                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ZStack {
                        Circle()
                            .fill(Theme.accentSoft)
                            .frame(width: 72, height: 72)
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }

                    Text(t("appName"))
                        .font(Theme.Font.title(38))
                        .foregroundStyle(Theme.textPrimary)

                    Text(t("loginSubtitle"))
                        .font(Theme.Font.body(17))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: Theme.Spacing.md) {
                    SignInWithAppleButton(.continue) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        Task {
                            await blockingManager.handleAuthorizationResult(result)
                        }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))

                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Label(t("developmentLogin"), systemImage: "hammer.fill")
                            .font(Theme.Font.caption())
                            .foregroundStyle(Theme.textSecondary)

                        HStack(spacing: Theme.Spacing.sm) {
                            Button {
                                blockingManager.signInForDevelopment(as: .owner)
                            } label: {
                                Label(t("owner"), systemImage: "crown.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(SecondaryPillButtonStyle())

                            Button {
                                blockingManager.signInForDevelopment(as: .member)
                            } label: {
                                Label(t("friend"), systemImage: "person.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(SecondaryPillButtonStyle())
                        }
                    }
                    .padding(Theme.Spacing.md)
                    .background(Theme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                    .overlay(cardBorder)
                }

                if let authError = blockingManager.authError {
                    statusBanner(text: authError, icon: "exclamationmark.triangle.fill", color: Theme.destructive)
                }
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    private var dashboard: some View {
        TabView(selection: $selectedTab) {
            requestPage
                .tabItem {
                    Label(t("tabRequest"), systemImage: "paperplane.fill")
                }
                .tag(AppTab.request)

            managerPage
                .tabItem {
                    Label(t("tabManage"), systemImage: "slider.horizontal.3")
                }
                .tag(AppTab.manager)

            peoplePage
                .tabItem {
                    Label(t("tabPeople"), systemImage: "person.2.fill")
                }
                .tag(AppTab.people)

            pulsePage
                .tabItem {
                    Label(t("tabPulse"), systemImage: "waveform.path.ecg")
                }
                .tag(AppTab.pulse)

            settingsPage
                .tabItem {
                    Label(t("tabSettings"), systemImage: "gearshape.fill")
                }
                .tag(AppTab.settings)
        }
        .tint(Theme.accent)
    }

    private var requestPage: some View {
        pageScroll {
            headerSection(title: t("requestTitle"), subtitle: t("requestSubtitle"))
            focusHero
            requestMoreTimeSection
            quickStats
        }
    }

    private var managerPage: some View {
        pageScroll {
            headerSection(title: t("managerTitle"), subtitle: managerSubtitle)
            managerControlSection
            managerRequestsSection
            appSelectionSection
        }
    }

    private var peoplePage: some View {
        pageScroll {
            headerSection(title: t("peopleTitle"), subtitle: t("peopleSubtitle"))
            accessSection
        }
    }

    private var pulsePage: some View {
        pageScroll {
            headerSection(title: t("pulseTitle"), subtitle: t("pulseSubtitle"))
            quickStats
            pulseSection
        }
    }

    private var settingsPage: some View {
        pageScroll {
            headerSection(title: t("settingsTitle"), subtitle: blockingManager.isDeveloperSession ? t("developmentSession") : t("signedInWithApple"))
            appearanceSection
            languageSection
            accountSection
            settingsInfoSection
        }
    }

    private func pageScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                content()
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.xl)
        }
    }

    private func headerSection(title: String, subtitle: String) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.Font.title(30))
                    .foregroundStyle(Theme.textPrimary)

                Text(subtitle)
                    .font(Theme.Font.caption())
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()
        }
    }

    private var focusHero: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Label(blockingManager.isBlocking ? t("blockingActive") : t("readyToBlock"), systemImage: blockingManager.isBlocking ? "lock.fill" : "lock.open.fill")
                        .font(Theme.Font.caption())
                        .foregroundStyle(blockingManager.isBlocking ? Theme.success : Theme.textSecondary)

                    Text(blockingManager.isBlocking ? t("focusProtected") : t("chooseGuardrails"))
                        .font(Theme.Font.title(28))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                ZStack {
                    Circle()
                        .fill(blockingManager.isBlocking ? Theme.successSoft : Theme.accentSoft)
                        .frame(width: 64, height: 64)
                    Image(systemName: blockingManager.isBlocking ? "shield.fill" : "shield")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(blockingManager.isBlocking ? Theme.success : Theme.accent)
                }
            }

            if blockingManager.isBlocking {
                Text(blockingManager.activeBlockDescription)
                    .font(Theme.Font.heading())
                    .foregroundStyle(Theme.textPrimary)
            } else {
                Stepper("\(t("limit")) \(focusLimitMinutes) \(t("minutesShort"))", value: $focusLimitMinutes, in: 5...240, step: 5)
                    .font(Theme.Font.heading())
                    .onChange(of: focusLimitMinutes) { _, newValue in
                        blockingManager.updateFocusLimit(minutes: newValue)
                    }
            }
        }
        .sectionPanel()
    }

    private var quickStats: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Theme.Spacing.sm) {
            MetricTile(title: t("selection"), value: selectedCountText, icon: "square.grid.2x2.fill", tint: Theme.accent)
            MetricTile(title: t("circle"), value: "\(blockingManager.familyState.members.count)", icon: "person.2.fill", tint: Theme.success)
            MetricTile(title: t("pending"), value: "\(pendingCount)", icon: "clock.fill", tint: Theme.warning)
            MetricTile(title: t("allowance"), value: "\(blockingManager.familyState.extraTimeMinutes)m", icon: "timer", tint: Theme.destructive)
        }
    }

    private var requestMoreTimeSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle(t("askManagers"), icon: "paperplane.fill")

            Text(t("askManagersDescription"))
                .font(Theme.Font.body())
                .foregroundStyle(Theme.textSecondary)

            Stepper("\(t("request")) \(timeRequestMinutes) \(t("minutesShort"))", value: $timeRequestMinutes, in: 5...120, step: 5)
                .font(Theme.Font.heading())

            Button {
                blockingManager.requestExtraTime(
                    minutes: timeRequestMinutes,
                    from: FamilyMember(
                        id: UUID(),
                        name: blockingManager.currentUserDisplayName,
                        role: blockingManager.currentUserRole,
                        permissions: [.grantTime],
                        joinedAt: Date(),
                        isApprovedForAdmin: blockingManager.currentUserApprovedForAdmin,
                        appleUserID: blockingManager.currentUserIdentifier,
                        appUserID: blockingManager.currentAppUserID
                    )
                )
                selectedTab = .pulse
            } label: {
                Label(t("requestMoreTime"), systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryPillButtonStyle())

            if blockingManager.familyState.timeRequests.isEmpty {
                statusBanner(text: t("noOpenRequests"), icon: "checkmark.circle.fill", color: Theme.success)
            } else {
                statusBanner(text: String(format: t("requestsWaiting"), blockingManager.familyState.timeRequests.count), icon: "clock.fill", color: Theme.warning)
            }
        }
        .sectionPanel()
    }

    private var managerControlSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle(t("blockControls"), icon: "lock.fill")

            if !blockingManager.canManageBlocking {
                statusBanner(text: t("needsOwnerApproval"), icon: "hourglass", color: Theme.warning)
            }

            Stepper("\(t("defaultLimit")) \(focusLimitMinutes) \(t("minutesShort"))", value: $focusLimitMinutes, in: 5...240, step: 5)
                .font(Theme.Font.heading())
                .disabled(!blockingManager.canManageBlocking)
                .onChange(of: focusLimitMinutes) { _, newValue in
                    blockingManager.updateFocusLimit(minutes: newValue)
                }

            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    if blockingManager.isBlocking {
                        blockingManager.disableBlocking()
                    } else {
                        blockingManager.enableBlocking(minutes: focusLimitMinutes)
                    }
                } label: {
                    Label(blockingManager.isBlocking ? t("unlock") : t("startLimit"), systemImage: blockingManager.isBlocking ? "lock.open.fill" : "lock.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(!blockingManager.canManageBlocking || (!blockingManager.isBlocking && !blockingManager.hasItemsToBlock))

                Button {
                    blockingManager.enableBlocking()
                } label: {
                    Image(systemName: "infinity")
                        .frame(width: 48)
                }
                .buttonStyle(SecondaryPillButtonStyle())
                .disabled(!blockingManager.canManageBlocking || blockingManager.isBlocking || !blockingManager.hasItemsToBlock)
                .accessibilityLabel(t("blockNoLimit"))
            }

            if !blockingManager.hasItemsToBlock {
                statusBanner(text: t("pickAppsFirst"), icon: "app.badge", color: Theme.warning)
            }
        }
        .sectionPanel()
    }

    private var managerRequestsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle(t("approveRequests"), icon: "checkmark.seal.fill")

            if !blockingManager.canManageBlocking {
                Text(t("onlyManagersAnswer"))
                    .font(Theme.Font.body())
                    .foregroundStyle(Theme.textSecondary)
            } else if blockingManager.familyState.timeRequests.isEmpty {
                statusBanner(text: t("noRequestsWaiting"), icon: "checkmark.circle.fill", color: Theme.success)
            } else {
                ForEach(blockingManager.familyState.timeRequests) { request in
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(request.requestedBy.name)
                                    .font(Theme.Font.heading())
                                    .foregroundStyle(Theme.textPrimary)
                                Text("\(t("requested")) \(request.requestedMinutes) \(t("minutes"))")
                                    .font(Theme.Font.caption())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "timer")
                                .foregroundStyle(Theme.accent)
                        }

                        Stepper("\(t("approve")) \(responseMinutes) \(t("minutesShort"))", value: $responseMinutes, in: 5...120, step: 5)

                        HStack(spacing: Theme.Spacing.sm) {
                            Button(t("approve")) {
                                blockingManager.respondToTimeRequest(request, approved: true, minutes: responseMinutes)
                            }
                            .buttonStyle(PrimaryPillButtonStyle(compact: true))

                            Button(t("decline")) {
                                blockingManager.respondToTimeRequest(request, approved: false, minutes: 0)
                            }
                            .buttonStyle(SecondaryPillButtonStyle(compact: true))
                        }
                    }
                    .padding(Theme.Spacing.md)
                    .background(Theme.controlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                }
            }
        }
        .sectionPanel()
    }

    private var appSelectionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle(t("appsSites"), icon: "app.badge")

            Button {
                showingAppPicker = true
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "plus.app.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(blockingManager.hasItemsToBlock ? selectionSummary : t("selectAppsSites"))
                            .font(Theme.Font.heading())
                            .foregroundStyle(Theme.textPrimary)
                        Text(t("sharedSelectionDescription"))
                            .font(Theme.Font.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!blockingManager.canManageBlocking)
        }
        .sectionPanel()
    }

    private var pulseSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle(t("circlePulse"), icon: "waveform.path.ecg")

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                PulseRow(icon: "shield.fill", title: t("protection"), value: blockingManager.isBlocking ? t("active") : t("idle"), tint: blockingManager.isBlocking ? Theme.success : Theme.textSecondary)
                PulseRow(icon: "timer", title: t("currentLimit"), value: blockingManager.isBlocking ? blockingManager.activeBlockDescription : "\(blockingManager.familyState.focusLimitMinutes) \(t("minutesShort"))", tint: Theme.accent)
                PulseRow(icon: "person.2.fill", title: t("managers"), value: "\(managerCount)", tint: Theme.success)
                PulseRow(icon: "exclamationmark.bubble.fill", title: t("openRequests"), value: "\(blockingManager.familyState.timeRequests.count)", tint: blockingManager.familyState.timeRequests.isEmpty ? Theme.textSecondary : Theme.warning)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(t("nextBestAction"))
                    .font(Theme.Font.heading())
                    .foregroundStyle(Theme.textPrimary)

                Button {
                    selectedTab = nextActionTab
                } label: {
                    Label(nextActionTitle, systemImage: nextActionIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryPillButtonStyle())
            }
        }
        .sectionPanel()
    }

    private var settingsInfoSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle(t("appState"), icon: "info.circle.fill")

            PulseRow(icon: "icloud.fill", title: t("sync"), value: blockingManager.isDeveloperSession ? t("localDev") : (blockingManager.isSyncing ? t("syncing") : "CloudKit"), tint: Theme.accent)
            PulseRow(icon: "checkmark.shield.fill", title: t("familyControls"), value: blockingManager.isAuthorized ? t("allowed") : t("needsApproval"), tint: blockingManager.isAuthorized ? Theme.success : Theme.warning)
            PulseRow(icon: "person.text.rectangle.fill", title: t("role"), value: blockingManager.currentUserRole == .owner ? t("owner") : (blockingManager.currentUserApprovedForAdmin ? t("manager") : t("member")), tint: Theme.success)

            Button {
                blockingManager.signOut()
            } label: {
                Label(t("signOut"), systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryPillButtonStyle())
        }
        .sectionPanel()
    }

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle(t("language"), icon: "globe")

            Picker(t("language"), selection: languageBinding) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName)
                        .tag(language)
                }
            }
            .pickerStyle(.segmented)
        }
        .sectionPanel()
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle(t("appearance"), icon: "circle.lefthalf.filled")

            Picker(t("appearance"), selection: appearanceBinding) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title(language: appLanguage))
                        .tag(appearance)
                }
            }
            .pickerStyle(.segmented)
        }
        .sectionPanel()
    }

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle(t("trustedAccess"), icon: "person.crop.circle.badge.checkmark")

            if blockingManager.currentUserRole == .owner {
                inviteControls
            }

            joinControls

            if !blockingManager.pendingInvites.isEmpty {
                pendingInvites
            }

            if blockingManager.hasFamilyMembers {
                memberList
            }
        }
        .sectionPanel()
    }

    private var inviteControls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(t("invite"))
                .font(Theme.Font.heading())
                .foregroundStyle(Theme.textPrimary)

            TextField(t("yourDisplayName"), text: $inviteName)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    if let invite = blockingManager.createInvitation(for: inviteName) {
                        inviteName = invite.ownerName
                    }
                } label: {
                    Label(t("code"), systemImage: "number")
                }
                .buttonStyle(PrimaryPillButtonStyle())

                if let invite = blockingManager.familyState.activeInvite {
                    ShareLink(item: invite.code) {
                        Label(invite.code, systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(SecondaryPillButtonStyle())
                }
            }

            TextField(t("friendID"), text: $inviteUserID)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button {
                Task {
                    let success = await blockingManager.inviteUser(with: inviteUserID)
                    if success {
                        inviteUserID = ""
                    }
                }
            } label: {
                Label(t("sendFriendIDInvite"), systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryPillButtonStyle())
            .disabled(inviteUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var joinControls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(t("join"))
                .font(Theme.Font.heading())
                .foregroundStyle(Theme.textPrimary)

            TextField(t("yourName"), text: $joinName)
                .textFieldStyle(.roundedBorder)
            TextField(t("inviteCode"), text: $joinCode)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.characters)

            Button {
                Task {
                    let success = await blockingManager.joinFamily(with: joinCode, memberName: joinName)
                    if success {
                        joinCode = ""
                        joinName = ""
                    }
                }
            } label: {
                Label(t("joinCircle"), systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryPillButtonStyle())
            .disabled(joinCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var pendingInvites: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(t("invites"))
                .font(Theme.Font.heading())
                .foregroundStyle(Theme.textPrimary)

            ForEach(blockingManager.pendingInvites) { invite in
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "envelope.badge.fill")
                        .foregroundStyle(Theme.accent)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(invite.fromName)
                            .font(Theme.Font.heading(16))
                            .foregroundStyle(Theme.textPrimary)
                        Text(t("wantsToAddYou"))
                            .font(Theme.Font.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }

                    Spacer()

                    Button(t("accept")) {
                        Task {
                            _ = await blockingManager.acceptInvite(invite)
                        }
                    }
                    .buttonStyle(PrimaryPillButtonStyle(compact: true))
                }
            }
        }
    }

    private var memberList: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(t("circle"))
                .font(Theme.Font.heading())
                .foregroundStyle(Theme.textPrimary)

            ForEach(blockingManager.familyState.members) { member in
                HStack(spacing: Theme.Spacing.md) {
                    Circle()
                        .fill(member.isApprovedForAdmin ? Theme.successSoft : Theme.warningSoft)
                        .frame(width: 38, height: 38)
                        .overlay {
                            Image(systemName: member.role == .owner ? "crown.fill" : "person.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(member.isApprovedForAdmin ? Theme.success : Theme.warning)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.name)
                            .font(Theme.Font.heading(16))
                            .foregroundStyle(Theme.textPrimary)
                        Text(member.role == .owner ? t("owner") : (member.isApprovedForAdmin ? t("approvedFriend") : t("waitingApproval")))
                            .font(Theme.Font.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }

                    Spacer()

                    if blockingManager.currentUserRole == .owner && member.role == .member {
                        HStack(spacing: Theme.Spacing.xs) {
                            if !member.isApprovedForAdmin {
                                Button {
                                    blockingManager.approveMember(member)
                                } label: {
                                    Image(systemName: "checkmark")
                                }
                                .buttonStyle(IconCircleButtonStyle(compact: true, tint: Theme.success))
                                .accessibilityLabel(t("approveAccess"))
                            }

                            Button {
                                blockingManager.removeMember(member)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(IconCircleButtonStyle(compact: true, tint: Theme.destructive))
                            .accessibilityLabel(t("removeMember"))
                        }
                    }
                }
            }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionTitle(t("account"), icon: "person.crop.circle")

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(blockingManager.currentUserDisplayName)
                        .font(Theme.Font.heading())
                        .foregroundStyle(Theme.textPrimary)
                    if !blockingManager.currentAppUserID.isEmpty {
                        Text(t("yourFriendID"))
                            .font(Theme.Font.caption())
                            .foregroundStyle(Theme.textSecondary)
                        Text(blockingManager.currentAppUserID)
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
            }

            if let authError = blockingManager.authError {
                statusBanner(text: authError, icon: "exclamationmark.triangle.fill", color: Theme.destructive)
            }
        }
        .sectionPanel()
    }

    private var selectionSummary: String {
        let apps = blockingManager.selectedApps.applicationTokens.count
        let sites = blockingManager.selectedApps.webDomainTokens.count
        var parts: [String] = []
        if apps > 0 { parts.append(String(format: apps == 1 ? t("oneApp") : t("manyApps"), apps)) }
        if sites > 0 { parts.append(String(format: sites == 1 ? t("oneSite") : t("manySites"), sites)) }
        return parts.isEmpty ? t("noAppsSelected") : parts.joined(separator: ", ")
    }

    private var selectedCountText: String {
        "\(blockingManager.selectedApps.applicationTokens.count + blockingManager.selectedApps.webDomainTokens.count)"
    }

    private var pendingCount: Int {
        blockingManager.familyState.members.filter { !$0.isApprovedForAdmin }.count + blockingManager.pendingInvites.count
    }

    private var managerCount: Int {
        blockingManager.familyState.members.filter { $0.role == .owner || $0.isApprovedForAdmin }.count
    }

    private var managerSubtitle: String {
        blockingManager.canManageBlocking ? t("managerSubtitleAllowed") : t("managerSubtitleWaiting")
    }

    private var nextActionTab: AppTab {
        if !blockingManager.hasItemsToBlock && blockingManager.canManageBlocking {
            return .manager
        }
        if !blockingManager.pendingInvites.isEmpty || pendingCount > 0 {
            return .people
        }
        if blockingManager.familyState.timeRequests.isEmpty {
            return .request
        }
        return .manager
    }

    private var nextActionTitle: String {
        if !blockingManager.hasItemsToBlock && blockingManager.canManageBlocking {
            return t("chooseAppsToBlock")
        }
        if !blockingManager.pendingInvites.isEmpty {
            return t("reviewInvites")
        }
        if pendingCount > 0 {
            return t("reviewPeople")
        }
        if blockingManager.familyState.timeRequests.isEmpty {
            return t("requestMoreTime")
        }
        return t("answerRequests")
    }

    private var nextActionIcon: String {
        switch nextActionTab {
        case .request: return "paperplane.fill"
        case .manager: return "slider.horizontal.3"
        case .people: return "person.2.fill"
        case .pulse: return "waveform.path.ecg"
        case .settings: return "gearshape.fill"
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
            .stroke(Theme.border, lineWidth: 1)
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
    }

    private func statusBanner(text: String, icon: String, color: Color) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
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

    func title(language: AppLanguage) -> String {
        switch self {
        case .system: return L10n.text("appearanceSystem", language: language)
        case .light: return L10n.text("appearanceLight", language: language)
        case .dark: return L10n.text("appearanceDark", language: language)
        }
    }
}

private enum L10n {
    static func text(_ key: String, language: AppLanguage) -> String {
        strings[language]?[key] ?? strings[.enUS]?[key] ?? key
    }

    private static let strings: [AppLanguage: [String: String]] = [
        .enUS: [
            "accept": "Accept",
            "account": "Account",
            "active": "Active",
            "allowed": "Allowed",
            "allowance": "Allowance",
            "appName": "Friend Blocker",
            "appState": "App State",
            "appearance": "Appearance",
            "appearanceDark": "Dark",
            "appearanceLight": "Light",
            "appearanceSystem": "System",
            "appsSites": "Apps & Sites",
            "approve": "Approve",
            "approveAccess": "Approve access",
            "approveRequests": "Approve Requests",
            "answerRequests": "Answer requests",
            "askManagers": "Ask Managers",
            "askManagersDescription": "Send a time request to the approved people in your circle.",
            "blockControls": "Block Controls",
            "blockingActive": "Blocking active",
            "blockNoLimit": "Block without a time limit",
            "chooseAppsToBlock": "Choose apps to block",
            "chooseGuardrails": "Choose your guardrails",
            "circle": "Circle",
            "circlePulse": "Circle Pulse",
            "code": "Code",
            "currentLimit": "Current limit",
            "decline": "Decline",
            "defaultLimit": "Default limit",
            "developmentLogin": "Development login",
            "developmentSession": "Development session",
            "done": "Done",
            "familyControls": "Family Controls",
            "focusProtected": "Focus is protected",
            "friend": "Friend",
            "friendID": "Friend ID",
            "idle": "Idle",
            "invite": "Invite",
            "inviteCode": "Invite code",
            "invites": "Invites",
            "join": "Join",
            "joinCircle": "Join circle",
            "language": "Language",
            "limit": "Limit",
            "localDev": "Local dev",
            "loginSubtitle": "Let trusted friends control your app blocks and focus limits when you want help staying off distracting apps.",
            "manager": "Manager",
            "managerSubtitleAllowed": "Approve requests and control blocks",
            "managerSubtitleWaiting": "Waiting for owner approval",
            "managerTitle": "Manager",
            "managers": "Managers",
            "manyApps": "%d apps",
            "manySites": "%d sites",
            "member": "Member",
            "minutes": "minutes",
            "minutesShort": "min",
            "needsApproval": "Needs approval",
            "needsOwnerApproval": "You need owner approval before you can manage blocking.",
            "nextBestAction": "Next best action",
            "noAppsSelected": "No apps selected",
            "noOpenRequests": "No open requests yet.",
            "noRequestsWaiting": "No requests waiting.",
            "oneApp": "%d app",
            "oneSite": "%d site",
            "onlyManagersAnswer": "Only approved managers can answer time requests.",
            "openRequests": "Open requests",
            "owner": "Owner",
            "pending": "Pending",
            "peopleSubtitle": "Invite friends and approve access",
            "peopleTitle": "People",
            "pickAppsFirst": "Pick apps or sites before starting a block.",
            "protection": "Protection",
            "pulseSubtitle": "Your focus circle at a glance",
            "pulseTitle": "Pulse",
            "readyToBlock": "Ready to block",
            "removeMember": "Remove member",
            "request": "Request",
            "requested": "Requested",
            "requestMoreTime": "Request more time",
            "requestSubtitle": "Ask your managers for more time",
            "requestsWaiting": "%d request(s) waiting for a manager.",
            "requestTitle": "Request",
            "reviewInvites": "Review invites",
            "reviewPeople": "Review people",
            "role": "Role",
            "selectAppsSites": "Select apps and sites",
            "selection": "Selection",
            "sendFriendIDInvite": "Send Friend ID invite",
            "settingsTitle": "Settings",
            "sharedSelectionDescription": "Friends can apply limits to this shared selection.",
            "signOut": "Sign out",
            "signedInWithApple": "Signed in with Apple",
            "startLimit": "Start limit",
            "sync": "Sync",
            "syncing": "Syncing",
            "tabManage": "Manage",
            "tabPeople": "People",
            "tabPulse": "Pulse",
            "tabRequest": "Request",
            "tabSettings": "Settings",
            "trustedAccess": "Trusted Access",
            "unlock": "Unlock",
            "waitingApproval": "Waiting approval",
            "wantsToAddYou": "Wants to add you",
            "yourDisplayName": "Your display name",
            "yourFriendID": "Your Friend ID",
            "yourName": "Your name",
            "approvedFriend": "Approved friend"
        ],
        .de: [
            "accept": "Annehmen",
            "account": "Account",
            "active": "Aktiv",
            "allowed": "Erlaubt",
            "allowance": "Extra-Zeit",
            "appName": "Friend Blocker",
            "appState": "App-Status",
            "appearance": "Darstellung",
            "appearanceDark": "Dunkel",
            "appearanceLight": "Hell",
            "appearanceSystem": "System",
            "appsSites": "Apps & Websites",
            "approve": "Genehmigen",
            "approveAccess": "Zugriff erlauben",
            "approveRequests": "Anfragen genehmigen",
            "answerRequests": "Anfragen beantworten",
            "askManagers": "Manager fragen",
            "askManagersDescription": "Sende eine Zeitanfrage an die genehmigten Personen in deinem Kreis.",
            "blockControls": "Blockiersteuerung",
            "blockingActive": "Blockierung aktiv",
            "blockNoLimit": "Ohne Zeitlimit blockieren",
            "chooseAppsToBlock": "Apps zum Blockieren wählen",
            "chooseGuardrails": "Lege deine Grenzen fest",
            "circle": "Kreis",
            "circlePulse": "Kreis-Puls",
            "code": "Code",
            "currentLimit": "Aktuelles Limit",
            "decline": "Ablehnen",
            "defaultLimit": "Standardlimit",
            "developmentLogin": "Entwickler-Login",
            "developmentSession": "Entwicklersitzung",
            "done": "Fertig",
            "familyControls": "Family Controls",
            "focusProtected": "Fokus ist geschützt",
            "friend": "Freund",
            "friendID": "Friend ID",
            "idle": "Inaktiv",
            "invite": "Einladen",
            "inviteCode": "Einladungscode",
            "invites": "Einladungen",
            "join": "Beitreten",
            "joinCircle": "Kreis beitreten",
            "language": "Sprache",
            "limit": "Limit",
            "localDev": "Lokaler Dev-Modus",
            "loginSubtitle": "Lass vertrauenswürdige Freunde deine App-Blockierungen und Fokuslimits steuern, wenn du Hilfe gegen ablenkende Apps brauchst.",
            "manager": "Manager",
            "managerSubtitleAllowed": "Anfragen genehmigen und Blockierungen steuern",
            "managerSubtitleWaiting": "Wartet auf Genehmigung durch den Owner",
            "managerTitle": "Manager",
            "managers": "Manager",
            "manyApps": "%d Apps",
            "manySites": "%d Websites",
            "member": "Mitglied",
            "minutes": "Minuten",
            "minutesShort": "Min",
            "needsApproval": "Genehmigung nötig",
            "needsOwnerApproval": "Du brauchst die Genehmigung des Owners, bevor du Blockierungen verwalten kannst.",
            "nextBestAction": "Nächster sinnvoller Schritt",
            "noAppsSelected": "Keine Apps ausgewählt",
            "noOpenRequests": "Noch keine offenen Anfragen.",
            "noRequestsWaiting": "Keine wartenden Anfragen.",
            "oneApp": "%d App",
            "oneSite": "%d Website",
            "onlyManagersAnswer": "Nur genehmigte Manager können Zeitanfragen beantworten.",
            "openRequests": "Offene Anfragen",
            "owner": "Owner",
            "pending": "Offen",
            "peopleSubtitle": "Freunde einladen und Zugriff genehmigen",
            "peopleTitle": "Personen",
            "pickAppsFirst": "Wähle zuerst Apps oder Websites aus.",
            "protection": "Schutz",
            "pulseSubtitle": "Dein Fokus-Kreis auf einen Blick",
            "pulseTitle": "Puls",
            "readyToBlock": "Bereit zum Blockieren",
            "removeMember": "Mitglied entfernen",
            "request": "Anfrage",
            "requested": "Angefragt",
            "requestMoreTime": "Mehr Zeit anfragen",
            "requestSubtitle": "Frage deine Manager nach mehr Zeit",
            "requestsWaiting": "%d Anfrage(n) warten auf einen Manager.",
            "requestTitle": "Anfrage",
            "reviewInvites": "Einladungen prüfen",
            "reviewPeople": "Personen prüfen",
            "role": "Rolle",
            "selectAppsSites": "Apps und Websites auswählen",
            "selection": "Auswahl",
            "sendFriendIDInvite": "Friend-ID-Einladung senden",
            "settingsTitle": "Einstellungen",
            "sharedSelectionDescription": "Freunde können Limits auf diese gemeinsame Auswahl anwenden.",
            "signOut": "Abmelden",
            "signedInWithApple": "Mit Apple angemeldet",
            "startLimit": "Limit starten",
            "sync": "Sync",
            "syncing": "Synchronisiert",
            "tabManage": "Manager",
            "tabPeople": "Personen",
            "tabPulse": "Puls",
            "tabRequest": "Anfrage",
            "tabSettings": "Einstellungen",
            "trustedAccess": "Vertrauenszugriff",
            "unlock": "Entsperren",
            "waitingApproval": "Wartet auf Genehmigung",
            "wantsToAddYou": "Möchte dich hinzufügen",
            "yourDisplayName": "Dein Anzeigename",
            "yourFriendID": "Deine Friend ID",
            "yourName": "Dein Name",
            "approvedFriend": "Genehmigter Freund"
        ]
    ]
}

private struct MetricTile: View {
    var title: String
    var value: String
    var icon: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(Theme.Font.title(24))
                .foregroundStyle(Theme.textPrimary)
            Text(title)
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 106, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        }
    }
}

private struct PulseRow: View {
    var icon: String
    var title: String
    var value: String
    var tint: Color

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12))
                .clipShape(Circle())

            Text(title)
                .font(Theme.Font.body())
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            Text(value)
                .font(Theme.Font.caption())
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
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
