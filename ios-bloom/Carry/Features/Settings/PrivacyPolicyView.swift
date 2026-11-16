import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    private let sections: [(String, String)] = [
        ("What Carry stores",
         "Names you enter, your pregnancy dates, milestones, notes and photos you add, and your medications and dose logs. If you don't sign in, everything stays on this device."),
        ("When you sign in to share",
         "Signing in (with Apple or email) lets you share one pregnancy with your partner. Then your account email and name, the pregnancy's names and dates, milestones, medications (name, schedule, food timing, notes, who takes it), who logged each dose and when, and photos you add are stored in Carry's database and private photo storage, hosted by Supabase. Only you and your partner can read them. A copy is also kept on each phone so Carry works offline."),
        ("Live Activities and alerts",
         "To keep the Live Activity and partner alerts in sync, Carry saves your phone's Apple push tokens with your account. They are used only to send pushes through Apple's push service, and partner-alert tokens are saved only while partner alerts are on."),
        ("How it's used",
         "Only to show you your pregnancy timeline, weekly content, reminders and your shared day. Carry never uses your health information for analytics, advertising or marketing, and never sells it."),
        ("Medication lookup",
         "Only if you allow it: the medication name or sentence you typed, or the label text you reviewed after a scan, is sent to Rork's AI service, which passes it through Vercel AI Gateway to Google Gemini to fill in the medication and general timing and food information. The lines you write in Meds & routines are sent one at a time, with the names of your medications, to DeepSeek (or Anthropic Claude as a backup) through the same gateway, only to read them as medications and timing rules. Label scans are read on your iPhone; the photo itself is never sent, and lines like your name, address, Rx number, pharmacy and doctor are removed first. Carry never suggests doses or strengths. Nothing is saved unless you confirm it, and you can turn this off in Settings."),
        ("Your choices",
         "You can edit or delete anything at any time and export your data. In Settings you can leave a shared pregnancy, sign out (your data stays on this phone), or delete your account, which removes your account, your tokens and your medications from the server. A pregnancy is deleted from the server once nobody is left in it."),
        ("Not medical advice",
         "Carry offers general information only. It is not a medical device and does not replace your doctor, midwife or pharmacist."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(sections, id: \.0) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.0)
                            .font(.bloom(.headline, weight: .bold))
                            .foregroundStyle(Theme.text)
                        Text(section.1)
                            .font(.bloom(.body))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .bloomCard(padding: 18)
                }
            }
            .padding(20)
        }
        .background(BloomBackground())
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
