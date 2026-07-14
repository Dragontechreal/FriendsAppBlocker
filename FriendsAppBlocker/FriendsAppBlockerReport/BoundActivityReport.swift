import DeviceActivity
import ExtensionKit
import SwiftUI

@main
struct BoundActivityReportExtension: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        BoundLimitUsageReport { configuration in
            BoundLimitUsageView(configuration: configuration)
        }
    }
}

extension DeviceActivityReport.Context {
    static let boundLimitUsage = Self("BoundLimitUsage")
}

struct BoundLimitUsageConfiguration {
    let usedSeconds: TimeInterval
    let totalMinutes: Int?

    var usedMinutes: Int {
        Int(usedSeconds / 60)
    }

    var remainingMinutes: Int? {
        guard let totalMinutes else { return nil }
        return max(0, totalMinutes - usedMinutes)
    }
}

nonisolated struct BoundLimitUsageReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .boundLimitUsage
    let content: (BoundLimitUsageConfiguration) -> BoundLimitUsageView
    private let usageMetadataSuiteName = "group.dev.supremezone.app.FriendsAppBlocker"
    private let usageTotalsBySelectionKey = "BoundUsageTotalsBySelection"
    private let usageTotalsByTokenKey = "BoundUsageTotalsByToken"

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> BoundLimitUsageConfiguration {
        var usedSeconds: TimeInterval = 0
        var tokenKeys: Set<String> = []

        for await activityData in data {
            for await segment in activityData.activitySegments {
                for await category in segment.categories {
                    for await application in category.applications {
                        usedSeconds += application.totalActivityDuration
                        if let token = application.application.token,
                           let tokenKey = encodedTokenKey(token) {
                            tokenKeys.insert("token:\(tokenKey)")
                        }
                    }
                    for await webDomain in category.webDomains {
                        usedSeconds += webDomain.totalActivityDuration
                        if let token = webDomain.webDomain.token,
                           let tokenKey = encodedTokenKey(token) {
                            tokenKeys.insert("token:\(tokenKey)")
                        }
                    }
                }
            }
        }

        return BoundLimitUsageConfiguration(usedSeconds: usedSeconds, totalMinutes: totalMinutes(for: tokenKeys))
    }

    private func totalMinutes(for tokenKeys: Set<String>) -> Int? {
        guard let defaults = UserDefaults(suiteName: usageMetadataSuiteName) else { return nil }
        if !tokenKeys.isEmpty {
            let selectionKey = tokenKeys.sorted().joined(separator: "|")
            if let totalsBySelection = defaults.dictionary(forKey: usageTotalsBySelectionKey) as? [String: Int],
               let total = totalsBySelection[selectionKey] {
                return total
            }
            if let totalsByToken = defaults.dictionary(forKey: usageTotalsByTokenKey) as? [String: Int] {
                let matchingTotals = Set(tokenKeys.compactMap { totalsByToken[$0] })
                if matchingTotals.count == 1 {
                    return matchingTotals.first
                }
            }
        }
        return nil
    }

    private func encodedTokenKey<T: Encodable>(_ token: T) -> String? {
        try? JSONEncoder().encode(token).base64EncodedString()
    }
}

struct BoundLimitUsageView: View {
    let configuration: BoundLimitUsageConfiguration

    var body: some View {
        HStack(spacing: 8) {
            if let remainingMinutes = configuration.remainingMinutes {
                Text("\(remainingMinutes)")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("min left today")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                Text("Calculating time left")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
