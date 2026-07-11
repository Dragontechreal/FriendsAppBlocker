import Foundation
import Combine
import FamilyControls
import ManagedSettings
import AuthenticationServices
import CloudKit
import UserNotifications

struct FriendProfile: Identifiable, Codable, Hashable {
    var id: String { appUserID }
    var appUserID: String
    var displayName: String
}

struct FriendConnection: Identifiable, Codable, Hashable {
    let id: String
    var userIDs: [String]
    var displayNames: [String: String]
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

enum TimeRequestStatus: String, Codable, CaseIterable {
    case open
    case approved
    case declined
}

struct AppTimeRequest: Identifiable, Codable, Hashable {
    let id: UUID
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
        "time_request_\(id.uuidString)"
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
    @Published var limits: [AppLimitPolicy] = []
    @Published var incomingRequests: [AppTimeRequest] = []
    @Published var ownRequests: [AppTimeRequest] = []
    @Published var isAuthenticated = false
    @Published var isDeveloperSession = false
    @Published var isSyncing = false
    @Published var authError: String?
    @Published var infoMessage: String?

    private let appContainerIdentifier = "iCloud.dev.supremezone.friendsappblock"
    private let profileRecordType = "UserProfile"
    private let friendshipRecordType = "Friendship"
    private let limitRecordType = "LimitPolicy"
    private let timeRequestRecordType = "TimeRequest"
    private let currentUserIdentifierKey = "currentUserIdentifier"
    private let currentAppUserIDKey = "currentAppUserID"
    private let currentUserDisplayNameKey = "currentUserDisplayName"
    private let isDeveloperSessionKey = "isDeveloperSession"
    private let localFriendsKey = "localFriends"
    private let localLimitsKey = "localLimits"
    private let localIncomingRequestsKey = "localIncomingRequests"
    private let localOwnRequestsKey = "localOwnRequests"
    private let blockingStore = ManagedSettingsStore()

    private var privateDatabase: CKDatabase {
        CKContainer(identifier: appContainerIdentifier).privateCloudDatabase
    }

    private var publicDatabase: CKDatabase {
        CKContainer(identifier: appContainerIdentifier).publicCloudDatabase
    }

    private init() {
        updateAuthorizationStatus()
        loadLocalState()
    }

    var supportsFamilyControls: Bool { true }

    var openIncomingRequests: [AppTimeRequest] {
        incomingRequests.filter { $0.status == .open }
    }

    var openOwnRequests: [AppTimeRequest] {
        ownRequests.filter { $0.status == .open }
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
            signIn(userIdentifier: credential.user, appUserID: existingOrGeneratedAppUserID(), displayName: name.isEmpty ? "Apple User" : name, developer: false)
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
    }

