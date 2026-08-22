import SwiftUI

/// The four modals — Graphs, Meter (with the Relief stage below the meter),
/// Relief options, Personalize — arranged for a phone: graphs up top in a
/// compact grid, then the meter column, then personalization.
struct DashboardView: View {
    @EnvironmentObject var hub: SignalHub
    @EnvironmentObject var account: SupabaseService
    @EnvironmentObject var camera: CameraPPGReader
    @EnvironmentObject var watch: WatchLink
    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ADAPTUNE").font(.headline).tracking(3)
                    Text("Tune your state. Find your calm.").font(.caption2).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button(saving ? "Saving…" : "End & save") { endSession() }
                    .font(.caption.weight(.semibold)).disabled(saving)
            }.padding(.horizontal, 16).padding(.vertical, 11).background(Theme.panel)
            ScrollView {
                VStack(spacing: 14) {
                    if let saveError { Text(saveError).font(.caption).foregroundStyle(StressLabel.stressed.color).frame(maxWidth: .infinity, alignment: .leading) }
                    GraphsCard()
                    MeterCard()
                    ReliefCard()
                    PersonalizeCard()
                }
                .padding(14)
            }
        }
        .background(Theme.bg)
    }

    private func endSession() {
        saving = true; saveError = nil
        Task {
            do {
                try await account.finishAndSave(hub: hub)
                camera.stop(); watch.endWorkoutSession()
            } catch { saveError = error.localizedDescription }
            saving = false
        }
    }
}

struct CardTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(3)
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            .hoverEffect(.lift)
    }
}
