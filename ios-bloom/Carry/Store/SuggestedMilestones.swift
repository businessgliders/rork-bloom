import Foundation

/// Typical prenatal milestones, offered as editable suggestions.
/// Labelled in the UI as "typical; your provider's schedule may differ."
enum SuggestedMilestones {
    struct Template {
        let key: String
        let title: String
        let type: MilestoneType
        let week: Int
        let window: String
        var isMarker: Bool = false
        let note: String
    }

    static let templates: [Template] = [
        Template(key: "first_visit", title: "First prenatal visit", type: .doctorVisit, week: 8, window: "~Wk 8",
                 note: "Often includes health history, blood tests and a chance to ask lots of questions."),
        Template(key: "dating_scan", title: "Dating scan", type: .scan, week: 9, window: "Wk 8–12",
                 note: "An early ultrasound that can confirm how far along you are."),
        Template(key: "nipt", title: "NIPT window opens", type: .test, week: 10, window: "Wk 10+",
                 note: "An optional screening blood test. Talk it through with your provider."),
        Template(key: "nt_scan", title: "NT scan", type: .scan, week: 12, window: "Wk 11–14",
                 note: "An optional nuchal translucency ultrasound, done between 11 and 14 weeks."),
        Template(key: "trimester_2", title: "Second trimester begins", type: .personal, week: 14, window: "Wk 14", isMarker: true,
                 note: "Hello, second trimester!"),
        Template(key: "anatomy_scan", title: "Anatomy scan", type: .scan, week: 20, window: "Wk 18–22",
                 note: "A detailed ultrasound that checks how your baby is developing."),
        Template(key: "glucose_test", title: "Glucose test", type: .test, week: 24, window: "Wk 24–28",
                 note: "A screening test for gestational diabetes."),
        Template(key: "tdap", title: "Tdap vaccine", type: .doctorVisit, week: 27, window: "Wk 27–36",
                 note: "Commonly offered between 27 and 36 weeks. Ask your provider."),
        Template(key: "trimester_3", title: "Third trimester begins", type: .personal, week: 28, window: "Wk 28", isMarker: true,
                 note: "The home stretch starts here."),
        Template(key: "gbs_swab", title: "GBS swab", type: .test, week: 36, window: "Wk 36–37",
                 note: "A quick group B strep test, usually at 36–37 weeks."),
        Template(key: "weekly_visits", title: "Weekly visits begin", type: .doctorVisit, week: 36, window: "From Wk 36",
                 note: "Many providers start seeing you every week from here."),
        Template(key: "full_term", title: "Full term", type: .personal, week: 39, window: "Wk 39", isMarker: true,
                 note: "Baby is considered full term."),
        Template(key: "due_date", title: "Due date", type: .personal, week: 40, window: "Wk 40", isMarker: true,
                 note: "Only a small share of babies arrive exactly on this day."),
    ]

    static func date(for template: Template, profile: PregnancyProfile) -> Date {
        if template.key == "due_date" { return profile.dueDate }
        return PregnancyMath.addDays(template.week * 7, to: profile.gestationStart)
    }

    static func make(for profile: PregnancyProfile) -> [Milestone] {
        templates.map { template in
            Milestone(
                title: template.title,
                type: template.type,
                date: date(for: template, profile: profile),
                notes: template.note,
                isSuggested: true,
                suggestionKey: template.key,
                windowLabel: template.window,
                isMarker: template.isMarker
            )
        }
    }
}
