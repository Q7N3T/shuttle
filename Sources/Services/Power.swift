import Foundation
import IOKit.ps

/// Whether the Mac runs on battery. A Switch connected to a Mac on battery often isn't seen,
/// or starts charging the Mac instead — so the app suggests plugging the charger in.
@MainActor
final class PowerSource: ObservableObject {
    static let shared = PowerSource()
    @Published private(set) var onBattery = false

    private init() {
        update()
        // macOS calls back whenever the power source changes: charger in or out.
        if let src = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in PowerSource.shared.update() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    #if DEBUG
    /// Snapshots: draw the "on battery" state on any Mac.
    func pretendBattery() { onBattery = true }
    #endif

    func update() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String
        let now = type == kIOPSBatteryPowerValue
        if now != onBattery { onBattery = now }
    }
}
