import SwiftUI

/// Six compact graphs: BPM and HRV differential sampled per heartbeat, plus the four
/// EEG channels — which stay blank on mobile (no Muse input on this device), exactly
/// as the spec asks. Every graph's current-value number glows on each BPM reading.
struct GraphsCard: View {
    @EnvironmentObject var hub: SignalHub

    var body: some View {
        Card {
            CardTitle("Graphs")
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    GraphTile(name: "BPM", color: Theme.cBPM,
                              series: hub.bpmHistory, value: hub.beatFresh ? hub.bpm : nil, decimals: 0)
                    GraphTile(name: "HRV DIFF · ms", color: Theme.cHRV,
                              series: hub.hrvHistory, value: hub.beatFresh ? hub.hrvDiff : nil, decimals: 0)
                }
                HStack(spacing: 8) {
                    GraphTile(name: "EEG RIGHT BRAIN · µV", color: Theme.cRB, series: [], value: nil, decimals: 1)
                    GraphTile(name: "EEG LEFT BRAIN · µV", color: Theme.cLB, series: [], value: nil, decimals: 1)
                }
                HStack(spacing: 8) {
                    GraphTile(name: "EEG RIGHT EAR · µV", color: Theme.cRE, series: [], value: nil, decimals: 1)
                    GraphTile(name: "EEG LEFT EAR · µV", color: Theme.cLE, series: [], value: nil, decimals: 1)
                }
            }
        }
    }
}

struct GraphTile: View {
    @EnvironmentObject var hub: SignalHub
    let name: String
    let color: Color
    let series: [Double]
    let value: Double?
    let decimals: Int

    @State private var glow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(name)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Spacer()
                Text(value == nil ? "--" : String(format: "%.\(decimals)f", value!))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
                    .shadow(color: glow ? color : .clear, radius: glow ? 7 : 0)
            }
            plot
                .frame(height: 44)
        }
        .padding(8)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        .onChange(of: hub.beatSeq) { _, _ in                     // glow on every BPM reading
            withAnimation(.easeOut(duration: 0.1)) { glow = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(.easeOut(duration: 0.3)) { glow = false }
            }
        }
    }

    private var plot: some View {
        Canvas { ctx, size in
            // recessive grid
            var grid = Path()
            for i in 1...3 {
                let y = size.height * CGFloat(i) / 4
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(grid, with: .color(Theme.line.opacity(0.6)), lineWidth: 1)
            guard series.count > 1 else { return }               // blank graph with no reading
            var lo = series.min()!, hi = series.max()!
            if hi - lo < 1e-6 { lo -= 1; hi += 1 }
            let pad = (hi - lo) * 0.12; lo -= pad; hi += pad
            var path = Path()
            let n = SignalHub.maxPoints
            for (i, v) in series.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(n - 1)
                let y = size.height * (1 - CGFloat((v - lo) / (hi - lo)))
                i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
    }
}
