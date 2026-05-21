import SwiftUI
import UIKit
import Combine

/// Keeps the iPad's screen awake while AudiPad is foregrounded AND the
/// device is plugged in. The "plugged in" gate matters because the iPad
/// is permanently mounted in the car — power is only present while the
/// ignition / accessory line is live, so the screen sleeps naturally
/// once the car is off and the iPad is unplugged. Without this, iOS's
/// auto-lock would dim the dashboard mid-drive.
@MainActor
final class ScreenWakeService: ObservableObject {
    /// Last computed wake decision. Published mainly for the Settings
    /// status panel — the underlying side effect is the
    /// `isIdleTimerDisabled` toggle below.
    @Published private(set) var isHoldingAwake: Bool = false

    private var scenePhase: ScenePhase = .background
    private var observers: [NSObjectProtocol] = []

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reevaluate() }
        })
    }

    deinit {
        let nc = NotificationCenter.default
        for o in observers { nc.removeObserver(o) }
    }

    /// Driven from the App's `.onChange(of: scenePhase)`. We deliberately
    /// drop the wake lock when backgrounded so a forgotten "open" app
    /// can't keep the screen on after the user has switched apps.
    func update(scenePhase: ScenePhase) {
        self.scenePhase = scenePhase
        reevaluate()
    }

    private func reevaluate() {
        let plugged: Bool
        switch UIDevice.current.batteryState {
        case .charging, .full: plugged = true
        case .unplugged, .unknown: plugged = false
        @unknown default: plugged = false
        }
        let shouldHold = scenePhase == .active && plugged
        guard shouldHold != isHoldingAwake else { return }
        isHoldingAwake = shouldHold
        UIApplication.shared.isIdleTimerDisabled = shouldHold
    }
}
