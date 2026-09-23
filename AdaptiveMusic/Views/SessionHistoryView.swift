import SwiftUI

struct SessionHistoryView: View {
    @EnvironmentObject var claude: ClaudeService
    @EnvironmentObject var engine: PersonalizeEngine
    @EnvironmentObject var account: SupabaseService
    @EnvironmentObject var hub: SignalHub
    @State private var selected: SavedSession?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("YOUR DASHBOARD").font(.caption.monospaced()).tracking(3).foregroundStyle(Theme.accent)
                    Text("Past sessions").font(.system(size: 38, weight: .bold))
                    Text("Open a session to revisit every signal and your stress response over time.").foregroundStyle(Theme.muted)
                    Button("Start live session") { account.startLiveSession(hub: hub) }
                        .buttonStyle(PrimaryHistoryButton())
                    if account.sessions.isEmpty {
                        Text("No saved sessions yet. Start a live session to create one.")
                            .foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.vertical, 70)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, style: .init(dash: [6])))
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(account.sessions) { session in
                                Button { selected = session } label: { SessionRow(session: session) }
                                    .buttonStyle(.plain)
                                    .hoverEffect(.lift)
                            }
                        }
                    }
                }.padding(18)
            }
            .background(Theme.bg)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { VStack(alignment: .leading) { Text("ADAPTUNE").font(.headline).tracking(3); Text("Tune your state. Find your calm.").font(.caption2).foregroundStyle(Theme.muted) } }
                ToolbarItem(placement: .topBarTrailing) { Button("Sign out") { Task {
                    await engine.stopSessionAudio()
                    await engine.disconnectSpotify()
                    claude.removeKey()
                    await account.signOut()
                } }.font(.caption) }
            }
            .sheet(item: $selected) { SessionDetailView(session: $0) }
        }
    }
}

private struct SessionRow: View {
    let session: SavedSession
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(session.startDate.formatted(date: .long, time: .omitted)).font(.headline)
                Text(session.startDate.formatted(date: .omitted, time: .shortened)).foregroundStyle(Theme.muted)
            }
            Spacer()
            VStack(alignment: .trailing) { Text(session.avgStress.map { String(format: "%.1f", $0) } ?? "—").font(.title.monospaced().bold()).foregroundStyle(Theme.accent); Text("AVG STRESS").font(.caption2.monospaced()).foregroundStyle(Theme.muted) }
        }.padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }
}

struct SessionDetailView: View {
    @EnvironmentObject var account: SupabaseService
    @EnvironmentObject var claude: ClaudeService
    @Environment(\.dismiss) private var dismiss
    let session: SavedSession
    @State private var key = ""
    @State private var analysis = ""
    @State private var analysisError: String?
    @State private var analyzing = false
    @State private var consent = false
    private let channels = [("bpm","BPM"),("hrv_diff","HRV differential"),("right_brain","EEG right brain"),("left_brain","EEG left brain"),("right_ear","EEG right ear"),("left_ear","EEG left ear")]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(session.startDate.formatted(date: .complete, time: .shortened)).font(.caption.monospaced()).foregroundStyle(Theme.accent)
                    Text("Six live channels").font(.title2.bold())
                    ForEach(channels, id: \.0) { key, label in SavedGraphView(label: label, path: session.graphImages[key]) }
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Stress over time").font(.title2.bold())
                        StressHistoryChart(points: session.stressPoints).frame(height: 230)
                        Text("AVERAGE STRESS").font(.caption.monospaced()).foregroundStyle(Theme.muted)
                        Text(session.avgStress.map { String(format: "%.1f", $0) } ?? "—").font(.system(size: 48, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accent)
                        VStack(spacing: 12) {
                            Text("AI-generated wellness information may be inaccurate. It is not a diagnosis or medical advice.")
                                .font(.caption).foregroundStyle(Theme.muted)
                            Toggle("Send this session's relative timestamps, stress scores and average to Anthropic. No email or account ID is included. My API account will be charged.", isOn: $consent)
                                .font(.caption)
                            SecureField(claude.keySet ? "Use saved API key or enter a replacement" : "Anthropic API key (sk-ant-…)", text: $key)
                                .padding(11)
                                .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                            Button(analyzing ? "Analyzing…" : "Get AI analysis") { analyze() }
                                .buttonStyle(PrimaryHistoryButton())
                                .disabled(analyzing || claude.busy || !consent || (!claude.keySet && key.isEmpty))
                            if claude.keySet { Button("Remove API key") { claude.removeKey(); consent = false } }
                            Text("Keys are stored in iOS Keychain.").font(.caption).foregroundStyle(Theme.muted)
                        }
                        if !analysis.isEmpty { Text(analysis).foregroundStyle(Theme.muted).lineSpacing(4) }
                        if let analysisError { Text(analysisError).foregroundStyle(StressLabel.stressed.color).lineSpacing(4) }
                    }.padding(16).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                }.padding(16)
            }.background(Theme.bg).navigationTitle("Session details").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }

    private func analyze() {
        guard consent, !analyzing, !claude.busy else { return }
        if !key.isEmpty { claude.apiKey = key; key = "" }
        claude.analysisConsent = consent
        analyzing = true; analysis = ""; analysisError = nil
        Task {
            do { analysis = try await claude.analyzeSession(points: session.stressPoints, average: session.avgStress) }
            catch { analysisError = error.localizedDescription }
            analyzing = false
        }
    }
}