    func signOut() {
        currentUserIdentifier = nil
        currentAppUserID = ""
        currentUserDisplayName = "Guest"
        friends = []
        limits = []
        incomingRequests = []
        ownRequests = []
        isAuthenticated = false
        isDeveloperSession = false
        authError = nil
        infoMessage = nil
        selectedApps = FamilyActivitySelection()
        blockingStore.shield.applications = nil
        blockingStore.shield.webDomains = nil
        [
            currentUserIdentifierKey,
            currentAppUserIDKey,
            currentUserDisplayNameKey,
            isDeveloperSessionKey,
            localFriendsKey,
            localLimitsKey,
            localIncomingRequestsKey,
            localOwnRequestsKey
        ].forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    func refreshAll() async {
        guard isAuthenticated else { return }
        if isDeveloperSession {
            loadLocalCollections()
            return
        }
        await saveUserProfileToCloud()
        await configureNotifications()
        await loadFriends()
        await loadLimits()
        await loadIncomingTimeRequests()
        await loadOwnTimeRequests()
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

        do {
            guard let profile = try await fetchPublicProfile(appUserID: friendID) else {
                authError = "No user found for \(friendID)."
                return
            }
            let connection = FriendConnection(
                id: friendshipID(currentAppUserID, profile.appUserID),
                userIDs: [currentAppUserID, profile.appUserID].sorted(),
                displayNames: [
                    currentAppUserID: currentUserDisplayName,
                    profile.appUserID: profile.displayName
                ],
                createdAt: Date()
            )
            let record = CKRecord(recordType: friendshipRecordType, recordID: CKRecord.ID(recordName: connection.id))
            write(connection, to: record)
            _ = try await publicDatabase.save(record)
            await loadFriends()
        } catch {
            setCloudError(error, context: "add friend")
        }
    }

    func unfriend(_ friend: FriendProfile) async {
        if isDeveloperSession {
            friends.removeAll { $0.appUserID == friend.appUserID }
            saveLocalState()
            return
        }

        do {
            _ = try await publicDatabase.deleteRecord(withID: CKRecord.ID(recordName: friendshipID(currentAppUserID, friend.appUserID)))
            await loadFriends()
        } catch {
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
            return
        }

        do {
            let record = CKRecord(recordType: limitRecordType, recordID: CKRecord.ID(recordName: limitRecordName(updated.id)))
            write(updated, to: record)
            _ = try await publicDatabase.save(record)
            await loadLimits()
            await notifyLimitApprovers(updated)
        } catch {
            setCloudError(error, context: "save limit")
        }
    }

    func deleteLimit(_ limit: AppLimitPolicy) async {
        if isDeveloperSession {
            limits.removeAll { $0.id == limit.id }
            saveLocalState()
            return
        }

        do {
            _ = try await publicDatabase.deleteRecord(withID: CKRecord.ID(recordName: limitRecordName(limit.id)))
            await loadLimits()
        } catch {
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
            return
        }

        do {
            let record = CKRecord(recordType: timeRequestRecordType, recordID: CKRecord.ID(recordName: timeRequestRecordName(request.id)))
            write(request, to: record)
            _ = try await publicDatabase.save(record)
            await loadOwnTimeRequests()
        } catch {
            setCloudError(error, context: "request more time")
        }
    }

    func resolveRequest(_ request: AppTimeRequest, approved: Bool) async {
        guard request.status == .open else { return }
        var updated = request
        updated.status = approved ? .approved : .declined
        updated.resolvedByID = currentAppUserID
        updated.resolvedByName = currentUserDisplayName
        updated.updatedAt = Date()

        if isDeveloperSession {
            updateLocalRequest(updated)
            saveLocalState()
            return
        }

        do {
            let recordID = CKRecord.ID(recordName: timeRequestRecordName(request.id))
            let record = try await publicDatabase.record(for: recordID)
            write(updated, to: record)
            _ = try await publicDatabase.save(record)
            removeNotification(for: request)
            await loadIncomingTimeRequests()
            await loadOwnTimeRequests()
        } catch {
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
        let sampleLimitID = UUID(uuidString: "00000000-0000-0000-0000-000000000010") ?? UUID()
        let sampleRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000011") ?? UUID()

        let sampleFriendship = FriendConnection(
            id: "schema_friendship_sample",
            userIDs: [currentAppUserID, sampleFriendID],
            displayNames: [currentAppUserID: currentUserDisplayName, sampleFriendID: "Schema Friend"],
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

        let friendship = CKRecord(recordType: friendshipRecordType, recordID: CKRecord.ID(recordName: sampleFriendship.id))
        write(sampleFriendship, to: friendship)
        let limit = CKRecord(recordType: limitRecordType, recordID: CKRecord.ID(recordName: "schema_limit_sample"))
        write(sampleLimit, to: limit)
        let request = CKRecord(recordType: timeRequestRecordType, recordID: CKRecord.ID(recordName: "schema_request_sample"))
        write(sampleRequest, to: request)
        let profile = CKRecord(recordType: profileRecordType, recordID: CKRecord.ID(recordName: publicUserRecordName(for: sampleFriendID)))
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

    private func afterSignIn() async {
        await saveUserProfileToCloud()
        await refreshAll()
    }

    private func configureNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        await saveTimeRequestSubscription()
    }

    private func saveTimeRequestSubscription() async {
        guard !currentAppUserID.isEmpty else { return }
        let predicate = NSPredicate(format: "ANY approverIDs == %@ AND status == %@", currentAppUserID, TimeRequestStatus.open.rawValue)
        let subscription = CKQuerySubscription(
            recordType: timeRequestRecordType,
            predicate: predicate,
            subscriptionID: "time_requests_\(currentAppUserID)",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate]
        )
        let info = CKSubscription.NotificationInfo()
        info.title = "bound"
        info.alertBody = "A friend requested more time."
        info.soundName = "default"
        info.shouldBadge = true
        subscription.notificationInfo = info
        _ = try? await publicDatabase.save(subscription)
    }

    private func notifyLimitApprovers(_ limit: AppLimitPolicy) async {
        // CloudKit subscriptions deliver future request notifications. A true "new limit" push for every selected
        // friend needs a separate notification event record or an app server.
        infoMessage = "Limit saved. Selected friends can now approve requests for it."
    }

    private func removeNotification(for request: AppTimeRequest) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [request.notificationIdentifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [request.notificationIdentifier])
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

    private func loadFriends() async {
        guard !currentAppUserID.isEmpty, !isDeveloperSession else { return }
        let query = CKQuery(recordType: friendshipRecordType, predicate: NSPredicate(format: "ANY userIDs == %@", currentAppUserID))
        do {
            let (results, _) = try await publicDatabase.records(matching: query)
            friends = results.compactMap { result in
                guard case .success(let record) = result.1,
                      let connection = readFriendship(from: record) else { return nil }
                return connection.friend(for: currentAppUserID)
            }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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
            limits = results.compactMap { result in
                guard case .success(let record) = result.1 else { return nil }
                return readLimit(from: record)
            }
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
            incomingRequests = results.compactMap { result in
                guard case .success(let record) = result.1 else { return nil }
                return readTimeRequest(from: record)
            }
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
            ownRequests = results.compactMap { result in
                guard case .success(let record) = result.1 else { return nil }
                return readTimeRequest(from: record)
            }
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
    }

    private func fetchPublicProfile(appUserID: String) async throws -> FriendProfile? {
        let record = try await publicDatabase.record(for: CKRecord.ID(recordName: publicUserRecordName(for: appUserID)))
        guard let id = record["appUserID"] as? String else { return nil }
        return FriendProfile(appUserID: id, displayName: record["displayName"] as? String ?? id)
    }

    private func hasOpenOwnRequest(for limitID: UUID) -> Bool {
        ownRequests.contains { $0.limitID == limitID && $0.status == .open }
    }

    private func updateLocalRequest(_ request: AppTimeRequest) {
        incomingRequests.removeAll { $0.id == request.id }
        incomingRequests.append(request)
        ownRequests.removeAll { $0.id == request.id }
        ownRequests.append(request)
    }

    private func write(_ connection: FriendConnection, to record: CKRecord) {
        record["userIDs"] = connection.userIDs as NSArray
        record["displayNamesData"] = try? JSONEncoder().encode(connection.displayNames) as NSData
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
        return FriendConnection(id: record.recordID.recordName, userIDs: userIDs, displayNames: displayNames, createdAt: createdAt)
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
        record["requesterID"] = request.requesterID as NSString
        record["requesterName"] = request.requesterName as NSString
        record["limitID"] = request.limitID.uuidString as NSString
        record["limitTitle"] = request.limitTitle as NSString
        record["approverIDs"] = request.approverIDs as NSArray
        record["requestedMinutes"] = request.requestedMinutes as NSNumber
        record["status"] = request.status.rawValue as NSString
        record["resolvedByID"] = request.resolvedByID as NSString?
        record["resolvedByName"] = request.resolvedByName as NSString?
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

    private func applyShielding(for limit: AppLimitPolicy?) {
        guard let limit, isAuthorized else {
            blockingStore.shield.applications = nil
            blockingStore.shield.webDomains = nil
            return
        }
        blockingStore.shield.applications = limit.selection.applicationTokens.isEmpty ? nil : limit.selection.applicationTokens
        blockingStore.shield.webDomains = limit.selection.webDomainTokens.isEmpty ? nil : limit.selection.webDomainTokens
    }

    private func friendshipID(_ first: String, _ second: String) -> String {
        "friendship_\([first, second].sorted().joined(separator: "_"))"
    }

    private func limitRecordName(_ id: UUID) -> String {
        "limit_\(id.uuidString)"
    }

    private func timeRequestRecordName(_ id: UUID) -> String {
        "time_request_\(id.uuidString)"
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
        encode(limits, key: localLimitsKey)
        encode(incomingRequests, key: localIncomingRequestsKey)
        encode(ownRequests, key: localOwnRequestsKey)
    }

    private func loadLocalState() {
        currentUserIdentifier = UserDefaults.standard.string(forKey: currentUserIdentifierKey)
        currentAppUserID = UserDefaults.standard.string(forKey: currentAppUserIDKey) ?? ""
        currentUserDisplayName = UserDefaults.standard.string(forKey: currentUserDisplayNameKey) ?? "Guest"
        isDeveloperSession = UserDefaults.standard.bool(forKey: isDeveloperSessionKey)
        isAuthenticated = currentUserIdentifier != nil
        loadLocalCollections()
    }

    private func loadLocalCollections() {
        friends = decode([FriendProfile].self, key: localFriendsKey) ?? friends
        limits = decode([AppLimitPolicy].self, key: localLimitsKey) ?? []
        incomingRequests = decode([AppTimeRequest].self, key: localIncomingRequestsKey) ?? []
        ownRequests = decode([AppTimeRequest].self, key: localOwnRequestsKey) ?? []
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
