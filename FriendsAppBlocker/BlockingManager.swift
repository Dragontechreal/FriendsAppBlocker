import Foundation
import Combine
import FamilyControls
import ManagedSettings
import AuthenticationServices
import CloudKit

enum FamilyPermission: String, Codable, CaseIterable, Identifiable {
    var id: String { rawValue }

    case blockApps = "block_apps"
    case grantTime = "grant_time"
}

struct FamilyMember: Identifiable, Codable {
    let id: UUID
    var name: String
    var role: Role
    var permissions: [FamilyPermission]
    var joinedAt: Date
    var isApprovedForAdmin: Bool = false
    var appleUserID: String?
    var appUserID: String?

    enum Role: String, Codable {
        case owner
        case member
    }
}

struct FamilyInvitation: Identifiable, Codable {
    let id: UUID
    var code: String
    var ownerName: String
    var permissions: [FamilyPermission]
    var createdAt: Date
    var expiresAt: Date
    var note: String
}

struct FamilyTimeRequest: Identifiable, Codable {
    let id: UUID
    var requestedBy: FamilyMember
    var requestedMinutes: Int
    var detail: String
    var createdAt: Date
}

struct FriendInviteRequest: Identifiable, Codable {
    let id: UUID
    var fromUserID: String
    var fromName: String
    var toUserID: String
    var circleRecordName: String
    var status: Status
    var createdAt: Date

    enum Status: String, Codable {
        case pending
        case accepted
        case declined
    }
}

struct AppLimit: Identifiable, Codable {
    let id: UUID
    var appName: String
    var bundleIdentifier: String
    var timeLimitMinutes: Int
    var isEnabled: Bool
    var createdAt: Date
}

struct BlockRule: Identifiable, Codable {
    let id: UUID
    var appName: String
    var bundleIdentifier: String
    var isBlocked: Bool
    var targetUserID: String?
    var createdAt: Date
}

struct FamilyState: Codable {
    var members: [FamilyMember] = []
    var activeInvite: FamilyInvitation?
    var timeRequests: [FamilyTimeRequest] = []
    var extraTimeMinutes: Int = 0
    var focusLimitMinutes: Int = 30
    var blockExpiresAt: Date?
    var isBlocking: Bool = false
    var sharedSelection: FamilyActivitySelection = FamilyActivitySelection()
    var appLimits: [AppLimit] = []
    var blockRules: [BlockRule] = []
    var enrollmentStatus: EnrollmentStatus = .draft

    enum EnrollmentStatus: String, Codable {
        case draft
        case readyForReview
        case requiresMDM
    }

    enum CodingKeys: String, CodingKey {
        case members
        case activeInvite
        case timeRequests
        case extraTimeMinutes
        case focusLimitMinutes
        case blockExpiresAt
        case isBlocking
        case sharedSelection
        case appLimits
        case blockRules
        case enrollmentStatus
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        members = try container.decodeIfPresent([FamilyMember].self, forKey: .members) ?? []
        activeInvite = try container.decodeIfPresent(FamilyInvitation.self, forKey: .activeInvite)
        timeRequests = try container.decodeIfPresent([FamilyTimeRequest].self, forKey: .timeRequests) ?? []
        extraTimeMinutes = try container.decodeIfPresent(Int.self, forKey: .extraTimeMinutes) ?? 0
        focusLimitMinutes = try container.decodeIfPresent(Int.self, forKey: .focusLimitMinutes) ?? 30
        blockExpiresAt = try container.decodeIfPresent(Date.self, forKey: .blockExpiresAt)
        isBlocking = try container.decodeIfPresent(Bool.self, forKey: .isBlocking) ?? false
        sharedSelection = try container.decodeIfPresent(FamilyActivitySelection.self, forKey: .sharedSelection) ?? FamilyActivitySelection()
        appLimits = try container.decodeIfPresent([AppLimit].self, forKey: .appLimits) ?? []
        blockRules = try container.decodeIfPresent([BlockRule].self, forKey: .blockRules) ?? []
        enrollmentStatus = try container.decodeIfPresent(EnrollmentStatus.self, forKey: .enrollmentStatus) ?? .draft
    }
}

@MainActor
class BlockingManager: ObservableObject {
    static let shared = BlockingManager()

    @Published var isAuthorized = false
    @Published var isBlocking = false
    @Published var selectedApps = FamilyActivitySelection()
    @Published var familyState = FamilyState()
    @Published var currentUserRole: FamilyMember.Role = .owner
    @Published var currentUserApprovedForAdmin = true
    @Published var currentUserIdentifier: String?
    @Published var currentAppUserID = ""
    @Published var currentUserDisplayName = "Guest"
    @Published var pendingInvites: [FriendInviteRequest] = []
    @Published var isAuthenticated = false
    @Published var isDeveloperSession = false
    @Published var isSyncing = false
    @Published var authError: String?
    @Published var enforcementWarning: String?

