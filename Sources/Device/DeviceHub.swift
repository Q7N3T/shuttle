import Foundation

/// Several devices at once: every physical device gets its own `DeviceService`
/// with its own queue and driver. Phone and Switch work in parallel —
/// installing a game on the Switch doesn't block browsing the phone's camera.
final class DeviceHub: @unchecked Sendable {
    static let shared = DeviceHub()

    struct Slot {
        /// "mtp:bus:number", "adb", "mock:phone" — stays the same while the device is plugged in.
        let id: String
        let service: DeviceService
    }

    private let queue = DispatchQueue(label: "shuttle.hub")
    private var services: [String: DeviceService] = [:]
    /// For tests: the set of services is fixed in advance and never changes.
    private let fixed: [Slot]?

    init(fixed: [Slot]? = nil) {
        self.fixed = fixed
    }

    /// Find devices: create a service for new ones, close the ones that are gone.
    /// `scan: false` — don't touch the bus (a transfer is running): only already known devices.
    func refresh(scan: Bool = true) async -> [Slot] {
        if let fixed { return fixed }
        return await withCheckedContinuation { c in
            queue.async { c.resume(returning: scan ? self.refreshSync() : self.known()) }
        }
    }

    private func known() -> [Slot] {
        services.keys.sorted { a, b in a == "adb" ? true : (b == "adb" ? false : a < b) }
            .compactMap { id in services[id].map { Slot(id: id, service: $0) } }
    }

    /// ADB was turned on or off — rebuild the set.
    func reload() {
        queue.async {
            for s in self.services.values { s.runDetached { $0.release() } }
            self.services = [:]
        }
    }

    private func refreshSync() -> [Slot] {
        var order: [String] = []
        #if DEBUG
        if let kinds = MockDriver.requestedKinds {
            for k in kinds {
                let id = "mock:\(k.rawValue)"
                if services[id] == nil { services[id] = DeviceService(drivers: [MockDriver(kind: k)]) }
                order.append(id)
            }
            return order.compactMap { id in services[id].map { Slot(id: id, service: $0) } }
        }
        #endif
        // ADB first: faster than MTP and can do more. One phone over ADB.
        if UserDefaults.standard.bool(forKey: "adbEnabled"), ADBDriver.isAvailable {
            if services["adb"] == nil { services["adb"] = DeviceService(drivers: [ADBDriver()]) }
            order.append("adb")
        } else if let s = services.removeValue(forKey: "adb") {
            s.runDetached { $0.release() }
        }
        // MTP — one service per device on the bus.
        let raws = MTPDriver.detect()
        let present = Set(raws.map(\.slot))
        for (id, s) in services where id.hasPrefix("mtp:") && !present.contains(id) {
            s.runDetached { $0.release() }
            services[id] = nil
        }
        for r in raws.sorted(by: { ($0.bus, $0.devnum) < ($1.bus, $1.devnum) }) {
            if services[r.slot] == nil { services[r.slot] = DeviceService(drivers: [MTPDriver(target: r)]) }
            order.append(r.slot)
        }
        return order.compactMap { id in services[id].map { Slot(id: id, service: $0) } }
    }
}
