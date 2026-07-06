import SwiftUI
import FamilyControls

struct ContentView: View {
    @StateObject private var blockingManager = BlockingManager.shared
    @State private var showingAppPicker = false
    @State private var inviteName = ""
    @State private var joinName = ""
    @State private var joinCode = ""
    @State private var timeRequestMinutes = 15
    @State private var responseMinutes = 15

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
        .task {
            if blockingManager.supportsFamilyControls && !blockingManager.isAuthorized {
                try? await blockingManager.requestAuthorization()
            }
        }
    }

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

    private var setupView: some View {
        VStack(spacing: Theme.Spacing.md) {
            appsSection
            familySection
        }
    }

    private var appsSection: some View {
        Button {
            if blockingManager.canManageBlocking {
                showingAppPicker = true
            } else {
                Task {
                    try? await blockingManager.requestAuthorization()
                }
            }
        } label: {
            HStack {
                Text(blockingManager.canManageBlocking
                     ? (blockingManager.hasItemsToBlock ? selectionSummary : "Select apps & sites to block")
                     : "Awaiting owner approval")
                    .foregroundStyle(blockingManager.canManageBlocking && !blockingManager.hasItemsToBlock ? Theme.textSecondary : Theme.accent)
                Spacer()
                Image(systemName: blockingManager.canManageBlocking ? "chevron.right" : "clock")
                    .foregroundStyle(Theme.accent)
            }
            .font(Theme.Font.heading())
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground)
            .cornerRadius(Theme.Radius.lg)
        }
        .disabled(!blockingManager.canManageBlocking && !blockingManager.hasItemsToBlock)
    }

    private var familySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionHeader("Admin panel & trusted access", icon: "person.2")

            Text("Approved members can manage blocking and grant extra time directly. The owner can still invite new people and request more time from the group.")
                .font(Theme.Font.body())
                .foregroundStyle(Theme.textSecondary)

            if blockingManager.currentUserRole == .owner {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Create invite")
                        .font(Theme.Font.heading())
                        .foregroundStyle(Theme.textPrimary)

                    TextField("Your name", text: $inviteName)
                        .textFieldStyle(.roundedBorder)

                    Button("Create invite") {
                        if let invite = blockingManager.createInvitation(for: inviteName) {
                            inviteName = invite.ownerName
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    if let invite = blockingManager.familyState.activeInvite {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text("Invite code")
                                .font(Theme.Font.caption())
                                .foregroundStyle(Theme.textSecondary)
                            HStack {
                                Text(invite.code)
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                    .foregroundStyle(Theme.accent)
                                ShareLink("Share", item: invite.code)
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.md)
                .background(Theme.cardBackground)
                .cornerRadius(Theme.Radius.lg)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Join with code")
                    .font(Theme.Font.heading())
                    .foregroundStyle(Theme.textPrimary)

                TextField("Your name", text: $joinName)
                    .textFieldStyle(.roundedBorder)
                TextField("Invite code", text: $joinCode)
                    .textFieldStyle(.roundedBorder)

                Button("Join circle") {
                    let success = blockingManager.joinFamily(with: joinCode, memberName: joinName)
                    if success {
                        joinCode = ""
                        joinName = ""
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(Theme.Spacing.md)
            .background(Theme.cardBackground)
            .cornerRadius(Theme.Radius.lg)

            if blockingManager.hasFamilyMembers {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Trusted circle")
                        .font(Theme.Font.heading())
                        .foregroundStyle(Theme.textPrimary)

                    ForEach(blockingManager.familyState.members) { member in
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            HStack {
                                Text(member.name)
                                    .font(Theme.Font.heading())
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text(member.role == .owner ? "Owner" : (member.isApprovedForAdmin ? "Approved" : "Pending"))
                                    .font(Theme.Font.caption())
                                    .foregroundStyle(member.isApprovedForAdmin ? Theme.accent : Theme.textSecondary)
                            }

                            if blockingManager.currentUserRole == .owner {
                                if member.role == .member {
                                    HStack(spacing: Theme.Spacing.sm) {
                                        if !member.isApprovedForAdmin {
                                            Button("Approve access") {
                                                blockingManager.approveMember(member)
                                            }
                                            .buttonStyle(.borderedProminent)
                                        }

                                        Button("Remove") {
                                            blockingManager.removeMember(member)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            } else if member.role == .member {
                                if blockingManager.currentUserApprovedForAdmin {
                                    HStack(spacing: Theme.Spacing.sm) {
                                        Button(blockingManager.isBlocking ? "Unlock" : "Block now") {
                                            blockingManager.toggleBlocking()
                                        }
                                        .buttonStyle(.borderedProminent)

                                        Button("Grant +15m") {
                                            blockingManager.grantExtraTime(minutes: 15)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, Theme.Spacing.xs)
                    }
                }
                .padding(Theme.Spacing.md)
                .background(Theme.cardBackground)
                .cornerRadius(Theme.Radius.lg)
            }

            if blockingManager.currentUserRole == .owner {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Admin panel")
                        .font(Theme.Font.heading())
                        .foregroundStyle(Theme.textPrimary)

                    Stepper("Request \(timeRequestMinutes) min", value: $timeRequestMinutes, in: 5...120, step: 5)

                    Button("Ask members for more time") {
                        blockingManager.requestExtraTime(minutes: timeRequestMinutes, from: FamilyMember(id: UUID(), name: "You", role: .owner, permissions: [.grantTime], joinedAt: Date(), isApprovedForAdmin: true))
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(Theme.Spacing.md)
                .background(Theme.cardBackground)
                .cornerRadius(Theme.Radius.lg)
            } else if blockingManager.currentUserApprovedForAdmin {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Time requests")
                        .font(Theme.Font.heading())
                        .foregroundStyle(Theme.textPrimary)

                    ForEach(blockingManager.familyState.timeRequests) { request in
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text("From \(request.requestedBy.name)")
                                .font(Theme.Font.heading())
                                .foregroundStyle(Theme.textPrimary)
                            Text(request.detail)
                                .font(Theme.Font.caption())
                                .foregroundStyle(Theme.textSecondary)

                            Stepper("Approve \(responseMinutes) min", value: $responseMinutes, in: 5...120, step: 5)

                            HStack(spacing: Theme.Spacing.sm) {
                                Button("Approve") {
                                    blockingManager.respondToTimeRequest(request, approved: true, minutes: responseMinutes)
                                }
                                .buttonStyle(.borderedProminent)

                                Button("Decline") {
                                    blockingManager.respondToTimeRequest(request, approved: false, minutes: 0)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, Theme.Spacing.xs)
                    }
                }
                .padding(Theme.Spacing.md)
                .background(Theme.cardBackground)
                .cornerRadius(Theme.Radius.lg)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Waiting for approval")
                        .font(Theme.Font.heading())
                        .foregroundStyle(Theme.textPrimary)
                    Text("The owner needs to approve your access before you can manage blocking or grant time.")
                        .font(Theme.Font.body())
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(Theme.Spacing.md)
                .background(Theme.cardBackground)
                .cornerRadius(Theme.Radius.lg)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Shared allowance")
                    .font(Theme.Font.heading())
                    .foregroundStyle(Theme.textPrimary)
                Text("\(blockingManager.familyState.extraTimeMinutes) minutes available")
                    .font(Theme.Font.body())
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(Theme.Spacing.md)
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

    private var lockedView: some View {
        VStack(spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Focus is active")
                    .font(Theme.Font.heading())
                    .foregroundStyle(Theme.textPrimary)
                Text("Apps and sites are currently blocked for this session.")
                    .font(Theme.Font.body())
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground)
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

            Button("Unlock now") {
                blockingManager.disableBlocking()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var actionButton: some View {
        Button {
            if blockingManager.isBlocking {
                blockingManager.disableBlocking()
            } else if blockingManager.canManageBlocking {
                blockingManager.enableBlocking()
            }
        } label: {
            HStack {
                Image(systemName: blockingManager.isBlocking ? "lock.fill" : "lock.open.fill")
                Text(blockingManager.isBlocking ? "Unlock focus" : "Start focus")
            }
            .font(Theme.Font.heading())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.md)
            .background(
                blockingManager.isBlocking
                    ? Theme.textSecondary
                    : (blockingManager.canManageBlocking && blockingManager.hasItemsToBlock ? Theme.accent : Theme.border)
            )
            .cornerRadius(Theme.Radius.lg)
        }
        .disabled(!blockingManager.canManageBlocking || (!blockingManager.isBlocking && !blockingManager.hasItemsToBlock))
    }
}

#Preview {
    ContentView()
}
