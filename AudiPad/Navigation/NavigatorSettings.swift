import Foundation

/// Shared `@AppStorage` keys for navigator-tab preferences. Lives in a
/// single namespace so the writer (Settings → Navigator section) and
/// the readers (`MapTabView` gauges) can't drift apart.
///
/// Defaults: both gauges are on. The `@AppStorage` consumers declare
/// the matching `true` default in their property wrappers.
enum NavigatorSettings {
    /// Whether the stylised speedometer card shows on the Map tab.
    static let showSpeedometerKey = "audipad.nav.showSpeedometer"
    /// Whether the vertical boost gauge card shows on the Map tab.
    static let showBoostGaugeKey = "audipad.nav.showBoostGauge"
}
