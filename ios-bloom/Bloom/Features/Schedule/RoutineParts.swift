import SwiftUI

/// S M T W T F S. A day belongs to one routine; picking a day another routine has offers to move it.
struct DayChips: View {
    var days: Set<Int>
    var onTap: (Int) -> Void

    var body: some View {
        let symbols = PregnancyMath.calendar.veryShortWeekdaySymbols
        HStack(spacing: 6) {
            ForEach(ScheduleTemplate.orderedDays, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    onTap(day)
                } label: {
                    Text(symbols[day])
                        .font(.bloom(.subheadline, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .foregroundStyle(on ? .white : Theme.blushDeep)
                        .background(on ? Theme.roseButton : Theme.blushSoft, in: .circle)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(PregnancyMath.calendar.weekdaySymbols[day])
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("day-chip-\(day)")
            }
        }
    }
}

/// A rule a routine breaks: why, and one-tap fixes that keep every rule.
struct RuleProblemCard: View {
    var template: ScheduleTemplate
    var violation: RuleViolation
    @Environment(AppStore.self) private var store

    var body: some View {
        let fixes = store.templateFixes(template, for: violation)
        VStack(alignment: .leading, spacing: 8) {
            Label(store.templateBlockedReason(template, for: violation), systemImage: "exclamationmark.triangle.fill")
                .font(.bloom(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.coralDeep)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(fixes) { fix in
                Button {
                    store.applyTemplateFix(template.id, fix: fix)
                } label: {
                    Label(fix.title, systemImage: icon(for: fix))
                        .font(.bloom(.subheadline, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(BloomSoftButtonStyle())
                .accessibilityIdentifier("rule-fix")
            }
            if fixes.isEmpty {
                Text("Change a meal, wake or bedtime above to make room.")
                    .font(.bloom(.footnote))
                    .foregroundStyle(Theme.text)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.coralSoft, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private func icon(for fix: ScheduleFix) -> String {
        switch fix.kind {
        case .move: "arrow.up.arrow.down"
        case .skip: "forward.end"
        case .retime(let tweak): tweak.bed != nil ? "moon" : tweak.wake != nil ? "sunrise" : "fork.knife"
        }
    }
}
