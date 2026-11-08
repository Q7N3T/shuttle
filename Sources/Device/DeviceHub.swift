import Foundation

/// Несколько устройств сразу: у каждого физического устройства свой `DeviceService`
/// со своей очередью и своим драйвером. Телефон и Switch работают параллельно —
/// установка игры на Switch не мешает листать камеру телефона.
final class DeviceHub: @unchecked Sendable {
    static let shared = DeviceHub()

    struct Slot {
        /// «mtp:шина:номер», «adb», «mock:phone» — постоянен, пока устройство воткнуто.
        let id: String
        let service: DeviceService
    }

    private let queue = DispatchQueue(label: "shuttle.hub")
    private var services: [String: DeviceService] = [:]
    /// Для автотестов: набор сервисов задан заранее и не меняется.
    private let fixed: [Slot]?

    init(fixed: [Slot]? = nil) {
        self.fixed = fixed
    }

    /// Найти устройства: новым — завести сервис, пропавшим — закрыть.
    /// `scan: false` — шину не трогаем (идёт передача): только уже известные устройства.
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

    /// Включили или выключили ADB — пересобрать набор.
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
        // ADB — первым: быстрее MTP и умеет больше. Один телефон по ADB.
        if UserDefaults.standard.bool(forKey: "adbEnabled"), ADBDriver.isAvailable {
            if services["adb"] == nil { services["adb"] = DeviceService(drivers: [ADBDriver()]) }
            order.append("adb")
        } else if let s = services.removeValue(forKey: "adb") {
            s.runDetached { $0.release() }
        }
        // MTP — по сервису на каждое устройство на шине.
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
