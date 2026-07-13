import DeviceActivity
import ManagedSettings

final class BoundDeviceActivityMonitor: DeviceActivityMonitor {
    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        guard event.rawValue == "limitReached" else { return }
        guard let eventConfiguration = DeviceActivityCenter().events(for: activity)[event] else { return }

        let store = ManagedSettingsStore(named: ManagedSettingsStore.Name(activity.rawValue))
        store.shield.applications = eventConfiguration.applications.isEmpty ? nil : eventConfiguration.applications
        store.shield.applicationCategories = eventConfiguration.categories.isEmpty ? nil : .specific(eventConfiguration.categories)
        store.shield.webDomains = eventConfiguration.webDomains.isEmpty ? nil : eventConfiguration.webDomains
        store.shield.webDomainCategories = eventConfiguration.categories.isEmpty ? nil : .specific(eventConfiguration.categories)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        let store = ManagedSettingsStore(named: ManagedSettingsStore.Name(activity.rawValue))
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.shield.webDomainCategories = nil
    }
}
