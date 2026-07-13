import DeviceActivity
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

    var usedMinutes: Int {
        Int(usedSeconds / 60)
    }
}

struct BoundLimitUsageReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .boundLimitUsage
    let content: (BoundLimitUsageConfiguration) -> BoundLimitUsageView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> BoundLimitUsageConfiguration {
        var usedSeconds: TimeInterval = 0

        for await activityData in data {
            for await segment in activityData.activitySegments {
                usedSeconds += segment.totalActivityDuration
            }
        }

        return BoundLimitUsageConfiguration(usedSeconds: usedSeconds)
    }
}

struct BoundLimitUsageView: View {
    let configuration: BoundLimitUsageConfiguration

    var body: some View {
        HStack(spacing: 8) {
            Text("\(configuration.usedMinutes)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text("min used today")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
