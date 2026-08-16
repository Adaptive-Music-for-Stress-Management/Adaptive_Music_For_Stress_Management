import SwiftUI

/// Meter modal: the stress label (bigger than the title), the meter value under it
/// (smaller, status-colored), the horizontal calm → mild-stress → stressed meter,
/// and the empty card below the meter where the Relief UI renders.
struct MeterCard: View {
    @EnvironmentObject var hub: SignalHub
    @EnvironmentObject var engine: PersonalizeEngine
    @EnvironmentObject var relief: ReliefState

    var body: some View {
        Card {
            CardTitle("Meter")

            if hub.calibrating {
                Text("Calibrating")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.muted)
                Text(hub.calibrationLeft != nil ? "\(Int(hub.calibrationLeft!.rounded(.up)))s left" : "…")
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.muted)
            } else {
                Text(hub.stressLabel?.rawValue ?? "—")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(hub.stressLabel?.color ?? Theme.muted)
                    .animation(.easeInOut(duration: 0.4), value: hub.stressLabel)
                Text(hub.stress == nil ? "--" : String(format: "%.1f", hub.stress!))
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(hub.stressLabel?.color ?? Theme.muted)
            }

            meterBar
                .padding(.top, 4)

            HStack {
                Text("Calm").foregroundStyle(StressLabel.calm.color)
                Spacer()
                Text("Mild-stress").foregroundStyle(StressLabel.mild.color)
                Spacer()
                Text("Stressed").foregroundStyle(StressLabel.stressed.color)
            }
            .font(.system(size: 11, weight: .semibold))

            // the Relief UI renders in this card, below the horizontal meter
            ReliefStage()
                .frame(minHeight: 260)
                .frame(maxWidth: .infinity)
                .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                .padding(.top, 6)
        }
    }

    private var meterBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(LinearGradient(colors: [StressLabel.calm.color, StressLabel.calm.color,
                                                  StressLabel.mild.color, StressLabel.mild.color,
                                                  StressLabel.stressed.color, StressLabel.stressed.color],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 14)
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .frame(width: 4, height: 22)
                    .shadow(color: .white.opacity(0.8), radius: 5)
                    .offset(x: geo.size.width * CGFloat((hub.stress ?? 0) / 100) - 2)
                    .animation(.easeInOut(duration: 0.5), value: hub.stress)
            }
            .frame(height: 22)
        }
        .frame(height: 22)
    }
}
