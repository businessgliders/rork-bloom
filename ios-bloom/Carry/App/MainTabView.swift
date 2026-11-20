import SwiftUI

/// Top-level destinations. Add a case here to add a tab later.
enum AppTab: String, CaseIterable, Identifiable {
    case journey
    case timeline
    case meds

    var id: String { rawValue }

    var title: String {
        switch self {
        case .journey: "Journey"
        case .timeline: "Timeline"
        case .meds: "Meds"
        }
    }

    var symbol: String {
        switch self {
        case .journey: "camera.macro"
        case .timeline: "calendar.day.timeline.leading"
        case .meds: "pills.fill"
        }
    }

    @ViewBuilder
    var content: some View {
        switch self {
        case .journey: JourneyView()
        case .timeline: TimelineTabView()
        case .meds: MedsView()
        }
    }
}

struct MainTabView: View {
    @Environment(SyncEngine.self) private var sync
    @Environment(AppStore.self) private var store
    @State private var selection: AppTab = AppStore.shared.isTrackingPaused ? .meds : .journey

    /// Paused: only Meds is left. The Journey and Timeline tabs come back on resume.
    private var visibleTabs: [AppTab] { store.isTrackingPaused ? [.meds] : AppTab.allCases }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(visibleTabs) { tab in
                tab.content
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
        // Pause flips from Settings or the other phone: move off a tab that just went away.
        .onChange(of: store.isTrackingPaused) { _, paused in
            if paused && selection != .meds { selection = .meds }
        }
        // carry://meds from a widget, the Live Activity or a notification.
        .onChange(of: DeepLinkRouter.shared.medsRequest) { _, _ in selection = .meds }
        .onAppear { if DeepLinkRouter.shared.pendingMeds { selection = .meds } }
        // Invite code after starting, or "You're in" after joining.
        .sheet(item: Binding(get: { sync.welcome }, set: { sync.welcome = $0 })) { welcome in
            WelcomeSheetView(welcome: welcome)
        }
        // She left Meds today with "Shift my day" not saved.
        .confirmationDialog(shiftQuestion, isPresented: Binding(
            get: { store.shiftNeedsAnswer && store.scheduleChange?.kind == .shift },
            set: { if !$0 { store.shiftNeedsAnswer = false } }
        ), titleVisibility: .visible) {
            if let change = store.scheduleChange, change.kind == .shift {
                Button("Just today") { answerShift(.today) }
                Button(ScheduleChangePanel.everyLabel(change.routineName)) { answerShift(.forward) }
                // Not the cancel role: iOS hides that one in this dialog, and she should see the way back.
                Button("Put times back") {
                    store.shiftNeedsAnswer = false
                    store.discardChange()
                }
            }
        } message: {
            if let problem = store.scheduleChange?.problems.first {
                Text(problem.reason)
            }
        }
    }

    private var shiftQuestion: String {
        guard let change = store.scheduleChange, change.kind == .shift else { return "" }
        let amount = ScheduleEngine.duration(abs(change.shift))
        return "Keep everything \(amount) \(change.shift > 0 ? "later" : "earlier")?"
    }

    private func answerShift(_ scope: ScheduleChange.Scope) {
        store.shiftNeedsAnswer = false
        store.scheduleChange?.kept = true
        store.applyChange(scope)
    }
}
