import SwiftUI

/// The compact inline panel shown under the row (or routine) she just changed.
/// Rules broken: the reason, the closest time that works and one-tap fixes; "Keep anyway" is secondary.
/// Otherwise: what moves, then "Just today" / "Today and every …" / "Undo".
struct ScheduleChangePanel: View {
    /// Scroll target for a panel shown under a list row.
    static let scrollID = "schedule-change-panel"
    var change: ScheduleChange
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let notice = change.followOn {
                followOnLine(notice)
            }
            if change.needsDecision {
                problemContent
            } else {
                choiceContent
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(change.needsDecision ? Theme.coralSoft : Theme.blushSoft,
                    in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("schedule-change-panel")
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: change)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: change.needsDecision ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(change.needsDecision ? Theme.coralDeep : Theme.blushDeep)
            Text(title)
                .font(.bloom(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        if change.needsDecision {
            return change.problems.count == 1 ? "A rule can't be met" : "\(change.problems.count) rules can't be met"
        }
        switch change.kind {
        case .dose, .meal:
            if let t = change.subjectTime { return "\(change.subjectName) at \(ScheduleEngine.clock(t))" }
            return change.subjectName
        case .logged: return "\(change.subjectName) logged"
        case .routine: return "\(change.routineName) routine updated"
        case .review: return change.skips.isEmpty ? "Times updated" : "Plan for today"
        case .rule: return "\(change.subjectName) · new times"
        case .shift: return "Keep these times?"
        }
    }

    /// Tomorrow's dose already moved by itself (a gap rule across midnight): its own line, with Undo.
    private func followOnLine(_ notice: AutoMoveNotice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.rose)
            Text(notice.message)
                .font(.bloom(.footnote, weight: .semibold))
                .foregroundStyle(Theme.rose)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Undo") {
                Haptics.select()
                store.undoAutoMove(notice.id)
            }
            .font(.bloom(.footnote, weight: .semibold))
            .foregroundStyle(Theme.rose)
            .frame(minHeight: 32)
            .accessibilityIdentifier("change-followon-undo")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.roseTint, in: .rect(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("change-followon")
        .transition(.opacity)
    }

    // MARK: Rules broken

    @ViewBuilder
    private var problemContent: some View {
        ForEach(change.problems) { problem in
            Text(problem.reason)
                .font(.bloom(.subheadline))
                .foregroundStyle(Theme.coralDeep)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let s = change.suggestion {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(isLater(s) ? "Earliest" : "Latest") that works: \(ScheduleEngine.clock(s))")
                    .font(.bloom(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Button {
                    store.useSuggestion()
                } label: {
                    Text("Use \(ScheduleEngine.clock(s))")
                }
                .buttonStyle(BloomPrimaryButtonStyle())
                .accessibilityIdentifier("change-use-suggestion")
            }
        }
        let fixes = uniqueFixes
        if !fixes.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(fixes) { fix in
                    Button {
                        store.applyFix(fix)
                    } label: {
                        Label(fix.title, systemImage: icon(for: fix))
                            .font(.bloom(.subheadline, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(BloomSoftButtonStyle())
                    .accessibilityIdentifier("change-fix")
                }
            }
        }
        HStack {
            Button("Keep anyway") { store.keepAnyway() }
                .buttonStyle(BloomSoftButtonStyle(tint: Theme.textSecondary))
                .font(.bloom(.subheadline))
                .accessibilityIdentifier("change-keep")
            Spacer()
            Button(undoLabel) { store.discardChange() }
                .buttonStyle(BloomSoftButtonStyle())
                .accessibilityIdentifier("change-undo")
        }
    }

    private func isLater(_ suggestion: Int) -> Bool {
        guard let id = change.subjectID, let current = change.times[id] else { return true }
        return suggestion > current
    }

    /// The same fix can solve several problems; list it once.
    private var uniqueFixes: [ScheduleFix] {
        var seen = Set<String>()
        var result: [ScheduleFix] = []
        for fix in change.problems.flatMap(\.fixes) where !seen.contains(fix.title) {
            seen.insert(fix.title)
            result.append(fix)
        }
        return Array(result.prefix(3))
    }

    private func icon(for fix: ScheduleFix) -> String {
        switch fix.kind {
        case .move: "arrow.up.arrow.down"
        case .skip: "forward.end"
        case .retime(let tweak): tweak.bed != nil ? "moon" : tweak.wake != nil ? "sunrise" : "fork.knife"
        }
    }

    // MARK: Apply

    @ViewBuilder
    private var choiceContent: some View {
        if change.kept, !change.problems.isEmpty {
            Label("Keeping it with \(change.problems.count == 1 ? "a rule" : "rules") not met", systemImage: "exclamationmark.triangle.fill")
                .font(.bloom(.footnote, weight: .semibold))
                .foregroundStyle(Theme.coralDeep)
        }
        Text(change.summary)
            .font(.bloom(.subheadline))
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
        if change.kind == .rule {
            confirmToggle
        }
        if (change.kind != .routine && change.kind != .rule) || change.canApplyToday {
            Button {
                store.applyChange(.today)
            } label: {
                Text(change.isNextDay ? "Just tomorrow" : "Just today")
            }
            .buttonStyle(BloomPrimaryButtonStyle())
            .disabled(change.needsConfirmation)
            .opacity(change.needsConfirmation ? 0.5 : 1)
            .accessibilityIdentifier("change-today")
        }
        HStack {
            // A late dose moving tomorrow morning is a one-off: never offered as a new routine time.
            if !change.isNextDay {
                Button(forwardLabel) { store.applyChange(.forward) }
                    .buttonStyle(BloomSoftButtonStyle())
                    .font(.bloom(.subheadline, weight: .semibold))
                    .disabled(change.needsConfirmation)
                    .opacity(change.needsConfirmation ? 0.5 : 1)
                    .accessibilityIdentifier("change-forward")
            }
            Spacer()
            Button(undoLabel) { store.discardChange() }
                .buttonStyle(BloomSoftButtonStyle(tint: Theme.textSecondary))
                .accessibilityIdentifier("change-undo")
        }
    }

    /// Rules added or changed: she says they match what her doctor or pharmacist told her.
    private var confirmToggle: some View {
        Toggle(isOn: Binding(
            get: { store.scheduleChange?.confirmed ?? false },
            set: { on in
                store.scheduleChange?.confirmed = on
                Haptics.select()
            }
        )) {
            Text("Matches my doctor or pharmacist")
                .font(.bloom(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.text)
        }
        .tint(Theme.sageButton)
        .frame(minHeight: 44)
        .accessibilityIdentifier("change-confirm-rule")
    }

    private var forwardLabel: String {
        if change.kind == .routine || change.kind == .rule { return "Going forward" }
        return Self.everyLabel(change.routineName)
    }

    /// "Every day", or "Every weekday" when this routine only covers some days.
    static func everyLabel(_ routineName: String) -> String {
        let name = everyName(routineName)
        return name == "day" ? "Every day" : "Every \(name)"
    }

    private var undoLabel: String {
        switch change.kind {
        case .logged: "Keep other times"
        case .shift: "Put back"
        default: "Undo"
        }
    }

    /// "Weekdays" → "weekday", "Weekend" → "weekend day", "Every day" → "day".
    static func everyName(_ routineName: String) -> String {
        switch routineName {
        case "Weekdays": "weekday"
        case "Weekend": "weekend day"
        case "Every day": "day"
        default: "\(routineName) day"
        }
    }
}