    private let isBlockingKey = "isBlocking"
    private let selectedAppsKey = "selectedApps"
    private let familyStateKey = "familyState"
    private let currentUserIdentifierKey = "currentUserIdentifier"
    private let currentAppUserIDKey = "currentAppUserID"
    private let currentUserDisplayNameKey = "currentUserDisplayName"
    private let isDeveloperSessionKey = "isDeveloperSession"
    private let pendingInvitesKey = "pendingInvites"
    private let appContainerIdentifier = "iCloud.dev.supremezone.friendappblock"
    private let circleRecordType = "Circle"
    private let userRecordType = "UserProfile"
    private let inviteRequestRecordType = "FriendInviteRequest"
    private let deviceActivityReminder = "Reliable remote time limits require DeviceActivity and Shield extensions."
    private let blockingStore = ManagedSettingsStore()

    private var privateDatabase: CKDatabase {
        CKContainer(identifier: appContainerIdentifier).privateCloudDatabase
    }

    private var publicDatabase: CKDatabase {
        CKContainer(identifier: appContainerIdentifier).publicCloudDatabase
    }

    private var currentCircleRecordID: CKRecord.ID?
    private var currentInviteCode: String?
    private var blockingStatusTimer: AnyCancellable?

    private init() {
        updateAuthorizationStatus()
        loadState()
        applyShieldingIfNeeded()
        startBlockingStatusTimer()
    }

    private func updateAuthorizationStatus() {
        isAuthorized = AuthorizationCenter.shared.authorizationStatus == .approved
    }

    var supportsFamilyControls: Bool {
        true
    }

    var canManageBlocking: Bool {
        currentUserRole == .owner || currentUserApprovedForAdmin
    }

    var hasItemsToBlock: Bool {
        !selectedApps.applicationTokens.isEmpty || !selectedApps.webDomainTokens.isEmpty
    }

    var hasFamilyMembers: Bool {
        !familyState.members.isEmpty
    }

