import Foundation
import Combine
import FamilyControls
import DeviceActivity

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

struct FamilyState: Codable {
    var members: [FamilyMember] = []
    var activeInvite: FamilyInvitation?
    var timeRequests: [FamilyTimeRequest] = []
    var extraTimeMinutes: Int = 0
    var enrollmentStatus: EnrollmentStatus = .draft

    enum EnrollmentStatus: String, Codable {
        case draft
        case readyForReview
        case requiresMDM
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
    @Published var currentUserId: UUID?

    private let familyControlsEnabled = false

    private let isBlockingKey = "isBlocking"
    private let selectedAppsKey = "selectedApps"
    private let familyStateKey = "familyState"
    private let cloudFamilyStateKey = "sharedFamilyState"
    private let currentUserIdKey = "currentUserId"
    private let currentUserRoleKey = "currentUserRole"
    private let currentUserApprovedKey = "currentUserApprovedForAdmin"

    private init() {
        updateAuthorizationStatus()
        loadState()
    }

    private func updateAuthorizationStatus() {
        isAuthorized = false
    }

    var supportsFamilyControls: Bool {
        familyControlsEnabled
    }

    var canManageBlocking: Bool {
        currentUserRole == .owner || currentUserApprovedForAdmin
    }

    /// Placeholder authorization flow until Apple approval is available.
    func requestAuthorization() async throws {
        isAuthorized = false
    }

    func enableBlocking() {
        isBlocking = true
        familyState.enrollmentStatus = .readyForReview
        saveState()
    }

    func disableBlocking() {
        isBlocking = false
        saveState()
    }

    func toggleBlocking() {
        isBlocking.toggle()
        saveState()
    }

    func checkBlockingStatus() {
        isBlocking = false
    }

    var hasItemsToBlock: Bool {
        !selectedApps.applicationTokens.isEmpty || !selectedApps.webDomainTokens.isEmpty
    }

    var hasFamilyMembers: Bool {
        !familyState.members.isEmpty
    }

    func createInvitation(for name: String) -> FamilyInvitation? {
        if !familyState.members.contains(where: { $0.role == .owner }) {
            let owner = FamilyMember(
                id: UUID(),
                name: name.isEmpty ? "You" : name,
                role: .owner,
                permissions: [.blockApps, .grantTime],
                joinedAt: Date(),
                isApprovedForAdmin: true
            )
            familyState.members.append(owner)
            currentUserId = owner.id
        }

        let code = String(UUID().uuidString.prefix(6)).uppercased()
        let invite = FamilyInvitation(
            id: UUID(),
            code: code,
            ownerName: name.isEmpty ? "You" : name,
            permissions: [.blockApps, .grantTime],
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(7 * 24 * 60 * 60),
            note: "Use this code in the app to join the trusted circle."
        )

        familyState.activeInvite = invite
        currentUserRole = .owner
        currentUserApprovedForAdmin = true
        familyState.enrollmentStatus = .readyForReview
        saveState()
        return invite
    }

    func joinFamily(with code: String, memberName: String) -> Bool {
        guard let invite = familyState.activeInvite,
              invite.code.lowercased() == code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              invite.expiresAt > Date() else {
            return false
        }

        let member = FamilyMember(
            id: UUID(),
            name: memberName.isEmpty ? "Friend" : memberName,
            role: .member,
            permissions: invite.permissions,
            joinedAt: Date(),
            isApprovedForAdmin: false
        )

        if familyState.members.contains(where: { $0.id == member.id }) {
            saveState()
            return true
        }

        familyState.members.append(member)
        currentUserId = member.id
        currentUserRole = .member
        currentUserApprovedForAdmin = false
        familyState.enrollmentStatus = .readyForReview
        saveState()
        return true
    }

    func approveMember(_ member: FamilyMember) {
        guard currentUserRole == .owner else { return }

        if let index = familyState.members.firstIndex(where: { $0.id == member.id }) {
            familyState.members[index].isApprovedForAdmin = true
        }

        if currentUserId == member.id {
            currentUserApprovedForAdmin = true
        }

        saveState()
    }

    func requestExtraTime(minutes: Int, from member: FamilyMember) {
        let request = FamilyTimeRequest(
            id: UUID(),
            requestedBy: member,
            requestedMinutes: minutes,
            detail: "The owner wants to add extra focus time for the circle.",
            createdAt: Date()
        )

        familyState.timeRequests.append(request)
        saveState()
    }

    func respondToTimeRequest(_ request: FamilyTimeRequest, approved: Bool, minutes: Int) {
        if approved {
            familyState.extraTimeMinutes += minutes
        }

        familyState.timeRequests.removeAll { $0.id == request.id }
        saveState()
    }

    func grantExtraTime(minutes: Int) {
        familyState.extraTimeMinutes += minutes
        saveState()
    }

    func removeMember(_ member: FamilyMember) {
        guard currentUserRole == .owner else {
            return
        }

        familyState.members.removeAll { $0.id == member.id }
        saveState()
    }

    private func persistCurrentUserSession() {
        if let currentUserId,
           let encoded = try? JSONEncoder().encode(currentUserId) {
            UserDefaults.standard.set(encoded, forKey: currentUserIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: currentUserIdKey)
        }

        UserDefaults.standard.set(currentUserRole.rawValue, forKey: currentUserRoleKey)
        UserDefaults.standard.set(currentUserApprovedForAdmin, forKey: currentUserApprovedKey)
    }

    private func restoreCurrentUserSession() {
        if let encoded = UserDefaults.standard.data(forKey: currentUserIdKey),
           let decoded = try? JSONDecoder().decode(UUID.self, from: encoded) {
            currentUserId = decoded
        } else {
            currentUserId = nil
        }

        if let roleString = UserDefaults.standard.string(forKey: currentUserRoleKey) {
            currentUserRole = FamilyMember.Role(rawValue: roleString) ?? .owner
        }

        if UserDefaults.standard.object(forKey: currentUserApprovedKey) != nil {
            currentUserApprovedForAdmin = UserDefaults.standard.bool(forKey: currentUserApprovedKey)
        }

        if let currentUserId, let member = familyState.members.first(where: { $0.id == currentUserId }) {
            currentUserRole = member.role
            currentUserApprovedForAdmin = member.isApprovedForAdmin || currentUserRole == .owner
        } else if familyState.members.isEmpty {
            currentUserRole = .owner
            currentUserApprovedForAdmin = true
        }
    }

    func saveState() {
        UserDefaults.standard.set(isBlocking, forKey: isBlockingKey)

        if let encoded = try? JSONEncoder().encode(selectedApps) {
            UserDefaults.standard.set(encoded, forKey: selectedAppsKey)
        }

        if let encoded = try? JSONEncoder().encode(familyState) {
            UserDefaults.standard.set(encoded, forKey: familyStateKey)
        }

        persistCurrentUserSession()
    }

    func loadState() {
        isBlocking = UserDefaults.standard.bool(forKey: isBlockingKey)

        if let data = UserDefaults.standard.data(forKey: selectedAppsKey),
           let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            selectedApps = decoded
        }

        if let data = UserDefaults.standard.data(forKey: familyStateKey),
           let decoded = try? JSONDecoder().decode(FamilyState.self, from: data) {
            familyState = decoded
        }

        restoreCurrentUserSession()
        checkBlockingStatus()
    }
}
