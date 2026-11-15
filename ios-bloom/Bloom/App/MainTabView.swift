import SwiftUI

/// Top-level destinations. Add a case here to add a tab later.
enum AppTab: String, CaseIterable, Identifiable {
    case journey
    case meds

    var id: String { rawValue }

    var title: String {
        switch self {
        case .journey: "Journey"
        case .meds: "Meds"
        }
    }

    var symbol: String {
        switch self {
        case .journey: "camera.macro"
        case .meds: "pills.fill"
        }
    }

    @ViewBuilder
    var content: some View {
        switch self {
        case .journey: JourneyView()
        case .meds: MedsView()
        }
    }
}

struct MainTabView: View {
    @Environment(SyncEngine.self) private var sync
    @State private var selection: AppTab = .journey

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                tab.content
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
        // Invite code after starting, or "You're in" after joining.
        .sheet(item: Binding(get: { sync.welcome }, set: { sync.welcome = $0 })) { welcome in
            WelcomeSheetView(welcome: welcome)
        }
    }
}
