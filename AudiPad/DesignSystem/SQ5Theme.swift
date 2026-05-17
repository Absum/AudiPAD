import SwiftUI
import UIKit

enum SQ5Theme {
    static func applyGlobalAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(SQ5Colors.background)
        appearance.shadowColor = UIColor(SQ5Colors.border)

        appearance.stackedLayoutAppearance.normal.iconColor = UIColor(SQ5Colors.textTertiary)
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor(SQ5Colors.textTertiary)
        ]
        appearance.stackedLayoutAppearance.selected.iconColor = UIColor(SQ5Colors.accent)
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
            .foregroundColor: UIColor(SQ5Colors.accent)
        ]

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().tintColor = UIColor(SQ5Colors.accent)
        UITabBar.appearance().isTranslucent = false
    }
}
