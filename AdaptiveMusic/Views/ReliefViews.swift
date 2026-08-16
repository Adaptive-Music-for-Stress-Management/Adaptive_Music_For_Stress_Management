import SwiftUI

/// Which relief option is open. Shared between the Relief card (buttons)
/// and the Meter card (where the relief UI actually renders).
final class ReliefState: ObservableObject {
    enum Mode { case karaoke, breathe, playAlong }
    @Published var mode: Mode? = nil
}

struct ReliefCard: View {
    @EnvironmentObject var relief: ReliefState
    @EnvironmentObject var engine: PersonalizeEngine
    @EnvironmentObject var breathe: BreatheController

    var body: some View {
        Card {
            CardTitle("Relief")
            HStack(spacing: 10) {
                reliefButton("Karaoke", .karaoke)
                reliefButton("Breathe", .breathe)
                reliefButton("Play-along", .playAlong)
            }
        }
    }

    private func reliefButton(_ label: String, _ mode: ReliefState.Mode) -> some View {
        let on = relief.mode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.35)) {
                relief.mode = on ? nil : mode
            }
            switch relief.mode {
            case .karaoke:  Task { await engine.startKaraoke() }
            case .breathe:  breathe.start()
            case .playAlong: break
            case nil:       break
            }
            if relief.mode != .breathe { breathe.stop() }
            if relief.mode != .karaoke { engine.stopKaraoke() }
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(on ? Theme.accent : Theme.line))
                .foregroundStyle(on ? Theme.accent : Theme.ink)
        }
        .buttonStyle(.plain)
    }
}

/// Renders inside the Meter card, below the horizontal meter.
struct ReliefStage: View {
    @EnvironmentObject var relief: ReliefState

    var body: some View {
        ZStack {
            switch relief.mode {
            case nil:
                Text("CHOOSE A RELIEF OPTION BELOW")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Theme.faint)
            case .karaoke:  KaraokeView().transition(.opacity)
            case .breathe:  BreatheView().transition(.opacity)
            case .playAlong: PlayAlongView().transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: relief.mode)
        .padding(10)
    }
}

// MARK: - Karaoke

struct KaraokeView: View {
    @EnvironmentObject var engine: PersonalizeEngine

    var body: some View {
        Group {
            if let msg = engine.karaokeMessage {
                Text(msg)
                    .font(.system(size: 14))
                    .foregroundStyle(StressLabel.stressed.color)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            } else if engine.karaokeBusy {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("finding instrumental & lyrics…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }
            } else if let pkg = engine.karaoke {
                LyricsScroller(lyrics: pkg.lyrics, positionMs: engine.positionMs)
            }
        }
    }
}

/// Spotify-style scrolling synced lyrics; pausing the song pauses the scroll
/// (position stops advancing).
struct LyricsScroller: View {
    let lyrics: [LyricLine]
    let positionMs: Int

    private var currentIndex: Int? {
        let synced = lyrics.filter { $0.ms >= 0 }
        guard !synced.isEmpty else { return nil }
        var idx: Int? = nil
        for (i, line) in lyrics.enumerated() where line.ms >= 0 && line.ms <= positionMs + 150 {
            idx = i
        }
        return idx
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    Spacer(minLength: 90)
                    ForEach(Array(lyrics.enumerated()), id: \.element.id) { i, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: line.ms >= 0 ? 16 : 13,
                                          weight: i == currentIndex ? .bold : .semibold))
                            .foregroundStyle(i == currentIndex ? Theme.ink :
                                             (currentIndex != nil && i < currentIndex!) ? Theme.muted : Theme.faint)
                            .multilineTextAlignment(.center)
                            .scaleEffect(i == currentIndex ? 1.05 : 1)
                            .id(i)
                    }
                    Spacer(minLength: 90)
                }
                .frame(maxWidth: .infinity)
            }
            .onChange(of: currentIndex) { _, idx in
                guard let idx else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(idx, anchor: .center) }
            }
        }
    }
}

// MARK: - Play-along

struct PlayAlongView: View {
    @State private var instrument: Instrument = .piano       // default to piano (always)
    private static let engine = InstrumentEngine()

    enum Instrument { case piano, drums }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                toggle("Piano", .piano)
                toggle("Drums", .drums)
            }
            if instrument == .piano {
                PianoView(engine: PlayAlongView.engine)
            } else {
                DrumsView(engine: PlayAlongView.engine)
            }
        }
    }

    private func toggle(_ label: String, _ which: Instrument) -> some View {
        Button(label) { withAnimation { instrument = which } }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 18).padding(.vertical, 7)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(instrument == which ? Theme.accent : Theme.line))
            .foregroundStyle(instrument == which ? Theme.accent : Theme.muted)
            .buttonStyle(.plain)
    }
}

/// One octave, tap to play. (The keyboard letters mirror the computer edition.)
struct PianoView: View {
    let engine: InstrumentEngine
    @State private var pressed: Set<Int> = []

    private let whites: [(midi: Int, label: String)] =
        [(60, "A"), (62, "S"), (64, "D"), (65, "F"), (67, "G"), (69, "H"), (71, "J")]
    private let blacks: [(midi: Int, label: String, after: Int)] =
        [(61, "W", 0), (63, "E", 1), (66, "T", 3), (68, "Y", 4), (70, "U", 5)]

    var body: some View {
        GeometryReader { geo in
            let whiteW = geo.size.width / 7
            ZStack(alignment: .topLeading) {
                HStack(spacing: 2) {
                    ForEach(whites, id: \.midi) { key in
                        keyView(midi: key.midi, label: key.label, white: true)
                    }
                }
                ForEach(blacks, id: \.midi) { key in
                    keyView(midi: key.midi, label: key.label, white: false)
                        .frame(width: whiteW * 0.62, height: geo.size.height * 0.58)
                        .offset(x: whiteW * CGFloat(key.after + 1) - whiteW * 0.31)
                }
            }
        }
        .frame(height: 190)
    }

    private func keyView(midi: Int, label: String, white: Bool) -> some View {
        Button {
            engine.playNote(midi: midi)
            pressed.insert(midi)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { pressed.remove(midi) }
        } label: {
            VStack {
                Spacer()
                Text(label)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(white ? Color(white: 0.35) : Theme.muted)
                    .padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(pressed.contains(midi) ? Theme.accent :
                        (white ? Color(white: 0.92) : Color(red: 0.08, green: 0.11, blue: 0.15)),
                        in: UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6))
            .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                .stroke(Theme.line))
        }
        .buttonStyle(.plain)
    }
}

/// Eight pads, tap to play.
struct DrumsView: View {
    let engine: InstrumentEngine
    @State private var pressed: Set<String> = []

    private let grid = [GridItem(.flexible()), GridItem(.flexible()),
                        GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        LazyVGrid(columns: grid, spacing: 8) {
            ForEach(InstrumentEngine.Drum.allCases) { drum in
                Button {
                    engine.playDrum(drum)
                    pressed.insert(drum.rawValue)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pressed.remove(drum.rawValue) }
                } label: {
                    Text(drum.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 74)
                        .background(pressed.contains(drum.rawValue) ? Theme.accent : Theme.panel,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                        .foregroundStyle(pressed.contains(drum.rawValue) ? Theme.bg : Theme.ink)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 170)
    }
}