    func requestAuthorization() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        updateAuthorizationStatus()
    }

    func handleAuthorizationResult(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let authorization):
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                authError = "Apple sign-in did not return a valid credential."
                return
            }

            let userIdentifier = appleIDCredential.user
            let fullName = [appleIDCredential.fullName?.givenName, appleIDCredential.fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            let displayName = fullName.isEmpty ? "Apple User" : fullName

            currentUserIdentifier = userIdentifier
            currentAppUserID = existingOrGeneratedAppUserID()
            currentUserDisplayName = displayName
            isAuthenticated = true
            isDeveloperSession = false
            authError = nil

            UserDefaults.standard.set(userIdentifier, forKey: currentUserIdentifierKey)
            UserDefaults.standard.set(currentAppUserID, forKey: currentAppUserIDKey)
            UserDefaults.standard.set(displayName, forKey: currentUserDisplayNameKey)
            UserDefaults.standard.set(false, forKey: isDeveloperSessionKey)

            await saveUserProfileToCloud()
            await loadStateFromCloud()
            await loadPendingInvites()

        case .failure(let error):
            authError = error.localizedDescription
            isAuthenticated = false
        }
    }

    func signInForDevelopment(as role: FamilyMember.Role) {
        let userIdentifier = role == .owner ? "dev-owner" : "dev-friend"
        let appUserID = role == .owner ? "DEV-OWNER" : "DEV-FRIEND"
        let displayName = role == .owner ? "Dev Owner" : "Dev Friend"

        currentUserIdentifier = userIdentifier
        currentAppUserID = appUserID
        currentUserDisplayName = displayName
        isAuthenticated = true
        isDeveloperSession = true
        authError = nil

        UserDefaults.standard.set(userIdentifier, forKey: currentUserIdentifierKey)
        UserDefaults.standard.set(appUserID, forKey: currentAppUserIDKey)
        UserDefaults.standard.set(displayName, forKey: currentUserDisplayNameKey)
        UserDefaults.standard.set(true, forKey: isDeveloperSessionKey)

        if role == .owner && !familyState.members.contains(where: { $0.appleUserID == userIdentifier }) {
            familyState.members.append(FamilyMember(
                id: UUID(),
                name: displayName,
                role: .owner,
                permissions: [.blockApps, .grantTime],
                joinedAt: Date(),
                isApprovedForAdmin: true,
                appleUserID: userIdentifier,
                appUserID: appUserID
            ))
        }

        refreshCurrentUserContext()
        loadPendingDevInvites()
        saveState()
    }

    func signOut() {
        currentUserIdentifier = nil
        currentAppUserID = ""
        currentUserDisplayName = "Guest"
        isAuthenticated = false
        isDeveloperSession = false
        currentCircleRecordID = nil
        currentInviteCode = nil
        currentUserRole = .owner
        currentUserApprovedForAdmin = true
        pendingInvites = []
        selectedApps = FamilyActivitySelection()
        familyState = FamilyState()
        isBlocking = false
        blockingStore.shield.applications = nil
        blockingStore.shield.webDomains = nil
        UserDefaults.standard.removeObject(forKey: currentUserIdentifierKey)
        UserDefaults.standard.removeObject(forKey: currentAppUserIDKey)
        UserDefaults.standard.removeObject(forKey: currentUserDisplayNameKey)
        UserDefaults.standard.removeObject(forKey: isDeveloperSessionKey)
        UserDefaults.standard.removeObject(forKey: selectedAppsKey)
        UserDefaults.standard.removeObject(forKey: familyStateKey)
        UserDefaults.standard.removeObject(forKey: isBlockingKey)
    }

    var activeBlockDescription: String {
        guard let blockExpiresAt = familyState.blockExpiresAt else { return "No time limit" }
        if blockExpiresAt <= Date() { return "Expired" }
        let remaining = Int(blockExpiresAt.timeIntervalSinceNow / 60)
        return "\(max(1, remaining)) min remaining"
    }

    func enableBlocking(minutes: Int? = nil) {
        guard canManageBlocking else {
            authError = "Only approved managers can enable blocking."
            return
        }

        guard isAuthorized else {
            Task { try? await requestAuthorization() }
            return
        }

        isBlocking = true
        familyState.isBlocking = true
        if let minutes {
            familyState.focusLimitMinutes = minutes
            familyState.blockExpiresAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        } else {
            familyState.blockExpiresAt = nil
        }
        familyState.enrollmentStatus = .readyForReview
        enforcementWarning = deviceActivityReminder
        saveState()
        applyShieldingIfNeeded()
        Task { await syncStateToCloud() }
    }

    func disableBlocking() {
        guard canManageBlocking else {
            authError = "Only approved managers can disable blocking."
            return
        }

        isBlocking = false
        familyState.isBlocking = false
        familyState.blockExpiresAt = nil
        saveState()
        applyShieldingIfNeeded()
        Task { await syncStateToCloud() }
    }

    func toggleBlocking() {
        guard canManageBlocking else {
            authError = "Only approved managers can change blocking."
            return
        }

        isBlocking.toggle()
        familyState.isBlocking = isBlocking
        saveState()
        applyShieldingIfNeeded()
        Task { await syncStateToCloud() }
    }

    func checkBlockingStatus() {
        if let blockExpiresAt = familyState.blockExpiresAt, blockExpiresAt <= Date() {
            isBlocking = false
            familyState.isBlocking = false
            familyState.blockExpiresAt = nil
            saveState()
        }

        if !isAuthorized {
            isBlocking = false
        }
        applyShieldingIfNeeded()
    }

    func updateFocusLimit(minutes: Int) {
        guard canManageBlocking else {
            authError = "Only approved managers can change limits."
            return
        }

        familyState.focusLimitMinutes = minutes
        saveState()
        Task { await syncStateToCloud() }
    }

    func createInvitation(for name: String) -> FamilyInvitation? {
        guard isAuthenticated else { return nil }

        if !familyState.members.contains(where: { $0.role == .owner }) {
            let owner = FamilyMember(
                id: UUID(),
                name: name.isEmpty ? "You" : name,
                role: .owner,
                permissions: [.blockApps, .grantTime],
                joinedAt: Date(),
                isApprovedForAdmin: true,
                appleUserID: currentUserIdentifier,
                appUserID: currentAppUserID
            )
            familyState.members.append(owner)
        }

        let code = String(UUID().uuidString.prefix(8)).uppercased()
        let invite = FamilyInvitation(
            id: UUID(),
            code: code,
            ownerName: name.isEmpty ? "You" : name,
            permissions: [.blockApps, .grantTime],
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(7 * 24 * 60 * 60),
            note: "Use this code to join the shared circle."
        )

        familyState.activeInvite = invite
        currentInviteCode = code
        currentUserRole = .owner
        currentUserApprovedForAdmin = true
        familyState.enrollmentStatus = .readyForReview
        saveState()
        Task { await syncStateToCloud() }
        return invite
    }

    func joinFamily(with code: String, memberName: String) async -> Bool {
        guard let currentUserIdentifier else { return false }

        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if isDeveloperSession {
            return joinLocalFamily(with: normalizedCode, memberName: memberName, userIdentifier: currentUserIdentifier)
        }

        let query = CKQuery(recordType: circleRecordType, predicate: NSPredicate(format: "inviteCode == %@", normalizedCode))

        do {
            let (matchResults, _) = try await publicDatabase.records(matching: query)
            guard let first = matchResults.compactMap({ result -> CKRecord? in
                switch result.1 {
                case .success(let record): return record
                case .failure: return nil
                }
            }).first else {
                return false
            }

            currentCircleRecordID = first.recordID
            currentInviteCode = normalizedCode

            var incomingState = familyState
            if let data = first["stateData"] as? Data,
               let decoded = try? JSONDecoder().decode(FamilyState.self, from: data) {
                incomingState = decoded
            }

            if incomingState.members.contains(where: memberMatchesCurrentUser) {
                familyState = incomingState
                isBlocking = incomingState.isBlocking
                mergeLocalSelection(from: incomingState)
                refreshCurrentUserContext()
                saveState()
                return true
            }

            let member = FamilyMember(
                id: UUID(),
                name: memberName.isEmpty ? "Friend" : memberName,
                role: .member,
                permissions: [.blockApps, .grantTime],
                joinedAt: Date(),
                isApprovedForAdmin: false,
                appleUserID: currentUserIdentifier,
                appUserID: currentAppUserID
            )

            incomingState.members.append(member)
            familyState = incomingState
            isBlocking = incomingState.isBlocking
            mergeLocalSelection(from: incomingState)
            currentUserRole = .member
            currentUserApprovedForAdmin = false
            familyState.activeInvite = FamilyInvitation(id: UUID(), code: normalizedCode, ownerName: familyState.members.first(where: { $0.role == .owner })?.name ?? "Owner", permissions: [.blockApps, .grantTime], createdAt: Date(), expiresAt: Date().addingTimeInterval(7*24*60*60), note: "Joined via invite")
            familyState.enrollmentStatus = .readyForReview
            saveState()

            first["stateData"] = try? encodedCloudStateData() as NSData
            first["updatedAt"] = Date() as NSDate
            _ = try await publicDatabase.save(first)
            await saveUserProfileToCloud()
            return true
        } catch {
            setCloudError()
            return false
        }
    }

    func approveMember(_ member: FamilyMember) {
        guard currentUserRole == .owner else {
            authError = "Only the circle owner can approve members."
            return
        }

        if let index = familyState.members.firstIndex(where: { $0.id == member.id }) {
            familyState.members[index].isApprovedForAdmin = true
        }

        saveState()
        Task { await syncStateToCloud() }
    }

    func inviteUser(with userID: String) async -> Bool {
        guard isAuthenticated, !currentAppUserID.isEmpty else { return false }
        let normalizedUserID = normalizeAppUserID(userID)
        guard !normalizedUserID.isEmpty else { return false }

        if isDeveloperSession {
            guard let targetUserIdentifier = resolveDevUserIdentifier(for: normalizedUserID) else {
                authError = "No development user found for \(normalizedUserID)."
                return false
            }

            let request = FriendInviteRequest(
                id: UUID(),
                fromUserID: currentAppUserID,
                fromName: currentUserDisplayName,
                toUserID: targetUserIdentifier,
                circleRecordName: "local-dev-circle",
                status: .pending,
                createdAt: Date()
            )
            saveDevInvite(request)
            return true
        }

        do {
            guard let targetAppUserID = try await resolveCloudUserIdentifier(for: normalizedUserID) else {
                authError = "No user found for \(normalizedUserID)."
                return false
            }

            let circleID = try await ensureCircleRecordExists()
            let request = FriendInviteRequest(
                id: UUID(),
                fromUserID: currentAppUserID,
                fromName: currentUserDisplayName,
                toUserID: targetAppUserID,
                circleRecordName: circleID.recordName,
                status: .pending,
                createdAt: Date()
            )
            let record = CKRecord(recordType: inviteRequestRecordType, recordID: CKRecord.ID(recordName: "invite_\(request.id.uuidString)"))
            write(request, to: record)
            _ = try await publicDatabase.save(record)
            return true
        } catch {
            setCloudError()
            return false
        }
    }

    func loadPendingInvites() async {
        guard !currentAppUserID.isEmpty else { return }
        if isDeveloperSession {
            loadPendingDevInvites()
            return
        }

        let predicate = NSPredicate(format: "toUserID == %@ AND status == %@", currentAppUserID, FriendInviteRequest.Status.pending.rawValue)
        let query = CKQuery(recordType: inviteRequestRecordType, predicate: predicate)

        do {
            let (matchResults, _) = try await publicDatabase.records(matching: query)
            pendingInvites = matchResults.compactMap { result in
                switch result.1 {
                case .success(let record): return readInviteRequest(from: record)
                case .failure: return nil
                }
            }
        } catch {
            setCloudError()
        }
    }

    func acceptInvite(_ invite: FriendInviteRequest) async -> Bool {
        guard let currentUserIdentifier else { return false }
        if isDeveloperSession {
            if !familyState.members.contains(where: { $0.appleUserID == currentUserIdentifier }) {
                familyState.members.append(FamilyMember(
                    id: UUID(),
                    name: currentUserDisplayName,
                    role: .member,
                    permissions: [.blockApps, .grantTime],
                    joinedAt: Date(),
                    isApprovedForAdmin: false,
                    appleUserID: currentUserIdentifier,
                    appUserID: currentAppUserID
                ))
            }

            var accepted = invite
            accepted.status = .accepted
            updateDevInvite(accepted)
            pendingInvites.removeAll { $0.id == invite.id }
            refreshCurrentUserContext()
            saveState()
            return true
        }

        do {
            let circleRecordID = CKRecord.ID(recordName: invite.circleRecordName)
            let circleRecord = try await publicDatabase.record(for: circleRecordID)
            var incomingState = FamilyState()
            if let data = circleRecord["stateData"] as? Data,
               let decoded = try? JSONDecoder().decode(FamilyState.self, from: data) {
                incomingState = decoded
            }

            if !incomingState.members.contains(where: memberMatchesCurrentUser) {
                incomingState.members.append(FamilyMember(
                    id: UUID(),
                    name: currentUserDisplayName == "Guest" ? "Friend" : currentUserDisplayName,
                    role: .member,
                    permissions: [.blockApps, .grantTime],
                    joinedAt: Date(),
                    isApprovedForAdmin: false,
                    appleUserID: currentUserIdentifier,
                    appUserID: currentAppUserID
                ))
            }

            familyState = incomingState
            isBlocking = incomingState.isBlocking
            mergeLocalSelection(from: incomingState)
            currentCircleRecordID = circleRecordID
            currentUserRole = .member
            currentUserApprovedForAdmin = false
            saveState()

            circleRecord["stateData"] = try? encodedCloudStateData() as NSData
            circleRecord["updatedAt"] = Date() as NSDate
            _ = try await publicDatabase.save(circleRecord)

            let inviteRecordID = CKRecord.ID(recordName: "invite_\(invite.id.uuidString)")
            let inviteRecord = try await publicDatabase.record(for: inviteRecordID)
            var accepted = invite
            accepted.status = .accepted
            write(accepted, to: inviteRecord)
            _ = try await publicDatabase.save(inviteRecord)

            pendingInvites.removeAll { $0.id == invite.id }
            await saveUserProfileToCloud()
            return true
        } catch {
            setCloudError()
            return false
        }
    }

    func requestExtraTime(minutes: Int, from member: FamilyMember) {
        let request = FamilyTimeRequest(
            id: UUID(),
            requestedBy: member,
            requestedMinutes: minutes,
            detail: "Please grant extra focus time for the shared circle.",
            createdAt: Date()
        )

        familyState.timeRequests.append(request)
        saveState()
        Task { await syncStateToCloud() }
    }

    func respondToTimeRequest(_ request: FamilyTimeRequest, approved: Bool, minutes: Int) {
        guard canManageBlocking else {
            authError = "Only approved managers can answer time requests."
            return
        }

        if approved {
            familyState.extraTimeMinutes += minutes
        }

        familyState.timeRequests.removeAll { $0.id == request.id }
        saveState()
        Task { await syncStateToCloud() }
    }

    func grantExtraTime(minutes: Int) {
        guard canManageBlocking else {
            authError = "Only approved managers can grant extra time."
            return
        }

        familyState.extraTimeMinutes += minutes
        if let blockExpiresAt = familyState.blockExpiresAt, blockExpiresAt > Date() {
            familyState.blockExpiresAt = blockExpiresAt.addingTimeInterval(TimeInterval(minutes * 60))
        }
        saveState()
        Task { await syncStateToCloud() }
    }

    func selectionDidChange() {
        guard canManageBlocking else {
            authError = "Only approved managers can change blocked apps."
            return
        }

        saveState()
        applyShieldingIfNeeded()
        Task { await syncStateToCloud() }
    }

    func addAppLimit(appName: String, bundleIdentifier: String, minutes: Int) {
        guard canManageBlocking else {
            authError = "Only approved managers can add app limits."
            return
        }

        let limit = AppLimit(id: UUID(), appName: appName, bundleIdentifier: bundleIdentifier, timeLimitMinutes: minutes, isEnabled: true, createdAt: Date())
        familyState.appLimits.append(limit)
        saveState()
        Task { await syncStateToCloud() }
    }

    func addBlockRule(appName: String, bundleIdentifier: String, targetUserID: String? = nil) {
        guard canManageBlocking else {
            authError = "Only approved managers can add block rules."
            return
        }

        let rule = BlockRule(id: UUID(), appName: appName, bundleIdentifier: bundleIdentifier, isBlocked: true, targetUserID: targetUserID, createdAt: Date())
        familyState.blockRules.append(rule)
        saveState()
        Task { await syncStateToCloud() }
    }

    func removeMember(_ member: FamilyMember) {
        guard currentUserRole == .owner else {
            authError = "Only the circle owner can remove members."
            return
        }

        familyState.members.removeAll { $0.id == member.id }
        saveState()
        Task { await syncStateToCloud() }
    }

    private func refreshCurrentUserContext() {
        guard currentUserIdentifier != nil else {
            currentUserRole = .owner
            currentUserApprovedForAdmin = true
            return
        }

        if let member = familyState.members.first(where: memberMatchesCurrentUser) {
            currentUserRole = member.role
            currentUserApprovedForAdmin = member.isApprovedForAdmin || member.role == .owner
            if currentAppUserID.isEmpty, let appUserID = member.appUserID {
                currentAppUserID = appUserID
            }
        } else if familyState.members.contains(where: { $0.role == .owner }) {
            currentUserRole = .member
            currentUserApprovedForAdmin = false
        } else {
            currentUserRole = .owner
            currentUserApprovedForAdmin = true
        }
    }

    private func memberMatchesCurrentUser(_ member: FamilyMember) -> Bool {
        if let currentUserIdentifier, member.appleUserID == currentUserIdentifier {
            return true
        }
        return !currentAppUserID.isEmpty && member.appUserID == currentAppUserID
    }

    private func cloudSafeFamilyState() -> FamilyState {
        var safeState = familyState
        safeState.members = safeState.members.map { member in
            var safeMember = member
            safeMember.appleUserID = nil
            return safeMember
        }
        safeState.timeRequests = safeState.timeRequests.map { request in
            var safeRequest = request
            safeRequest.requestedBy.appleUserID = nil
            return safeRequest
        }
        safeState.sharedSelection = FamilyActivitySelection()
        return safeState
    }

    private func encodedCloudStateData() throws -> Data {
        try JSONEncoder().encode(cloudSafeFamilyState())
    }

    private func mergeLocalSelection(from incomingState: FamilyState) {
        guard isDeveloperSession else { return }
        if !incomingState.sharedSelection.applicationTokens.isEmpty || !incomingState.sharedSelection.webDomainTokens.isEmpty {
            selectedApps = incomingState.sharedSelection
        }
    }

    private func setCloudError() {
        authError = "Cloud sync failed. Please check iCloud and try again."
    }

    private func joinLocalFamily(with code: String, memberName: String, userIdentifier: String) -> Bool {
        guard let invite = familyState.activeInvite,
              invite.code.uppercased() == code,
              invite.expiresAt > Date() else {
            return false
        }

        if !familyState.members.contains(where: { $0.appleUserID == userIdentifier }) {
            familyState.members.append(FamilyMember(
                id: UUID(),
                name: memberName.isEmpty ? currentUserDisplayName : memberName,
                role: .member,
                permissions: invite.permissions,
                joinedAt: Date(),
                isApprovedForAdmin: false,
                appleUserID: userIdentifier,
                appUserID: currentAppUserID
            ))
        }

        currentUserRole = .member
        currentUserApprovedForAdmin = false
        familyState.enrollmentStatus = .readyForReview
        saveState()
        return true
    }

    private func loadAllDevInvites() -> [FriendInviteRequest] {
        guard let data = UserDefaults.standard.data(forKey: pendingInvitesKey),
              let decoded = try? JSONDecoder().decode([FriendInviteRequest].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveAllDevInvites(_ invites: [FriendInviteRequest]) {
        if let encoded = try? JSONEncoder().encode(invites) {
            UserDefaults.standard.set(encoded, forKey: pendingInvitesKey)
        }
    }

    private func saveDevInvite(_ invite: FriendInviteRequest) {
        var invites = loadAllDevInvites()
        invites.removeAll { $0.id == invite.id }
        invites.append(invite)
        saveAllDevInvites(invites)
    }

    private func updateDevInvite(_ invite: FriendInviteRequest) {
        var invites = loadAllDevInvites()
        if let index = invites.firstIndex(where: { $0.id == invite.id }) {
            invites[index] = invite
        } else {
            invites.append(invite)
        }
        saveAllDevInvites(invites)
    }

    private func loadPendingDevInvites() {
        guard let currentUserIdentifier else {
            pendingInvites = []
            return
        }

        pendingInvites = loadAllDevInvites().filter {
            ($0.toUserID == currentUserIdentifier || $0.toUserID == currentAppUserID) && $0.status == .pending
        }
    }

    private func existingOrGeneratedAppUserID() -> String {
        let stored = UserDefaults.standard.string(forKey: currentAppUserIDKey)
        if let stored, !stored.isEmpty {
            let normalized = normalizeAppUserID(stored)
            if normalized.hasPrefix("DEV-") || normalized.replacingOccurrences(of: "FB-", with: "").count >= 8 {
                return normalized
            }
        }

        return generateRandomAppUserID()
    }

    private func generateRandomAppUserID() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let suffix = (0..<8).map { _ in
            String(alphabet[Int.random(in: 0..<alphabet.count)])
        }.joined()
        return "FB-\(suffix)"
    }

    private func normalizeAppUserID(_ userID: String) -> String {
        userID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func publicUserRecordName(for appUserID: String) -> String {
        "public_user_\(normalizeAppUserID(appUserID).replacingOccurrences(of: "-", with: "_"))"
    }

    private func resolveDevUserIdentifier(for appUserID: String) -> String? {
        switch normalizeAppUserID(appUserID) {
        case "DEV-OWNER":
            return "dev-owner"
        case "DEV-FRIEND":
            return "dev-friend"
        default:
            return nil
        }
    }

    private func resolveCloudUserIdentifier(for appUserID: String) async throws -> String? {
        let normalizedID = normalizeAppUserID(appUserID)
        let recordID = CKRecord.ID(recordName: publicUserRecordName(for: normalizedID))
        let record = try await publicDatabase.record(for: recordID)
        return record["appUserID"] as? String
    }

    private func saveUserProfileToCloud() async {
        guard let currentUserIdentifier, !isDeveloperSession else { return }
        if currentAppUserID.isEmpty {
            currentAppUserID = existingOrGeneratedAppUserID()
        }
        isSyncing = true
        defer { isSyncing = false }

        let recordID = CKRecord.ID(recordName: "user_\(currentUserIdentifier)")
        let record: CKRecord
        if let existing = try? await privateDatabase.record(for: recordID) {
            record = existing
        } else {
            record = CKRecord(recordType: userRecordType, recordID: recordID)
        }
        record["appleUserID"] = currentUserIdentifier as NSString
        record["appUserID"] = currentAppUserID as NSString
        record["displayName"] = currentUserDisplayName as NSString
        record["circleID"] = currentCircleRecordID?.recordName as NSString?
        record["isApprovedForAdmin"] = currentUserApprovedForAdmin as NSNumber

        do {
            _ = try await privateDatabase.save(record)
            let legacyPublicRecordID = CKRecord.ID(recordName: "public_user_\(currentUserIdentifier)")
            _ = try? await publicDatabase.deleteRecord(withID: legacyPublicRecordID)

            let publicRecordID = CKRecord.ID(recordName: publicUserRecordName(for: currentAppUserID))
            let publicRecord: CKRecord
            if let existing = try? await publicDatabase.record(for: publicRecordID) {
                publicRecord = existing
            } else {
                publicRecord = CKRecord(recordType: userRecordType, recordID: publicRecordID)
            }
            publicRecord["appUserID"] = currentAppUserID as NSString
            publicRecord["displayName"] = currentUserDisplayName as NSString
            publicRecord["circleID"] = currentCircleRecordID?.recordName as NSString?
            _ = try await publicDatabase.save(publicRecord)
        } catch {
            setCloudError()
        }
    }

    private func ensureCircleRecordExists() async throws -> CKRecord.ID {
        if let currentCircleRecordID {
            return currentCircleRecordID
        }

        if !familyState.members.contains(where: { $0.role == .owner }) {
            familyState.members.append(FamilyMember(
                id: UUID(),
                name: currentUserDisplayName == "Guest" ? "You" : currentUserDisplayName,
                role: .owner,
                permissions: [.blockApps, .grantTime],
                joinedAt: Date(),
                isApprovedForAdmin: true,
                appleUserID: currentUserIdentifier,
                appUserID: currentAppUserID
            ))
        }

        let circleRecordID = CKRecord.ID(recordName: "circle_\(UUID().uuidString)")
        currentCircleRecordID = circleRecordID
        try await saveCircleRecord(recordID: circleRecordID)
        return circleRecordID
    }

    private func syncStateToCloud() async {
        guard isAuthenticated, !isDeveloperSession else { return }
        isSyncing = true
        defer { isSyncing = false }

        let circleRecordID: CKRecord.ID
        if let currentCircleRecordID {
            circleRecordID = currentCircleRecordID
        } else {
            circleRecordID = CKRecord.ID(recordName: "circle_\(UUID().uuidString)")
            currentCircleRecordID = circleRecordID
        }

        do {
            try await saveCircleRecord(recordID: circleRecordID, ownerUserID: currentAppUserID)
            await saveUserProfileToCloud()
        } catch {
            setCloudError()
        }
    }

    private func saveCircleRecord(recordID: CKRecord.ID, ownerUserID: String? = nil) async throws {
        let record: CKRecord
        if let existing = try? await publicDatabase.record(for: recordID) {
            record = existing
        } else {
            record = CKRecord(recordType: circleRecordType, recordID: recordID)
        }

        record["ownerUserID"] = (ownerUserID ?? currentAppUserID) as NSString
        record["inviteCode"] = currentInviteCode as NSString?
        record["stateData"] = try? encodedCloudStateData() as NSData
        record["updatedAt"] = Date() as NSDate
        _ = try await publicDatabase.save(record)
    }

    private func loadStateFromCloud() async {
        guard isAuthenticated, !isDeveloperSession, let currentUserIdentifier else { return }
        isSyncing = true
        defer { isSyncing = false }

        let userRecordID = CKRecord.ID(recordName: "user_\(currentUserIdentifier)")
        do {
            let userRecord = try await privateDatabase.record(for: userRecordID)
            currentUserDisplayName = userRecord["displayName"] as? String ?? currentUserDisplayName
            currentAppUserID = userRecord["appUserID"] as? String ?? currentAppUserID
            if let circleID = userRecord["circleID"] as? String {
                currentCircleRecordID = CKRecord.ID(recordName: circleID)
            }

            if let circleRecordID = currentCircleRecordID {
                let circleRecord = try await publicDatabase.record(for: circleRecordID)
                if let data = circleRecord["stateData"] as? Data,
                   let decoded = try? JSONDecoder().decode(FamilyState.self, from: data) {
                    familyState = decoded
                    isBlocking = decoded.isBlocking
                    mergeLocalSelection(from: decoded)
                }
                if let inviteCode = circleRecord["inviteCode"] as? String {
                    currentInviteCode = inviteCode
                }
            }

            refreshCurrentUserContext()
            applyShieldingIfNeeded()
            saveState()
        } catch {
            setCloudError()
        }
    }

    private func applyShieldingIfNeeded() {
        guard isAuthorized, isBlocking else {
            blockingStore.shield.applications = nil
            blockingStore.shield.webDomains = nil
            return
        }

        blockingStore.shield.applications = selectedApps.applicationTokens.isEmpty ? nil : selectedApps.applicationTokens
        blockingStore.shield.webDomains = selectedApps.webDomainTokens.isEmpty ? nil : selectedApps.webDomainTokens
    }

    private func startBlockingStatusTimer() {
        blockingStatusTimer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkBlockingStatus()
            }
    }

    private func write(_ invite: FriendInviteRequest, to record: CKRecord) {
        record["id"] = invite.id.uuidString as NSString
        record["fromUserID"] = invite.fromUserID as NSString
        record["fromName"] = invite.fromName as NSString
        record["toUserID"] = invite.toUserID as NSString
        record["circleRecordName"] = invite.circleRecordName as NSString
        record["status"] = invite.status.rawValue as NSString
        record["createdAt"] = invite.createdAt as NSDate
    }

    private func readInviteRequest(from record: CKRecord) -> FriendInviteRequest? {
        guard let idString = record["id"] as? String,
              let id = UUID(uuidString: idString),
              let fromUserID = record["fromUserID"] as? String,
              let fromName = record["fromName"] as? String,
              let toUserID = record["toUserID"] as? String,
              let circleRecordName = record["circleRecordName"] as? String,
              let statusString = record["status"] as? String,
              let status = FriendInviteRequest.Status(rawValue: statusString),
              let createdAt = record["createdAt"] as? Date else {
            return nil
        }

        return FriendInviteRequest(
            id: id,
            fromUserID: fromUserID,
            fromName: fromName,
            toUserID: toUserID,
            circleRecordName: circleRecordName,
            status: status,
            createdAt: createdAt
        )
    }

    func saveState() {
        UserDefaults.standard.set(isBlocking, forKey: isBlockingKey)
        familyState.isBlocking = isBlocking
        familyState.sharedSelection = selectedApps

        if let encoded = try? JSONEncoder().encode(selectedApps) {
            UserDefaults.standard.set(encoded, forKey: selectedAppsKey)
        }

        if let encoded = try? JSONEncoder().encode(familyState) {
            UserDefaults.standard.set(encoded, forKey: familyStateKey)
        }

        if let currentUserIdentifier {
            UserDefaults.standard.set(currentUserIdentifier, forKey: currentUserIdentifierKey)
        }

        if !currentAppUserID.isEmpty {
            UserDefaults.standard.set(currentAppUserID, forKey: currentAppUserIDKey)
        }

        if !currentUserDisplayName.isEmpty {
            UserDefaults.standard.set(currentUserDisplayName, forKey: currentUserDisplayNameKey)
        }

        UserDefaults.standard.set(isDeveloperSession, forKey: isDeveloperSessionKey)
    }

    func loadState() {
        isBlocking = UserDefaults.standard.bool(forKey: isBlockingKey)
        currentUserIdentifier = UserDefaults.standard.string(forKey: currentUserIdentifierKey)
        currentAppUserID = UserDefaults.standard.string(forKey: currentAppUserIDKey) ?? ""
        currentUserDisplayName = UserDefaults.standard.string(forKey: currentUserDisplayNameKey) ?? "Guest"
        isDeveloperSession = UserDefaults.standard.bool(forKey: isDeveloperSessionKey)
        isAuthenticated = currentUserIdentifier != nil

        if let data = UserDefaults.standard.data(forKey: selectedAppsKey),
           let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            selectedApps = decoded
        }

        if let data = UserDefaults.standard.data(forKey: familyStateKey),
           let decoded = try? JSONDecoder().decode(FamilyState.self, from: data) {
            familyState = decoded
        }

        refreshCurrentUserContext()
        if currentAppUserID.isEmpty, currentUserIdentifier != nil {
            currentAppUserID = existingOrGeneratedAppUserID()
        }
        isBlocking = familyState.isBlocking || isBlocking
        if !familyState.sharedSelection.applicationTokens.isEmpty || !familyState.sharedSelection.webDomainTokens.isEmpty {
            selectedApps = familyState.sharedSelection
        }
        loadPendingDevInvites()
        checkBlockingStatus()
    }
}
