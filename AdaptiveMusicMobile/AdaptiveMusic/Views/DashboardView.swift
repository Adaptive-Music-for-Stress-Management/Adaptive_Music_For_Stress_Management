import SwiftUI

/// The four modals — Graphs, Meter (with the Relief stage below the meter),
/// Relief options, Personalize — arranged for a phone: graphs up top in a
/// compact grid, then the meter column, then personalization.
struct DashboardView: View {
    @EnvironmentObject var hub: SignalHub

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                GraphsCard()
                MeterCard()
                ReliefCard()
                PersonalizeCard()
            }
            .padding(14)
        }
        .background(Theme.bg)
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
    }
}