private struct SavedGraphView: View {
    @EnvironmentObject var account: SupabaseService
    let label: String
    let path: String?
    @State private var image: UIImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label.uppercased()).font(.caption.monospaced()).foregroundStyle(Theme.muted)
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Text(path == nil ? "NO READING FOR THIS SESSION" : "LOADING GRAPH…").font(.caption.monospaced()).foregroundStyle(Theme.faint).frame(maxWidth: .infinity, minHeight: 135) }
        }.padding(14).background(Theme.panel2, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line)).task(id: path) { if let path { image = try? await account.graphImage(path: path) } }
    }
}

private struct StressHistoryChart: View {
    let points: [StressPoint]
    var body: some View {
        ZStack {
            Canvas { context, size in
                for line in 1...3 {
                    var grid = Path(); let y = size.height * CGFloat(line) / 4
                    grid.move(to: .init(x: 0, y: y)); grid.addLine(to: .init(x: size.width, y: y))
                    context.stroke(grid, with: .color(Theme.line))
                }
                guard !points.isEmpty else { return }
                let maxX = max(1, points.map(\.x).max() ?? 1)
                let xPad: CGFloat = 8, yPad: CGFloat = 12
                let position: (StressPoint) -> CGPoint = { point in
                    CGPoint(
                        x: xPad + (size.width - xPad * 2) * CGFloat(max(0, point.x) / maxX),
                        y: yPad + (size.height - yPad * 2) * (1 - CGFloat(min(100, max(0, point.y)) / 100))
                    )
                }
                if points.count == 1 {
                    let point = position(points[0])
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(Theme.accent))
                    return
                }
                var line = Path()
                for (index, point) in points.enumerated() {
                    index == 0 ? line.move(to: position(point)) : line.addLine(to: position(point))
                }
                var area = line
                area.addLine(to: CGPoint(x: position(points.last!).x, y: size.height - yPad))
                area.addLine(to: CGPoint(x: position(points[0]).x, y: size.height - yPad))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(
                    Gradient(colors: [Theme.accent.opacity(0.24), Theme.accent.opacity(0)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(Theme.accent), lineWidth: 2.5)
            }
            if points.isEmpty {
                Text("NO STRESS READINGS FOR THIS SESSION")
                    .font(.caption.monospaced()).foregroundStyle(Theme.faint)
            }
        }
    }
}

private struct PrimaryHistoryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.font(.headline).foregroundStyle(Theme.bg).frame(maxWidth:.infinity).padding(.vertical,13).background(Theme.accent.opacity(configuration.isPressed ? 0.7 : 1),in:RoundedRectangle(cornerRadius:9)) }
}
