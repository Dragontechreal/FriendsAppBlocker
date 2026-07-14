import Foundation
import Combine
import FamilyControls
import ManagedSettings
import DeviceActivity
import AuthenticationServices
import CloudKit
@preconcurrency import UserNotifications
import UIKit

struct FriendProfile: Identifiable, Codable, Hashable {
    var id: String { appUserID }
    var appUserID: String
    var displayName: String
}

struct FriendConnection: Identifiable, Codable, Hashable {
    enum Status: String, Codable {
        case pending
        case accepted
        case declined
    }

    var id: String
    var userIDs: [String]
    var displayNames: [String: String]
    var requestedByID: String
    var requestedToID: String
    var status: Status
    var createdAt: Date

    func friend(for currentUserID: String) -> FriendProfile? {
        guard let friendID = userIDs.first(where: { $0 != currentUserID }) else { return nil }
        return FriendProfile(appUserID: friendID, displayName: displayNames[friendID] ?? friendID)
    }
}

enum LimitMode: String, Codable, CaseIterable, Identifiable {
    case shared
    case individual

    var id: String { rawValue }
    var title: String {
        switch self {
        case .shared: return "All apps together"
        case .individual: return "Each app individually"
        }
    }
}

struct AppLimitPolicy: Identifiable, Codable {
    let id: UUID
    var ownerID: String
    var ownerName: String
    var title: String
    var minutes: Int
    var mode: LimitMode
    var approverIDs: [String]
    var selection: FamilyActivitySelection
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case ownerID
        case ownerName
        case title
        case minutes
        case mode
        case approverIDs
        case selection
        case createdAt
        case updatedAt
    }

    static func empty(ownerID: String, ownerName: String) -> AppLimitPolicy {
        AppLimitPolicy(
            id: UUID(),
            ownerID: ownerID,
            ownerName: ownerName,
            title: "New limit",
            minutes: 30,
            mode: .shared,
            approverIDs: [],
            selection: FamilyActivitySelection(),
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

struct LimitTimeStatus: Hashable {
    let baseMinutes: Int
    let approvedExtraMinutes: Int
    let usedMinutes: Int

    var totalAvailableMinutes: Int {
        baseMinutes + approvedExtraMinutes
    }

    var remainingMinutes: Int {
        max(0, totalAvailableMinutes - usedMinutes)
    }

    var progress: Double {
        guard totalAvailableMinutes > 0 else { return 0 }
        return min(1, max(0, Double(remainingMinutes) / Double(totalAvailableMinutes)))
    }
}

enum TimeRequestStatus: String, Codable, CaseIterable {
    case open
    case approved
    case declined
}

struct AppTimeRequest: Identifiable, Codable, Hashable {
    var id: UUID
    var responseToRequestID: UUID?
    var requesterID: String
    var requesterName: String
    var limitID: UUID
    var limitTitle: String
    var approverIDs: [String]
    var requestedMinutes: Int
    var status: TimeRequestStatus
    var resolvedByID: String?
    var resolvedByName: String?
    var createdAt: Date
    var updatedAt: Date

    var notificationIdentifier: String {
        "time_request_\((responseToRequestID ?? id).uuidString)"
    }
}

@MainActor
final class BlockingManager: ObservableObject {
    static let shared = BlockingManager()

    @Published var isAuthorized = false
    @Published var selectedApps = FamilyActivitySelection()
    @Published var currentUserIdentifier: String?
    @Published var currentAppUserID = ""
    @Published var currentUserDisplayName = "Guest"
    @Published var friends: [FriendProfile] = []
    @Published var incomingFriendRequests: [FriendConnection] = []
    @Published var outgoingFriendRequests: [FriendConnection] = []
    @Published var limits: [AppLimitPolicy] = []
    @Published var incomingRequests: [AppTimeRequest] = []
    @Published var ownRequests: [AppTimeRequest] = []
    @Published var isAuthenticated = false
    @Published var isDeveloperSession = false
    @Published var isSyncing = false
    @Published var authError: String?
    @Published var infoMessage: String?
    @Published var needsDisplayName = false
    @Published var devDiagnostics = "No diagnostics yet."

    private let appContainerIdentifier = "iCloud.dev.supremezone.friendsappblock"
    private let profileRecordType = "UserProfile"
    private let friendshipRecordType = "Friendship"
    private let limitRecordType = "LimitPolicy"
    private let timeRequestRecordType = "TimeRequest"
    private let cloudKitSubscriptionVersion = "v4"
    private let currentUserIdentifierKey = "currentUserIdentifier"
    private let currentAppUserIDKey = "currentAppUserID"
    private let currentUserDisplayNameKey = "currentUserDisplayName"
    private let isDeveloperSessionKey = "isDeveloperSession"
    private let localFriendsKey = "localFriends"
    private let localIncomingFriendRequestsKey = "localIncomingFriendRequests"
    private let localOutgoingFriendRequestsKey = "localOutgoingFriendRequests"
    private let localLimitsKey = "localLimits"
    private let localIncomingRequestsKey = "localIncomingRequests"
    private let localOwnRequestsKey = "localOwnRequests"
    private let screenTimeMonitorStateKey = "screenTimeMonitorState"
    private let schemaSampleLimitID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")
    private let schemaSampleRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")
    private let blockingStore = ManagedSettingsStore()
    private let deviceActivityCenter = DeviceActivityCenter()
    private var refreshTimer: AnyCancellable?
    private var isRefreshing = false
    private var needsRefreshAfterCurrent = false
    private var pendingFriendStateByPair: [String: FriendConnection] = [:]
    private var pendingLimitUpserts: [UUID: AppLimitPolicy] = [:]
    private var pendingLimitDeletes: Set<UUID> = []
    private var pendingTimeRequests: [UUID: AppTimeRequest] = [:]
    private var pendingTimeResponses: [UUID: AppTimeRequest] = [:]
    private var screenTimeMonitorState: [String: String] = [:]

    private var privateDatabase: CKDatabase {
        CKContainer(identifier: appContainerIdentifier).privateCloudDatabase
    }

    private var publicDatabase: CKDatabase {
        CKContainer(identifier: appContainerIdentifier).publicCloudDatabase
    }

    private init() {
        updateAuthorizationStatus()
        loadLocalState()
        cleanupRemovedFeatureNotifications()
        syncScreenTimeTrackingAfterLaunch()
        startAutoRefresh()
    }

    var supportsFamilyControls: Bool { true }

    var openIncomingRequests: [AppTimeRequest] {
        incomingRequests.filter { $0.status == .open }
    }

    var openOwnRequests: [AppTimeRequest] {
        ownRequests.filter { $0.status == .open && $0.responseToRequestID == nil }
    }

    func timeStatus(for limit: AppLimitPolicy) -> LimitTimeStatus {
        let approvedExtraMinutes = ownRequests
            .filter { request in
                request.limitID == limit.id &&
                request.status == .approved &&
                Calendar.current.isDateInToday(request.updatedAt)
            }
            .reduce(0) { $0 + $1.requestedMinutes }

        return LimitTimeStatus(
            baseMinutes: limit.minutes,
            approvedExtraMinutes: approvedExtraMinutes,
            usedMinutes: usageMinutesToday(for: limit.id)
        )
    }

    func requestAuthorization() async throws {
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        updateAuthorizationStatus()
    }

    func handleAuthorizationResult(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                authError = "Apple sign-in did not return a valid credential."
                return
            }

            let name = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            let storedName = UserDefaults.standard.string(forKey: currentUserDisplayNameKey) ?? ""
            let displayName = storedName.isEmpty ? name : storedName
            signIn(userIdentifier: credential.user, appUserID: existingOrGeneratedAppUserID(), displayName: displayName, developer: false)
            needsDisplayName = isPlaceholderName(displayName)
            await afterSignIn()
        case .failure(let error):
            authError = error.localizedDescription
            isAuthenticated = false
        }
    }

    func signInForDevelopment(asOwner: Bool) {
        signIn(
            userIdentifier: asOwner ? "dev-owner" : "dev-friend",
            appUserID: asOwner ? "DEV-OWNER" : "DEV-FRIEND",
            displayName: asOwner ? "Dev Owner" : "Dev Friend",
            developer: true
        )
        if asOwner {
            friends = [FriendProfile(appUserID: "DEV-FRIEND", displayName: "Dev Friend")]
        } else {
            friends = [FriendProfile(appUserID: "DEV-OWNER", displayName: "Dev Owner")]
        }
        loadLocalCollections()
        saveLocalState()
        syncAppBadge()
    }

    func signOut() {
        currentUserIdentifier = nil
        currentAppUserID = ""
        currentUserDisplayName = "Guest"
        friends = []
        incomingFriendRequests = []
        outgoingFriendRequests = []
        limits = []
        incomingRequests = []
        ownRequests = []
        isAuthenticated = false
        isDeveloperSession = false
        authError = nil
        infoMessage = nil
        cleanupRemovedFeatureNotifications()
        syncAppBadge(count: 0)
        selectedApps = FamilyActivitySelection()
        blockingStore.shield.applications = nil
        blockingStore.shield.applicationCategories = nil
        blockingStore.shield.webDomains = nil
        blockingStore.shield.webDomainCategories = nil
        clearScreenTimeTracking()
        [
            currentUserIdentifierKey,
            currentAppUserIDKey,
            currentUserDisplayNameKey,
            isDeveloperSessionKey,
            localFriendsKey,
            localIncomingFriendRequestsKey,
            localOutgoingFriendRequestsKey,
            localLimitsKey,
            localIncomingRequestsKey,
            localOwnRequestsKey,
            screenTimeMonitorStateKey
        ].forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    func deleteAccount() async {
        guard isAuthenticated else { return }

        if isDeveloperSession {
            signOut()
            return
        }

        let userIdentifier = currentUserIdentifier
        let appUserID = currentAppUserID
        let displayName = currentUserDisplayName
        guard !appUserID.isEmpty else {
            signOut()
            return
        }

        isSyncing = true
        var deletionErrors: [String] = []

        do {
            try await writeFriendRemovalRecordsForAccountDeletion(appUserID: appUserID, displayName: displayName)
        } catch {
            deletionErrors.append("friendships: \(shortCloudDiagnostic(error))")
        }

        do {
            try await deletePublicRecords(recordType: limitRecordType, predicate: NSPredicate(format: "ownerID == %@", appUserID))
        } catch {
            deletionErrors.append("limits: \(shortCloudDiagnostic(error))")
        }

        do {
            try await deletePublicRecords(recordType: timeRequestRecordType, predicate: NSPredicate(format: "requesterID == %@", appUserID))
        } catch {
            deletionErrors.append("time requests: \(shortCloudDiagnostic(error))")
        }

        do {
            try await deletePublicRecords(recordType: timeRequestRecordType, predicate: NSPredicate(format: "resolvedByID == %@", appUserID))
        } catch {
            deletionErrors.append("time request responses: \(shortCloudDiagnostic(error))")
        }

        do {
            try await deleteRecordIfExists(CKRecord.ID(recordName: publicUserRecordName(for: appUserID)), in: publicDatabase)
        } catch {
            deletionErrors.append("public profile: \(shortCloudDiagnostic(error))")
        }

        if let userIdentifier {
            do {
                try await deleteRecordIfExists(CKRecord.ID(recordName: "user_\(userIdentifier)"), in: privateDatabase)
            } catch {
                deletionErrors.append("private profile: \(shortCloudDiagnostic(error))")
            }
        }

        isSyncing = false

        if deletionErrors.isEmpty {
            infoMessage = "Account deleted."
            signOut()
        } else {
            authError = "Account deletion incomplete: \(deletionErrors.joined(separator: "; "))"
        }
    }

    func refreshAll() async {
        guard isAuthenticated else { return }
        if isDeveloperSession {
            loadLocalCollections()
            return
        }
        guard !isRefreshing else {
            needsRefreshAfterCurrent = true
            return
        }
        isRefreshing = true
        isSyncing = true
        defer {
            isRefreshing = false
            isSyncing = false
            runQueuedRefreshIfNeeded()
        }
        await saveUserProfileToCloud()
        await configureNotifications()
        await loadFreshRemoteState()
    }

    func refreshRemoteChanges() async {
        guard isAuthenticated, !isDeveloperSession else {
            loadLocalCollections()
            return
        }
        guard !isRefreshing else {
            needsRefreshAfterCurrent = true
            return
        }
        isRefreshing = true
        isSyncing = true
        defer {
            isRefreshing = false
            isSyncing = false
            runQueuedRefreshIfNeeded()
        }
        await loadFreshRemoteState()
    }

    private func runQueuedRefreshIfNeeded() {
        guard needsRefreshAfterCurrent else { return }
        needsRefreshAfterCurrent = false
        Task { await refreshRemoteChanges() }
    }

    func addFriend(with code: String) async {
        let friendID = normalizeAppUserID(code)
        guard !friendID.isEmpty, friendID != currentAppUserID else { return }

        if isDeveloperSession {
            let profile = FriendProfile(appUserID: friendID, displayName: friendID == "DEV-OWNER" ? "Dev Owner" : "Dev Friend")
            if !friends.contains(profile) {
                friends.append(profile)
                saveLocalState()
            }
            return
        }

        var previousOutgoing: [FriendConnection]?
        do {
            guard let profile = try await fetchPublicProfile(appUserID: friendID) else {
                authError = "No user found for \(friendID)."
                return
            }
            previousOutgoing = outgoingFriendRequests
            let connection = FriendConnection(
                id: friendPendingRequestID(to: profile.appUserID),
                userIDs: [currentAppUserID, profile.appUserID].sorted(),
                displayNames: [
                    currentAppUserID: currentUserDisplayName,
                    profile.appUserID: profile.displayName
                ],
                requestedByID: currentAppUserID,
                requestedToID: profile.appUserID,
                status: .pending,
                createdAt: Date()
            )
            let record = CKRecord(recordType: friendshipRecordType, recordID: CKRecord.ID(recordName: connection.id))
            write(connection, to: record)
            pendingFriendStateByPair[friendshipPairKey(connection.userIDs)] = connection
            outgoingFriendRequests.removeAll { friendshipPairKey($0.userIDs) == friendshipPairKey(connection.userIDs) }
            outgoingFriendRequests.insert(connection, at: 0)
            saveLocalState()
            _ = try await publicDatabase.save(record)
            await loadFriendState()
            infoMessage = "Friend request sent to \(profile.displayName)."
        } catch {
            pendingFriendStateByPair.removeValue(forKey: friendshipPairKey([currentAppUserID, friendID]))
            if let previousOutgoing {
                outgoingFriendRequests = previousOutgoing
            }
            saveLocalState()
            setCloudError(error, context: "add friend")
        }
    }

    func acceptFriendRequest(_ request: FriendConnection) async {
        await resolveFriendRequest(request, accepted: true)
    }

    func declineFriendRequest(_ request: FriendConnection) async {
        await resolveFriendRequest(request, accepted: false)
    }

    private func resolveFriendRequest(_ request: FriendConnection, accepted: Bool) async {
        var updated = request
        updated.status = accepted ? .accepted : .declined

        if isDeveloperSession {
            if accepted, let friend = updated.friend(for: currentAppUserID), !friends.contains(friend) {
                friends.append(friend)
            }
            incomingFriendRequests.removeAll { $0.id == request.id }
            outgoingFriendRequests.removeAll { $0.id == request.id }
            saveLocalState()
            return
        }

        let previousFriends = friends
        let previousIncoming = incomingFriendRequests
        let previousOutgoing = outgoingFriendRequests
        let pairKey = friendshipPairKey(request.userIDs)
        incomingFriendRequests.removeAll { $0.id == request.id || friendshipPairKey($0.userIDs) == friendshipPairKey(request.userIDs) }
        outgoingFriendRequests.removeAll { $0.id == request.id || friendshipPairKey($0.userIDs) == friendshipPairKey(request.userIDs) }
        if accepted, let friend = updated.friend(for: currentAppUserID), !friends.contains(friend) {
            friends.insert(friend, at: 0)
        }
        saveLocalState()

        do {
            updated.id = friendResponseID(for: request, accepted: accepted)
            updated.createdAt = Date()
            pendingFriendStateByPair[pairKey] = updated
            let record = CKRecord(recordType: friendshipRecordType, recordID: CKRecord.ID(recordName: updated.id))
            write(updated, to: record)
            _ = try await publicDatabase.save(record)
            await loadFriendState()
        } catch {
            pendingFriendStateByPair.removeValue(forKey: pairKey)
            friends = previousFriends
            incomingFriendRequests = previousIncoming
            outgoingFriendRequests = previousOutgoing
            saveLocalState()
            setCloudError(error, context: accepted ? "accept friend request" : "decline friend request")
        }
    }

    func unfriend(_ friend: FriendProfile) async {
        if isDeveloperSession {
            friends.removeAll { $0.appUserID == friend.appUserID }
            saveLocalState()
            return
        }

        let previousFriends = friends
        let pairKey = friendshipPairKey([currentAppUserID, friend.appUserID])
        friends.removeAll { $0.appUserID == friend.appUserID }
        saveLocalState()

        do {
            let connection = FriendConnection(
                id: friendRemovalID(friend.appUserID),
                userIDs: [currentAppUserID, friend.appUserID].sorted(),
                displayNames: [
                    currentAppUserID: currentUserDisplayName,
                    friend.appUserID: friend.displayName
                ],
                requestedByID: currentAppUserID,
                requestedToID: friend.appUserID,
                status: .declined,
                createdAt: Date()
            )
            pendingFriendStateByPair[pairKey] = connection
            let record = CKRecord(recordType: friendshipRecordType, recordID: CKRecord.ID(recordName: connection.id))
            write(connection, to: record)
            _ = try await publicDatabase.save(record)
            await loadFriendState()
        } catch {
            pendingFriendStateByPair.removeValue(forKey: pairKey)
            friends = previousFriends
            saveLocalState()
            setCloudError(error, context: "remove friend")
        }
    }

    func saveLimit(_ limit: AppLimitPolicy) async {
        var updated = limit
        updated.ownerID = currentAppUserID
        updated.ownerName = currentUserDisplayName
        updated.updatedAt = Date()

        if isDeveloperSession {
            limits.removeAll { $0.id == updated.id }
            limits.append(updated)
            saveLocalState()
            syncScreenTimeTracking()
            return
        }

        let previousLimits = limits
        pendingLimitDeletes.remove(updated.id)
        pendingLimitUpserts[updated.id] = updated
        limits.removeAll { $0.id == updated.id }
        limits.insert(updated, at: 0)
        saveLocalState()

        do {
            let record = await existingOrNewPublicRecord(
                recordType: limitRecordType,
                recordName: limitRecordName(updated.id)
            )
            write(updated, to: record)
            _ = try await publicDatabase.save(record)
            await loadLimits()
            await loadOwnTimeRequests()
            syncScreenTimeTracking()
            await notifyLimitApprovers(updated)
        } catch {
            pendingLimitUpserts.removeValue(forKey: updated.id)
            limits = previousLimits
            saveLocalState()
            setCloudError(error, context: "save limit")
        }
    }

    func deleteLimit(_ limit: AppLimitPolicy) async {
        if isDeveloperSession {
            limits.removeAll { $0.id == limit.id }
            saveLocalState()
            syncScreenTimeTracking()
            return
        }

        let previousLimits = limits
        pendingLimitUpserts.removeValue(forKey: limit.id)
        pendingLimitDeletes.insert(limit.id)
        limits.removeAll { $0.id == limit.id }
        saveLocalState()

        do {
            _ = try await publicDatabase.deleteRecord(withID: CKRecord.ID(recordName: limitRecordName(limit.id)))
            await loadLimits()
            await loadOwnTimeRequests()
            syncScreenTimeTracking()
        } catch {
            pendingLimitDeletes.remove(limit.id)
            limits = previousLimits
            saveLocalState()
            setCloudError(error, context: "delete limit")
        }
    }

    func requestMoreTime(limit: AppLimitPolicy, minutes: Int) async {
        guard !hasOpenOwnRequest(for: limit.id) else {
            authError = "You already have an open request for this limit."
            return
        }
        guard !limit.approverIDs.isEmpty else {
            authError = "Add at least one friend who can approve this limit."
            return
        }

        let request = AppTimeRequest(
            id: UUID(),
            responseToRequestID: nil,
            requesterID: currentAppUserID,
            requesterName: currentUserDisplayName,
            limitID: limit.id,
            limitTitle: limit.title,
            approverIDs: limit.approverIDs,
            requestedMinutes: minutes,
            status: .open,
            resolvedByID: nil,
            resolvedByName: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        if isDeveloperSession {
            ownRequests.append(request)
            incomingRequests.append(request)
            saveLocalState()
            syncScreenTimeTracking()
            return
        }

        let previousOwnRequests = ownRequests
        let previousIncomingRequests = incomingRequests
        pendingTimeRequests[request.id] = request
        ownRequests.insert(request, at: 0)
        if request.approverIDs.contains(currentAppUserID) {
            incomingRequests.insert(request, at: 0)
        }
        saveLocalState()

        do {
            let record = CKRecord(recordType: timeRequestRecordType, recordID: CKRecord.ID(recordName: timeRequestRecordName(request.id)))
            write(request, to: record)
            _ = try await publicDatabase.save(record)
            await loadOwnTimeRequests()
            await loadIncomingTimeRequests()
            syncScreenTimeTracking()
        } catch {
            pendingTimeRequests.removeValue(forKey: request.id)
            ownRequests = previousOwnRequests
            incomingRequests = previousIncomingRequests
            saveLocalState()
            setCloudError(error, context: "request more time")
        }
    }

    func resolveRequest(_ request: AppTimeRequest, approved: Bool) async {
        guard request.status == .open else { return }
        let originalRequestID = request.responseToRequestID ?? request.id
        var response = request
        response.id = UUID()
        response.responseToRequestID = originalRequestID
        response.status = approved ? .approved : .declined
        response.resolvedByID = currentAppUserID
        response.resolvedByName = currentUserDisplayName
        response.createdAt = Date()
        response.updatedAt = Date()

        if isDeveloperSession {
            updateLocalResolvedRequest(originalRequestID: originalRequestID, response: response)
            saveLocalState()
            syncScreenTimeTracking()
            return
        }

        pendingTimeResponses[originalRequestID] = response
        updateLocalResolvedRequest(originalRequestID: originalRequestID, response: response)

        do {
            let recordName = timeRequestResponseRecordName(originalRequestID: originalRequestID, responderID: currentAppUserID)
            let record = CKRecord(recordType: timeRequestRecordType, recordID: CKRecord.ID(recordName: recordName))
            write(response, to: record)
            _ = try await publicDatabase.save(record)
            removeNotification(for: request)
            await refreshRemoteChanges()
            syncScreenTimeTracking()
        } catch {
            pendingTimeResponses.removeValue(forKey: originalRequestID)
            incomingRequests.removeAll { $0.id == response.id || $0.responseToRequestID == originalRequestID }
            ownRequests.removeAll { $0.id == response.id || $0.responseToRequestID == originalRequestID }
            updateLocalRequest(request)
            saveLocalState()
            setCloudError(error, context: "resolve request")
        }
    }

    func registerCloudSchemaForDevelopment() async {
        guard isAuthenticated, !isDeveloperSession else {
            infoMessage = "Use Apple sign-in in a Debug build to seed the Development CloudKit schema."
            return
        }

        authError = nil
        infoMessage = "Seeding Development CloudKit schema..."

        let sampleFriendID = "SCHEMA-FRIEND"
        let now = Date()
        let sampleLimitID = schemaSampleLimitID ?? UUID()
        let sampleRequestID = schemaSampleRequestID ?? UUID()

        let sampleFriendship = FriendConnection(
            id: "schema_friendship_sample",
            userIDs: [currentAppUserID, sampleFriendID],
            displayNames: [currentAppUserID: currentUserDisplayName, sampleFriendID: "Schema Friend"],
            requestedByID: currentAppUserID,
            requestedToID: sampleFriendID,
            status: .declined,
            createdAt: now
        )
        let sampleLimit = AppLimitPolicy(
            id: sampleLimitID,
            ownerID: currentAppUserID,
            ownerName: currentUserDisplayName,
            title: "Schema sample limit",
            minutes: 30,
            mode: .shared,
            approverIDs: [sampleFriendID],
            selection: FamilyActivitySelection(),
            createdAt: now,
            updatedAt: now
        )
        let sampleRequest = AppTimeRequest(
            id: sampleRequestID,
            responseToRequestID: nil,
            requesterID: currentAppUserID,
            requesterName: currentUserDisplayName,
            limitID: sampleLimit.id,
            limitTitle: sampleLimit.title,
            approverIDs: [sampleFriendID],
            requestedMinutes: 5,
            status: .declined,
            resolvedByID: sampleFriendID,
            resolvedByName: "Schema Friend",
            createdAt: now,
            updatedAt: now
        )

        let friendship = await existingOrNewPublicRecord(recordType: friendshipRecordType, recordName: sampleFriendship.id)
        write(sampleFriendship, to: friendship)
        let limit = await existingOrNewPublicRecord(recordType: limitRecordType, recordName: "schema_limit_sample")
        write(sampleLimit, to: limit)
        let request = await existingOrNewPublicRecord(recordType: timeRequestRecordType, recordName: "schema_request_sample")
        write(sampleRequest, to: request)
        let profile = await existingOrNewPublicRecord(recordType: profileRecordType, recordName: publicUserRecordName(for: sampleFriendID))
        profile["appUserID"] = sampleFriendID as NSString
        profile["displayName"] = "Schema Friend" as NSString

        let records: [(String, CKRecord)] = [
            ("UserProfile", profile),
            ("Friendship", friendship),
            ("LimitPolicy", limit),
            ("TimeRequest", request)
        ]
        var report: [String] = ["CloudKit schema seed result:"]

        for (name, record) in records {
            do {
                _ = try await publicDatabase.save(record)
                report.append("OK: \(name)")
            } catch {
                report.append("ERROR: \(name) - \(shortCloudDiagnostic(error))")
            }
        }

        report.append("Next: if all rows are OK, deploy Development schema to Production in CloudKit Dashboard.")
        infoMessage = report.joined(separator: "\n")
    }

    private func existingOrNewPublicRecord(recordType: String, recordName: String) async -> CKRecord {
        let recordID = CKRecord.ID(recordName: recordName)
        if let existing = try? await publicDatabase.record(for: recordID) {
            return existing
        }
        return CKRecord(recordType: recordType, recordID: recordID)
    }

    private func updateAuthorizationStatus() {
        isAuthorized = AuthorizationCenter.shared.authorizationStatus == .approved
    }

    private func signIn(userIdentifier: String, appUserID: String, displayName: String, developer: Bool) {
        currentUserIdentifier = userIdentifier
        currentAppUserID = appUserID
        currentUserDisplayName = displayName
        isAuthenticated = true
        isDeveloperSession = developer
        authError = nil
        UserDefaults.standard.set(userIdentifier, forKey: currentUserIdentifierKey)
        UserDefaults.standard.set(appUserID, forKey: currentAppUserIDKey)
        UserDefaults.standard.set(displayName, forKey: currentUserDisplayNameKey)
        UserDefaults.standard.set(developer, forKey: isDeveloperSessionKey)
    }

    func saveDisplayName(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            authError = "Please enter a name."
            return
        }
        currentUserDisplayName = trimmed
        needsDisplayName = false
        UserDefaults.standard.set(trimmed, forKey: currentUserDisplayNameKey)
        await saveUserProfileToCloud()
        await refreshAll()
    }

    private func afterSignIn() async {
        await saveUserProfileToCloud()
        await refreshAll()
    }

    func configureNotificationsForDiagnostics() async {
        await configureNotifications()
        await loadNotificationDiagnostics()
    }

    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async {
        let notification = CKNotification(fromRemoteNotificationDictionary: userInfo)
        let type = notification?.subscriptionID ?? "unknown subscription"
        devDiagnostics = "Remote notification received: \(type)\nRefreshing data..."
        await refreshRemoteChanges()
    }

    func updateRemoteNotificationRegistration(success: Bool, detail: String) {
        let status = success ? "Remote notification registration OK" : "Remote notification registration failed"
        devDiagnostics = "\(status)\n\(detail)"
        if !success {
            authError = devDiagnostics
        }
    }

    func scheduleLocalNotificationTest() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            guard granted else {
                devDiagnostics = "Local notification test failed: notification permission was denied."
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Bound"
            content.body = "Local notification test works."
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "Bound_local_notification_test",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
            )
            try await UNUserNotificationCenter.current().add(request)
            devDiagnostics = "Local notification scheduled. It should appear in about 2 seconds."
        } catch {
            devDiagnostics = "Local notification test failed: \(error.localizedDescription)"
            authError = devDiagnostics
        }
    }

    func createDevelopmentTimeRequestPushTest() async {
        guard isAuthenticated, !isDeveloperSession else {
            devDiagnostics = "Use Apple sign-in, not Development login, for CloudKit push tests."
            return
        }
        let request = AppTimeRequest(
            id: UUID(),
            responseToRequestID: nil,
            requesterID: currentAppUserID,
            requesterName: "\(currentUserDisplayName) Push Test",
            limitID: UUID(),
            limitTitle: "Push test time request",
            approverIDs: [currentAppUserID],
            requestedMinutes: 5,
            status: .open,
            resolvedByID: nil,
            resolvedByName: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        do {
            await configureNotifications()
            let record = CKRecord(recordType: timeRequestRecordType, recordID: CKRecord.ID(recordName: timeRequestRecordName(request.id)))
            write(request, to: record)
            _ = try await publicDatabase.save(record)
            await loadIncomingTimeRequests()
            let matches = await timeRequestSubscriptionMatches(recordName: record.recordID.recordName)
            devDiagnostics = [
                "Created TimeRequest push test record.",
                "Record: \(record.recordID.recordName)",
                "Subscription predicate match: \(matches ? "yes" : "no")",
                "Important: CloudKit does not reliably send query-subscription pushes back to the same user/device that created the record. Use this to verify schema/predicate/save. For a real remote push test, create the request from a second Apple ID/device."
            ].joined(separator: "\n")
        } catch {
            devDiagnostics = "TimeRequest push test failed:\n\(shortCloudDiagnostic(error))"
            setCloudError(error, context: "create time request push test")
        }
    }

    func createDevelopmentFriendRequestPushTest() async {
        guard isAuthenticated, !isDeveloperSession else {
            devDiagnostics = "Use Apple sign-in, not Development login, for CloudKit push tests."
            return
        }
        let senderID = "SCHEMA-PUSH-SENDER"
        let connection = FriendConnection(
            id: "friendship_push_test_\(UUID().uuidString)",
            userIDs: [currentAppUserID, senderID].sorted(),
            displayNames: [
                currentAppUserID: currentUserDisplayName,
                senderID: "Push Test"
            ],
            requestedByID: senderID,
            requestedToID: currentAppUserID,
            status: .pending,
            createdAt: Date()
        )

        do {
            await configureNotifications()
            let record = CKRecord(recordType: friendshipRecordType, recordID: CKRecord.ID(recordName: connection.id))
            write(connection, to: record)
            _ = try await publicDatabase.save(record)
            let matches = await friendRequestSubscriptionMatches(recordName: record.recordID.recordName)
            devDiagnostics = [
                "Created FriendRequest push test record.",
                "Record: \(record.recordID.recordName)",
                "Subscription predicate match: \(matches ? "yes" : "no")",
                "It is hidden from the friend list because it uses a SCHEMA test user.",
                "Important: CloudKit does not reliably send query-subscription pushes back to the same user/device that created the record. Use a second Apple ID/device for the real push test."
            ].joined(separator: "\n")
        } catch {
            devDiagnostics = "FriendRequest push test failed:\n\(shortCloudDiagnostic(error))"
            setCloudError(error, context: "create friend request push test")
        }
    }

    func loadNotificationDiagnostics() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        var lines = [
            "Notifications:",
            "Authorization: \(notificationAuthorizationDescription(settings.authorizationStatus))",
            "Alert: \(notificationSettingDescription(settings.alertSetting))",
            "Sound: \(notificationSettingDescription(settings.soundSetting))",
            "Badge: \(notificationSettingDescription(settings.badgeSetting))"
        ]

        do {
            let subscriptions = try await publicDatabase.allSubscriptions()
            lines.append("CloudKit subscriptions: \(subscriptions.count)")
            lines.append(contentsOf: subscriptions.map { "- \($0.subscriptionID)" }.sorted())
            lines.append("Expected active subscriptions:")
            lines.append("- \(timeRequestSubscriptionID)")
            lines.append("- \(friendRequestSubscriptionID)")
            lines.append("- \(timeRequestApprovedSubscriptionID)")
            lines.append("- \(timeRequestDeclinedSubscriptionID)")
        } catch {
            lines.append("CloudKit subscription check failed: \(shortCloudDiagnostic(error))")
        }

        devDiagnostics = lines.joined(separator: "\n")
    }

    private func configureNotifications() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            } else {
                devDiagnostics = "Notification permission denied. CloudKit can create subscriptions, but APNs alerts will not be shown."
            }
        } catch {
            devDiagnostics = "Notification authorization failed: \(error.localizedDescription)"
        }
        await saveSubscriptions()
    }

    private func saveSubscriptions() async {
        guard !currentAppUserID.isEmpty else { return }
        let timePredicate = NSPredicate(format: "ANY approverIDs == %@ AND status == %@", currentAppUserID, TimeRequestStatus.open.rawValue)
        let timeSubscription = CKQuerySubscription(
            recordType: timeRequestRecordType,
            predicate: timePredicate,
            subscriptionID: timeRequestSubscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )

        let friendPredicate = NSPredicate(format: "requestedToID == %@ AND status == %@", currentAppUserID, FriendConnection.Status.pending.rawValue)
        let friendSubscription = CKQuerySubscription(
            recordType: friendshipRecordType,
            predicate: friendPredicate,
            subscriptionID: friendRequestSubscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )

        let approvedResponsePredicate = NSPredicate(
            format: "requesterID == %@ AND status == %@",
            currentAppUserID,
            TimeRequestStatus.approved.rawValue
        )
        let approvedResponseSubscription = CKQuerySubscription(
            recordType: timeRequestRecordType,
            predicate: approvedResponsePredicate,
            subscriptionID: timeRequestApprovedSubscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )

        let declinedResponsePredicate = NSPredicate(
            format: "requesterID == %@ AND status == %@",
            currentAppUserID,
            TimeRequestStatus.declined.rawValue
        )
        let declinedResponseSubscription = CKQuerySubscription(
            recordType: timeRequestRecordType,
            predicate: declinedResponsePredicate,
            subscriptionID: timeRequestDeclinedSubscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )

        timeSubscription.notificationInfo = notificationInfo(body: "A friend requested more time.")
        friendSubscription.notificationInfo = notificationInfo(body: "Someone sent you a friend request.")
        approvedResponseSubscription.notificationInfo = notificationInfo(body: "Your time request was approved.")
        declinedResponseSubscription.notificationInfo = notificationInfo(body: "Your time request was declined.")

        let staleIDs = [
            "time_requests_\(currentAppUserID)",
            "friend_requests_\(currentAppUserID)",
            "time_requests_\(currentAppUserID)_v2",
            "friend_requests_\(currentAppUserID)_v2",
            "time_requests_\(currentAppUserID)_v3",
            "friend_requests_\(currentAppUserID)_v3",
            "time_request_approved_\(currentAppUserID)_v3",
            "time_request_declined_\(currentAppUserID)_v3"
        ]
        let existingIDs = (try? await publicDatabase.allSubscriptions().map(\.subscriptionID)) ?? []
        let existingIDSet = Set(existingIDs)
        let errors = await replaceSubscriptions(
            [timeSubscription, friendSubscription, approvedResponseSubscription, declinedResponseSubscription],
            deleting: staleIDs.filter { existingIDSet.contains($0) }
        )
        if !errors.isEmpty {
            infoMessage = "Notification subscription issue:\n\(errors.joined(separator: "\n"))"
        }
    }

    private var timeRequestSubscriptionID: String {
        "time_requests_\(currentAppUserID)_\(cloudKitSubscriptionVersion)"
    }

    private var friendRequestSubscriptionID: String {
        "friend_requests_\(currentAppUserID)_\(cloudKitSubscriptionVersion)"
    }

    private var timeRequestApprovedSubscriptionID: String {
        "time_request_approved_\(currentAppUserID)_\(cloudKitSubscriptionVersion)"
    }

    private var timeRequestDeclinedSubscriptionID: String {
        "time_request_declined_\(currentAppUserID)_\(cloudKitSubscriptionVersion)"
    }

    private func replaceSubscriptions(_ subscriptions: [CKSubscription], deleting staleIDs: [String]) async -> [String] {
        await withCheckedContinuation { continuation in
            let operation = CKModifySubscriptionsOperation(subscriptionsToSave: subscriptions, subscriptionIDsToDelete: staleIDs)
            operation.modifySubscriptionsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: [])
                case .failure(let error):
                    continuation.resume(returning: ["subscriptions: \(self.shortCloudDiagnostic(error))"])
                }
            }
            publicDatabase.add(operation)
        }
    }

    private func timeRequestSubscriptionMatches(recordName: String) async -> Bool {
        do {
            let record = try await publicDatabase.record(for: CKRecord.ID(recordName: recordName))
            guard let request = readTimeRequest(from: record) else { return false }
            return request.status == .open && request.approverIDs.contains(currentAppUserID)
        } catch {
            return false
        }
    }

    private func friendRequestSubscriptionMatches(recordName: String) async -> Bool {
        do {
            let record = try await publicDatabase.record(for: CKRecord.ID(recordName: recordName))
            guard let connection = readFriendship(from: record) else { return false }
            return connection.status == .pending && connection.requestedToID == currentAppUserID
        } catch {
            return false
        }
    }

    private func notificationInfo(body: String) -> CKSubscription.NotificationInfo {
        let info = CKSubscription.NotificationInfo()
        info.title = "Bound"
        info.alertBody = body
        info.soundName = "default"
        info.shouldBadge = true
        info.shouldSendContentAvailable = true
        return info
    }

    private func notifyLimitApprovers(_ limit: AppLimitPolicy) async {
        // CloudKit subscriptions deliver future request notifications. A true "new limit" push for every selected
        // friend needs a separate notification event record or an app server.
        infoMessage = "Limit saved. Selected friends can now approve requests for it."
    }

    private func removeNotification(for request: AppTimeRequest) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [request.notificationIdentifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [request.notificationIdentifier])
        syncAppBadge()
    }

    private func saveUserProfileToCloud() async {
        guard let currentUserIdentifier, !isDeveloperSession else { return }
        isSyncing = true
        defer { isSyncing = false }

        let privateRecordID = CKRecord.ID(recordName: "user_\(currentUserIdentifier)")
        let privateRecord = (try? await privateDatabase.record(for: privateRecordID)) ?? CKRecord(recordType: profileRecordType, recordID: privateRecordID)
        privateRecord["appleUserID"] = currentUserIdentifier as NSString
        privateRecord["appUserID"] = currentAppUserID as NSString
        privateRecord["displayName"] = currentUserDisplayName as NSString

        let publicRecordID = CKRecord.ID(recordName: publicUserRecordName(for: currentAppUserID))
        let publicRecord = (try? await publicDatabase.record(for: publicRecordID)) ?? CKRecord(recordType: profileRecordType, recordID: publicRecordID)
        publicRecord["appUserID"] = currentAppUserID as NSString
        publicRecord["displayName"] = currentUserDisplayName as NSString

        do {
            _ = try await privateDatabase.save(privateRecord)
            _ = try await publicDatabase.save(publicRecord)
        } catch {
            setCloudError(error, context: "save profile")
        }
    }

    private func writeFriendRemovalRecordsForAccountDeletion(appUserID: String, displayName: String) async throws {
        let query = CKQuery(recordType: friendshipRecordType, predicate: NSPredicate(format: "ANY userIDs == %@", appUserID))
        let (results, _) = try await publicDatabase.records(matching: query)
        let connections = results.compactMap { result -> FriendConnection? in
            guard case .success(let record) = result.1 else { return nil }
            return readFriendship(from: record)
        }
        let latestConnections = latestFriendshipByPair(from: connections).values
        for connection in latestConnections where connection.status != .declined {
            guard let friendID = connection.userIDs.first(where: { $0 != appUserID }) else { continue }
            let removal = FriendConnection(
                id: "friendship_removed_\(friendshipPairKey([appUserID, friendID]))_\(appUserID)_\(UUID().uuidString)",
                userIDs: [appUserID, friendID].sorted(),
                displayNames: [
                    appUserID: displayName,
                    friendID: connection.displayNames[friendID] ?? friendID
                ],
                requestedByID: appUserID,
                requestedToID: friendID,
                status: .declined,
                createdAt: Date()
            )
            let record = CKRecord(recordType: friendshipRecordType, recordID: CKRecord.ID(recordName: removal.id))
            write(removal, to: record)
            _ = try await publicDatabase.save(record)
        }
    }

    private func deletePublicRecords(recordType: String, predicate: NSPredicate) async throws {
        let recordIDs = try await publicRecordIDs(recordType: recordType, predicate: predicate)
        for recordID in recordIDs {
            try await deleteRecordIfExists(recordID, in: publicDatabase)
        }
    }

    private func publicRecordIDs(recordType: String, predicate: NSPredicate) async throws -> [CKRecord.ID] {
        let query = CKQuery(recordType: recordType, predicate: predicate)
        let (results, _) = try await publicDatabase.records(
            matching: query,
            desiredKeys: [],
            resultsLimit: CKQueryOperation.maximumResults
        )
        return results.compactMap { result in
            guard case .success(let record) = result.1 else { return nil }
            return record.recordID
        }
    }

    private func deleteRecordIfExists(_ recordID: CKRecord.ID, in database: CKDatabase) async throws {
        do {
            _ = try await database.deleteRecord(withID: recordID)
        } catch {
            guard let cloudError = error as? CKError, cloudError.code == .unknownItem else {
                throw error
            }
        }
    }

    private func isPlaceholderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "Guest" || trimmed == "Apple User"
    }

    private func loadFreshRemoteState() async {
        await loadFriendState()
        await loadLimits()
        await loadIncomingTimeRequests()
        await loadOwnTimeRequests()
        syncScreenTimeTracking()
    }

    private func loadFriends() async {
        await loadFriendState()
    }

    private func loadFriendRequests() async {
        await loadFriendState()
    }

    private func loadFriendState() async {
        guard !currentAppUserID.isEmpty, !isDeveloperSession else { return }
        let query = CKQuery(recordType: friendshipRecordType, predicate: NSPredicate(format: "ANY userIDs == %@", currentAppUserID))
        do {
            let (results, _) = try await publicDatabase.records(matching: query)
            let connections = results.compactMap { result in
                guard case .success(let record) = result.1,
                      let connection = readFriendship(from: record) else { return nil }
                return connection
            }
            .filter { !isSchemaFriendship($0) }
            let visibleConnections = friendshipConnectionsWithPendingOverlay(connections)
            friends = visibleAcceptedFriendships(from: visibleConnections)
                .compactMap { $0.friend(for: currentAppUserID) }
            .filter { !isSchemaUserID($0.appUserID) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            let pending = latestFriendshipByPair(from: visibleConnections).values.filter { $0.status == .pending }
            incomingFriendRequests = pending
                .filter { $0.requestedToID == currentAppUserID }
                .sorted { $0.createdAt > $1.createdAt }
            outgoingFriendRequests = pending
                .filter { $0.requestedByID == currentAppUserID }
                .sorted { $0.createdAt > $1.createdAt }
            saveLocalState()
        } catch {
            if !isMissingCloudSchema(error) {
                setCloudError(error, context: "load friends")
            }
        }
    }

    private func loadLimits() async {
        guard !currentAppUserID.isEmpty, !isDeveloperSession else { return }
        let query = CKQuery(recordType: limitRecordType, predicate: NSPredicate(format: "ownerID == %@", currentAppUserID))
        query.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        do {
            let (results, _) = try await publicDatabase.records(matching: query)
            let fetchedLimits: [AppLimitPolicy] = results.compactMap { result in
                guard case .success(let record) = result.1 else { return nil }
                return readLimit(from: record)
            }
            .filter { !isSchemaLimit($0) }
            limits = limitsWithPendingOverlay(uniqueLatestLimits(fetchedLimits))
            saveLocalState()
        } catch {
            if !isMissingCloudSchema(error) {
                setCloudError(error, context: "load limits")
            }
        }
    }

    private func loadIncomingTimeRequests() async {
        guard !currentAppUserID.isEmpty, !isDeveloperSession else { return }
        let query = CKQuery(recordType: timeRequestRecordType, predicate: NSPredicate(format: "ANY approverIDs == %@", currentAppUserID))
        query.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        do {
            let (results, _) = try await publicDatabase.records(matching: query)
            let requests: [AppTimeRequest] = results.compactMap { result in
                guard case .success(let record) = result.1 else { return nil }
                return readTimeRequest(from: record)
            }
            .filter { !isSchemaTimeRequest($0) }
            incomingRequests = timeRequestsWithPendingOverlay(mergedTimeRequests(from: requests), includeIncoming: true)
            removeResolvedNotifications()
            saveLocalState()
        } catch {
            if !isMissingCloudSchema(error) {
                setCloudError(error, context: "load incoming requests")
            }
        }
    }

    private func loadOwnTimeRequests() async {
        guard !currentAppUserID.isEmpty, !isDeveloperSession else { return }
        let query = CKQuery(recordType: timeRequestRecordType, predicate: NSPredicate(format: "requesterID == %@", currentAppUserID))
        query.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        do {
            let (results, _) = try await publicDatabase.records(matching: query)
            let requests: [AppTimeRequest] = results.compactMap { result in
                guard case .success(let record) = result.1 else { return nil }
                return readTimeRequest(from: record)
            }
            .filter { !isSchemaTimeRequest($0) }
            ownRequests = timeRequestsWithPendingOverlay(mergedTimeRequests(from: requests), includeIncoming: false)
            saveLocalState()
        } catch {
            if !isMissingCloudSchema(error) {
                setCloudError(error, context: "load own requests")
            }
        }
    }

    private func removeResolvedNotifications() {
        incomingRequests
            .filter { $0.status != .open }
            .forEach(removeNotification)
        syncAppBadge()
    }

    private func fetchPublicProfile(appUserID: String) async throws -> FriendProfile? {
        let record = try await publicDatabase.record(for: CKRecord.ID(recordName: publicUserRecordName(for: appUserID)))
        guard let id = record["appUserID"] as? String else { return nil }
        return FriendProfile(appUserID: id, displayName: record["displayName"] as? String ?? id)
    }

    private func isSchemaUserID(_ appUserID: String) -> Bool {
        appUserID.hasPrefix("SCHEMA-")
    }

    private func isSchemaFriendship(_ connection: FriendConnection) -> Bool {
        connection.userIDs.contains(where: isSchemaUserID)
    }

    private func isSchemaLimit(_ limit: AppLimitPolicy) -> Bool {
        limit.id == schemaSampleLimitID ||
        isSchemaUserID(limit.ownerID) ||
        limit.approverIDs.contains(where: isSchemaUserID) ||
        limit.title.localizedCaseInsensitiveContains("schema sample")
    }

    private func isSchemaTimeRequest(_ request: AppTimeRequest) -> Bool {
        request.id == schemaSampleRequestID ||
        request.limitID == schemaSampleLimitID ||
        isSchemaUserID(request.requesterID) ||
        request.approverIDs.contains(where: isSchemaUserID) ||
        request.limitTitle.localizedCaseInsensitiveContains("schema sample")
    }

    private func hasOpenOwnRequest(for limitID: UUID) -> Bool {
        ownRequests.contains { $0.limitID == limitID && $0.status == .open && $0.responseToRequestID == nil }
    }

    private func usageMinutesToday(for limitID: UUID) -> Int {
        // The main app cannot read live per-app Screen Time usage directly.
        0
    }

    private func syncScreenTimeTrackingAfterLaunch() {
        Task { @MainActor in
            syncScreenTimeTracking()
        }
    }

    private func syncScreenTimeTracking() {
        guard isAuthenticated, isAuthorized else { return }

        var didUpdateMonitorState = false
        let activeLimitKeys = Set(limits.map { screenTimeStateKey(for: $0.id) })
        let activeNames = Set(limits.map { deviceActivityName(for: $0.id) })
        let staleNames = deviceActivityCenter.activities.filter { activity in
            activity.rawValue.hasPrefix(screenTimeActivityPrefix) && !activeNames.contains(activity)
        }
        let staleStateKeys = Set(screenTimeMonitorState.keys).subtracting(activeLimitKeys)

        if !staleNames.isEmpty {
            deviceActivityCenter.stopMonitoring(staleNames)
            staleNames.forEach(clearShieldStore)
        }
        for stateKey in staleStateKeys {
            let activityName = DeviceActivityName("\(screenTimeActivityPrefix)\(stateKey)")
            deviceActivityCenter.stopMonitoring([activityName])
            clearShieldStore(activityName)
            screenTimeMonitorState.removeValue(forKey: stateKey)
            didUpdateMonitorState = true
        }

        for limit in limits {
            let activityName = deviceActivityName(for: limit.id)
            let stateKey = screenTimeStateKey(for: limit.id)

            guard hasTrackedSelection(limit) else {
                deviceActivityCenter.stopMonitoring([activityName])
                clearShieldStore(activityName)
                if screenTimeMonitorState.removeValue(forKey: stateKey) != nil {
                    didUpdateMonitorState = true
                }
                continue
            }

            let status = timeStatus(for: limit)
            let signature = screenTimeMonitorSignature(for: limit, totalAvailableMinutes: status.totalAvailableMinutes)
            let monitorChanged = screenTimeMonitorState[stateKey] != signature

            guard status.totalAvailableMinutes > 0 else {
                if monitorChanged {
                    clearShieldStore(activityName)
                }
                applyImmediateShield(for: limit)
                deviceActivityCenter.stopMonitoring([activityName])
                if monitorChanged {
                    screenTimeMonitorState[stateKey] = signature
                    didUpdateMonitorState = true
                }
                continue
            }

            do {
                if monitorChanged {
                    deviceActivityCenter.stopMonitoring([activityName])
                    clearShieldStore(activityName)
                }
                try startScreenTimeMonitoring(limit, activityName: activityName, thresholdMinutes: status.totalAvailableMinutes)
                if monitorChanged {
                    screenTimeMonitorState[stateKey] = signature
                    didUpdateMonitorState = true
                }
            } catch {
                devDiagnostics = "Screen Time tracking failed for \(limit.title): \(error.localizedDescription)"
            }
        }

        if didUpdateMonitorState {
            saveScreenTimeMonitorState()
        }
    }

    private func clearScreenTimeTracking() {
        let boundActivities = deviceActivityCenter.activities.filter { $0.rawValue.hasPrefix(screenTimeActivityPrefix) }
        if !boundActivities.isEmpty {
            deviceActivityCenter.stopMonitoring(boundActivities)
        }
        boundActivities.forEach(clearShieldStore)

        blockingStore.shield.applications = nil
        blockingStore.shield.applicationCategories = nil
        blockingStore.shield.webDomains = nil
        blockingStore.shield.webDomainCategories = nil
        ManagedSettingsStore(named: ManagedSettingsStore.Name("BoundLimitStore")).shield.applications = nil
        ManagedSettingsStore(named: ManagedSettingsStore.Name("BoundLimitStore")).shield.applicationCategories = nil
        ManagedSettingsStore(named: ManagedSettingsStore.Name("BoundLimitStore")).shield.webDomains = nil
        ManagedSettingsStore(named: ManagedSettingsStore.Name("BoundLimitStore")).shield.webDomainCategories = nil
        screenTimeMonitorState.removeAll()
        saveScreenTimeMonitorState()
    }

    private func startScreenTimeMonitoring(_ limit: AppLimitPolicy, activityName: DeviceActivityName, thresholdMinutes: Int) throws {
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )

        let event: DeviceActivityEvent
        if #available(iOS 17.4, *) {
            event = DeviceActivityEvent(
                applications: limit.selection.applicationTokens,
                categories: limit.selection.categoryTokens,
                webDomains: limit.selection.webDomainTokens,
                threshold: DateComponents(minute: thresholdMinutes),
                includesPastActivity: true
            )
        } else {
            event = DeviceActivityEvent(
                applications: limit.selection.applicationTokens,
                categories: limit.selection.categoryTokens,
                webDomains: limit.selection.webDomainTokens,
                threshold: DateComponents(minute: thresholdMinutes)
            )
        }

        try deviceActivityCenter.startMonitoring(
            activityName,
            during: schedule,
            events: [DeviceActivityEvent.Name("limitReached"): event]
        )
    }

    private var screenTimeActivityPrefix: String {
        "BoundLimit_"
    }

    private func deviceActivityName(for limitID: UUID) -> DeviceActivityName {
        DeviceActivityName("\(screenTimeActivityPrefix)\(limitID.uuidString)")
    }

    private func screenTimeStateKey(for limitID: UUID) -> String {
        limitID.uuidString
    }

    private func screenTimeMonitorSignature(for limit: AppLimitPolicy, totalAvailableMinutes: Int) -> String {
        var parts = [
            "minutes:\(totalAvailableMinutes)",
            "mode:\(limit.mode.rawValue)",
            "apps:\(limit.selection.applicationTokens.count)",
            "categories:\(limit.selection.categoryTokens.count)",
            "web:\(limit.selection.webDomainTokens.count)"
        ]
        if let selectionData = try? JSONEncoder().encode(limit.selection) {
            parts.append("selection:\(selectionData.base64EncodedString())")
        }
        return parts.joined(separator: "|")
    }

    private func saveScreenTimeMonitorState() {
        UserDefaults.standard.set(screenTimeMonitorState, forKey: screenTimeMonitorStateKey)
    }

    private func hasTrackedSelection(_ limit: AppLimitPolicy) -> Bool {
        !limit.selection.applicationTokens.isEmpty ||
        !limit.selection.categoryTokens.isEmpty ||
        !limit.selection.webDomainTokens.isEmpty
    }

    private func clearShieldStore(_ activityName: DeviceActivityName) {
        let store = ManagedSettingsStore(named: ManagedSettingsStore.Name(activityName.rawValue))
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.shield.webDomainCategories = nil
    }

    private func applyImmediateShield(for limit: AppLimitPolicy) {
        let store = ManagedSettingsStore(named: ManagedSettingsStore.Name(deviceActivityName(for: limit.id).rawValue))
        store.shield.applications = limit.selection.applicationTokens.isEmpty ? nil : limit.selection.applicationTokens
        store.shield.applicationCategories = limit.selection.categoryTokens.isEmpty ? nil : .specific(limit.selection.categoryTokens)
        store.shield.webDomains = limit.selection.webDomainTokens.isEmpty ? nil : limit.selection.webDomainTokens
        store.shield.webDomainCategories = limit.selection.categoryTokens.isEmpty ? nil : .specific(limit.selection.categoryTokens)
    }

    private func cleanupRemovedFeatureNotifications() {
        let removedPrefixes = ["Bound_low_time_", "Bound_monitor_"]
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let identifiers = requests
                .map(\.identifier)
                .filter { identifier in removedPrefixes.contains { identifier.hasPrefix($0) } }
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
        center.getDeliveredNotifications { notifications in
            let identifiers = notifications
                .map(\.request.identifier)
                .filter { identifier in removedPrefixes.contains { identifier.hasPrefix($0) } }
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    private func syncAppBadge(count explicitCount: Int? = nil) {
        let badgeCount = explicitCount ?? actionableNotificationCount
        UNUserNotificationCenter.current().setBadgeCount(badgeCount) { error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor in
                BlockingManager.shared.devDiagnostics = "Badge update failed: \(message)"
            }
        }
    }

    private var actionableNotificationCount: Int {
        incomingFriendRequests.count + incomingRequests.filter { $0.status == .open }.count
    }

    private func updateLocalRequest(_ request: AppTimeRequest) {
        incomingRequests.removeAll { $0.id == request.id }
        incomingRequests.append(request)
        ownRequests.removeAll { $0.id == request.id }
        if request.requesterID == currentAppUserID {
            ownRequests.append(request)
        }
    }

    private func updateLocalResolvedRequest(originalRequestID: UUID, response: AppTimeRequest) {
        incomingRequests.removeAll { $0.id == originalRequestID || $0.responseToRequestID == originalRequestID || $0.id == response.id }
        incomingRequests.append(response)
        ownRequests.removeAll { $0.id == originalRequestID || $0.responseToRequestID == originalRequestID || $0.id == response.id }
        if response.requesterID == currentAppUserID {
            ownRequests.append(response)
        }
    }

    private func visibleAcceptedFriendships(from connections: [FriendConnection]) -> [FriendConnection] {
        latestFriendshipByPair(from: connections).values.filter { $0.status == .accepted }
    }

    private func friendshipConnectionsWithPendingOverlay(_ connections: [FriendConnection]) -> [FriendConnection] {
        var latestByPair = latestFriendshipByPair(from: connections)
        for (pairKey, pendingConnection) in Array(pendingFriendStateByPair) {
            if latestByPair[pairKey]?.id == pendingConnection.id {
                pendingFriendStateByPair.removeValue(forKey: pairKey)
            } else {
                latestByPair[pairKey] = pendingConnection
            }
        }
        return Array(latestByPair.values)
    }

    private func latestFriendshipByPair(from connections: [FriendConnection]) -> [String: FriendConnection] {
        let sorted = connections.sorted { $0.createdAt > $1.createdAt }
        var latestByPair: [String: FriendConnection] = [:]
        for connection in sorted where latestByPair[friendshipPairKey(connection.userIDs)] == nil {
            latestByPair[friendshipPairKey(connection.userIDs)] = connection
        }
        return latestByPair
    }

    private func limitsWithPendingOverlay(_ fetchedLimits: [AppLimitPolicy]) -> [AppLimitPolicy] {
        let uniqueFetchedLimits = uniqueLatestLimits(fetchedLimits)
        let fetchedIDs = Set(uniqueFetchedLimits.map(\.id))
        for id in Array(pendingLimitDeletes) where !fetchedIDs.contains(id) {
            pendingLimitDeletes.remove(id)
        }
        var fetchedLimitByID: [UUID: AppLimitPolicy] = [:]
        for limit in uniqueFetchedLimits {
            fetchedLimitByID[limit.id] = limit
        }
        for (id, pendingLimit) in Array(pendingLimitUpserts) {
            if let fetchedLimit = fetchedLimitByID[id], fetchedLimit.updatedAt >= pendingLimit.updatedAt {
                pendingLimitUpserts.removeValue(forKey: id)
            }
        }

        var visible = uniqueFetchedLimits.filter { !pendingLimitDeletes.contains($0.id) }
        for pendingLimit in pendingLimitUpserts.values {
            visible.removeAll { $0.id == pendingLimit.id }
            visible.append(pendingLimit)
        }
        return visible.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func uniqueLatestLimits(_ limits: [AppLimitPolicy]) -> [AppLimitPolicy] {
        var latestByID: [UUID: AppLimitPolicy] = [:]
        for limit in limits.sorted(by: { $0.updatedAt > $1.updatedAt }) where latestByID[limit.id] == nil {
            latestByID[limit.id] = limit
        }
        return Array(latestByID.values).sorted { $0.updatedAt > $1.updatedAt }
    }

    private func mergedTimeRequests(from requests: [AppTimeRequest]) -> [AppTimeRequest] {
        var responseByOriginalID: [UUID: AppTimeRequest] = [:]
        let responses = requests.filter { $0.responseToRequestID != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
        for response in responses {
            guard let originalID = response.responseToRequestID, responseByOriginalID[originalID] == nil else { continue }
            responseByOriginalID[originalID] = response
        }

        let originals = requests.filter { $0.responseToRequestID == nil }
        var merged = originals.map { original in
            responseByOriginalID[original.id] ?? original
        }
        let originalIDs = Set(originals.map(\.id))
        merged.append(contentsOf: responses.filter { response in
            guard let originalID = response.responseToRequestID else { return false }
            return !originalIDs.contains(originalID)
        })
        return merged.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func timeRequestsWithPendingOverlay(_ fetchedRequests: [AppTimeRequest], includeIncoming: Bool) -> [AppTimeRequest] {
        let fetchedIDs = Set(fetchedRequests.map(\.id))
        let fetchedResponseOriginalIDs = Set(fetchedRequests.compactMap(\.responseToRequestID))

        for id in Array(pendingTimeRequests.keys) where fetchedIDs.contains(id) {
            pendingTimeRequests.removeValue(forKey: id)
        }
        for originalID in Array(pendingTimeResponses.keys) where fetchedResponseOriginalIDs.contains(originalID) {
            pendingTimeResponses.removeValue(forKey: originalID)
        }

        var visible = fetchedRequests
        for pendingRequest in pendingTimeRequests.values where shouldShowPendingTimeRequest(pendingRequest, includeIncoming: includeIncoming) {
            visible.removeAll { $0.id == pendingRequest.id }
            visible.append(pendingRequest)
        }
        for (originalID, pendingResponse) in pendingTimeResponses where shouldShowPendingTimeRequest(pendingResponse, includeIncoming: includeIncoming) {
            visible.removeAll { $0.id == originalID || $0.responseToRequestID == originalID }
            visible.append(pendingResponse)
        }
        return visible.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func shouldShowPendingTimeRequest(_ request: AppTimeRequest, includeIncoming: Bool) -> Bool {
        if includeIncoming {
            return request.approverIDs.contains(currentAppUserID)
        }
        return request.requesterID == currentAppUserID
    }

    private func write(_ connection: FriendConnection, to record: CKRecord) {
        record["userIDs"] = connection.userIDs as NSArray
        record["displayNamesData"] = try? JSONEncoder().encode(connection.displayNames) as NSData
        record["requestedByID"] = connection.requestedByID as NSString
        record["requestedToID"] = connection.requestedToID as NSString
        record["status"] = connection.status.rawValue as NSString
        record["createdAt"] = connection.createdAt as NSDate
    }

    private func readFriendship(from record: CKRecord) -> FriendConnection? {
        guard let userIDs = record["userIDs"] as? [String],
              let createdAt = record["createdAt"] as? Date else { return nil }
        var displayNames: [String: String] = [:]
        if let data = record["displayNamesData"] as? Data,
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            displayNames = decoded
        }
        let requestedByID = record["requestedByID"] as? String ?? userIDs.first ?? ""
        let requestedToID = record["requestedToID"] as? String ?? userIDs.dropFirst().first ?? ""
        let status = (record["status"] as? String).flatMap(FriendConnection.Status.init(rawValue:)) ?? .accepted
        return FriendConnection(
            id: record.recordID.recordName,
            userIDs: userIDs,
            displayNames: displayNames,
            requestedByID: requestedByID,
            requestedToID: requestedToID,
            status: status,
            createdAt: createdAt
        )
    }

    private func write(_ limit: AppLimitPolicy, to record: CKRecord) {
        record["id"] = limit.id.uuidString as NSString
        record["ownerID"] = limit.ownerID as NSString
        record["ownerName"] = limit.ownerName as NSString
        record["title"] = limit.title as NSString
        record["minutes"] = limit.minutes as NSNumber
        record["mode"] = limit.mode.rawValue as NSString
        record["approverIDs"] = limit.approverIDs as NSArray
        record["selectionData"] = try? JSONEncoder().encode(limit.selection) as NSData
        record["createdAt"] = limit.createdAt as NSDate
        record["updatedAt"] = limit.updatedAt as NSDate
    }

    private func readLimit(from record: CKRecord) -> AppLimitPolicy? {
        guard let idString = record["id"] as? String,
              let id = UUID(uuidString: idString),
              let ownerID = record["ownerID"] as? String,
              let ownerName = record["ownerName"] as? String,
              let title = record["title"] as? String,
              let minutes = record["minutes"] as? Int,
              let modeString = record["mode"] as? String,
              let mode = LimitMode(rawValue: modeString),
              let createdAt = record["createdAt"] as? Date,
              let updatedAt = record["updatedAt"] as? Date else { return nil }
        var selection = FamilyActivitySelection()
        if let data = record["selectionData"] as? Data,
           let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            selection = decoded
        }
        return AppLimitPolicy(
            id: id,
            ownerID: ownerID,
            ownerName: ownerName,
            title: title,
            minutes: minutes,
            mode: mode,
            approverIDs: record["approverIDs"] as? [String] ?? [],
            selection: selection,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func write(_ request: AppTimeRequest, to record: CKRecord) {
        record["id"] = request.id.uuidString as NSString
        record["responseToRequestID"] = (request.responseToRequestID?.uuidString ?? "") as NSString
        record["requesterID"] = request.requesterID as NSString
        record["requesterName"] = request.requesterName as NSString
        record["limitID"] = request.limitID.uuidString as NSString
        record["limitTitle"] = request.limitTitle as NSString
        record["approverIDs"] = request.approverIDs as NSArray
        record["requestedMinutes"] = request.requestedMinutes as NSNumber
        record["status"] = request.status.rawValue as NSString
        if let resolvedByID = request.resolvedByID {
            record["resolvedByID"] = resolvedByID as NSString
        } else {
            record["resolvedByID"] = nil
        }
        if let resolvedByName = request.resolvedByName {
            record["resolvedByName"] = resolvedByName as NSString
        } else {
            record["resolvedByName"] = nil
        }
        record["createdAt"] = request.createdAt as NSDate
        record["updatedAt"] = request.updatedAt as NSDate
    }

    private func readTimeRequest(from record: CKRecord) -> AppTimeRequest? {
        guard let idString = record["id"] as? String,
              let id = UUID(uuidString: idString),
              let requesterID = record["requesterID"] as? String,
              let requesterName = record["requesterName"] as? String,
              let limitIDString = record["limitID"] as? String,
              let limitID = UUID(uuidString: limitIDString),
              let limitTitle = record["limitTitle"] as? String,
              let requestedMinutes = record["requestedMinutes"] as? Int,
              let statusString = record["status"] as? String,
              let status = TimeRequestStatus(rawValue: statusString),
              let createdAt = record["createdAt"] as? Date,
              let updatedAt = record["updatedAt"] as? Date else { return nil }
        return AppTimeRequest(
            id: id,
            responseToRequestID: (record["responseToRequestID"] as? String).flatMap { $0.isEmpty ? nil : UUID(uuidString: $0) },
            requesterID: requesterID,
            requesterName: requesterName,
            limitID: limitID,
            limitTitle: limitTitle,
            approverIDs: record["approverIDs"] as? [String] ?? [],
            requestedMinutes: requestedMinutes,
            status: status,
            resolvedByID: record["resolvedByID"] as? String,
            resolvedByName: record["resolvedByName"] as? String,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func startAutoRefresh() {
        refreshTimer = Timer.publish(every: 3, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.refreshRemoteChanges() }
            }
    }

    private func friendshipID(_ first: String, _ second: String) -> String {
        "friendship_\([first, second].sorted().joined(separator: "_"))"
    }

    private func friendPendingRequestID(to friendID: String) -> String {
        "friendship_pending_\(friendshipPairKey([currentAppUserID, friendID]))_\(currentAppUserID)_\(UUID().uuidString)"
    }

    private func friendResponseID(for request: FriendConnection, accepted: Bool) -> String {
        let action = accepted ? "accepted" : "declined"
        return "friendship_\(action)_\(friendshipPairKey(request.userIDs))_\(currentAppUserID)"
    }

    private func friendRemovalID(_ friendID: String) -> String {
        "friendship_removed_\(friendshipPairKey([currentAppUserID, friendID]))_\(currentAppUserID)_\(UUID().uuidString)"
    }

    private func friendshipPairKey(_ userIDs: [String]) -> String {
        userIDs.sorted().joined(separator: "_")
    }

    private func limitRecordName(_ id: UUID) -> String {
        "limit_\(id.uuidString)"
    }

    private func timeRequestRecordName(_ id: UUID) -> String {
        "time_request_\(id.uuidString)"
    }

    private func timeRequestResponseRecordName(originalRequestID: UUID, responderID: String) -> String {
        "time_request_response_\(originalRequestID.uuidString)_\(responderID)"
    }

    private func existingOrGeneratedAppUserID() -> String {
        if let stored = UserDefaults.standard.string(forKey: currentAppUserIDKey), !stored.isEmpty {
            return normalizeAppUserID(stored)
        }
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return "FB-\((0..<8).map { _ in String(alphabet[Int.random(in: 0..<alphabet.count)]) }.joined())"
    }

    private func normalizeAppUserID(_ userID: String) -> String {
        userID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func publicUserRecordName(for appUserID: String) -> String {
        "public_user_\(normalizeAppUserID(appUserID).replacingOccurrences(of: "-", with: "_"))"
    }

    private func setCloudError(_ error: Error, context: String) {
        authError = cloudDiagnosticMessage(for: error, context: context)
    }

    private func cloudDiagnosticMessage(for error: Error, context: String) -> String {
        guard let cloudError = error as? CKError else {
            return "Cloud sync failed while trying to \(context): \(error.localizedDescription)"
        }
        var lines = [
            "CloudKit failed while trying to \(context).",
            "Code: \(cloudError.code.rawValue) (\(cloudError.code))",
            "Message: \(cloudError.localizedDescription)"
        ]
        if isMissingCloudSchema(error) {
            lines.append("Fix: seed the Development schema from Settings, then deploy it to Production for TestFlight.")
        }
        return lines.joined(separator: "\n")
    }

    private func shortCloudDiagnostic(_ error: Error) -> String {
        guard let cloudError = error as? CKError else {
            return error.localizedDescription
        }
        return "\(cloudError.code.rawValue) (\(cloudError.code)): \(cloudError.localizedDescription)"
    }

    private func notificationAuthorizationDescription(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private func notificationSettingDescription(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported: return "not supported"
        case .disabled: return "disabled"
        case .enabled: return "enabled"
        @unknown default: return "unknown"
        }
    }

    private func isMissingCloudSchema(_ error: Error) -> Bool {
        guard let cloudError = error as? CKError else { return false }
        return cloudError.code == .unknownItem
    }

    private func saveLocalState() {
        UserDefaults.standard.set(currentUserIdentifier, forKey: currentUserIdentifierKey)
        UserDefaults.standard.set(currentAppUserID, forKey: currentAppUserIDKey)
        UserDefaults.standard.set(currentUserDisplayName, forKey: currentUserDisplayNameKey)
        UserDefaults.standard.set(isDeveloperSession, forKey: isDeveloperSessionKey)
        encode(friends, key: localFriendsKey)
        encode(incomingFriendRequests, key: localIncomingFriendRequestsKey)
        encode(outgoingFriendRequests, key: localOutgoingFriendRequestsKey)
        encode(limits, key: localLimitsKey)
        encode(incomingRequests, key: localIncomingRequestsKey)
        encode(ownRequests, key: localOwnRequestsKey)
        syncAppBadge()
    }

    private func loadLocalState() {
        currentUserIdentifier = UserDefaults.standard.string(forKey: currentUserIdentifierKey)
        currentAppUserID = UserDefaults.standard.string(forKey: currentAppUserIDKey) ?? ""
        currentUserDisplayName = UserDefaults.standard.string(forKey: currentUserDisplayNameKey) ?? "Guest"
        isDeveloperSession = UserDefaults.standard.bool(forKey: isDeveloperSessionKey)
        isAuthenticated = currentUserIdentifier != nil
        needsDisplayName = isAuthenticated && !isDeveloperSession && isPlaceholderName(currentUserDisplayName)
        screenTimeMonitorState = UserDefaults.standard.dictionary(forKey: screenTimeMonitorStateKey) as? [String: String] ?? [:]
        loadLocalCollections()
    }

    private func loadLocalCollections() {
        friends = decode([FriendProfile].self, key: localFriendsKey) ?? friends
        incomingFriendRequests = decode([FriendConnection].self, key: localIncomingFriendRequestsKey) ?? []
        outgoingFriendRequests = decode([FriendConnection].self, key: localOutgoingFriendRequestsKey) ?? []
        limits = uniqueLatestLimits((decode([AppLimitPolicy].self, key: localLimitsKey) ?? []).filter { !isSchemaLimit($0) })
        incomingRequests = uniqueLatestTimeRequests((decode([AppTimeRequest].self, key: localIncomingRequestsKey) ?? []).filter { !isSchemaTimeRequest($0) })
        ownRequests = uniqueLatestTimeRequests((decode([AppTimeRequest].self, key: localOwnRequestsKey) ?? []).filter { !isSchemaTimeRequest($0) })
        syncAppBadge()
    }

    private func uniqueLatestTimeRequests(_ requests: [AppTimeRequest]) -> [AppTimeRequest] {
        var latestByID: [UUID: AppTimeRequest] = [:]
        for request in requests.sorted(by: { $0.updatedAt > $1.updatedAt }) where latestByID[request.id] == nil {
            latestByID[request.id] = request
        }
        return Array(latestByID.values).sorted { $0.updatedAt > $1.updatedAt }
    }

    private func encode<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
