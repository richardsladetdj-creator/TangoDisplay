import SwiftUI

struct PlayerControlsView: View {
    @ObservedObject var player: LocalPlayerSource
    @EnvironmentObject var appState: AppState
    var onScrollToCurrentTrack: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            trackInfo
            transportButtons
            fadeButtons
            seekBar
            volumeRow
        }
        .overlay(alignment: .topTrailing) {
            if let art = appState.currentArtwork {
                Image(nsImage: art)
                    .resizable()
                    .scaledToFit()
                    .frame(width: artworkSize, height: artworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(.easeInOut(duration: 0.2), value: appState.currentArtwork != nil)
    }

    // MARK: - Subviews

    private let artworkSize: CGFloat = 70

    private var trackInfo: some View {
        VStack(spacing: 3) {
            if let track = appState.displayState.currentTrack {
                HStack(spacing: 8) {
                    Text(track.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if appState.currentPlayerState == .playing || appState.currentPlayerState == .pauseArmed {
                        Button {
                            onScrollToCurrentTrack?()
                        } label: {
                            Image(systemName: "eye")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Scroll setlist to current track")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                Text(track.artist)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Text("No track loaded")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var transportButtons: some View {
        Button {
            switch appState.currentPlayerState {
            case .playing, .pauseArmed: appState.transportPause()
            case .paused, .stopped:     appState.transportPlay()
            }
        } label: {
            let (icon, color): (String, Color) = {
                switch appState.currentPlayerState {
                case .stopped:    return ("play.circle.fill",  ControlTheme.accent)
                case .playing:    return ("stop.circle.fill",  ControlTheme.accent)
                case .pauseArmed: return ("stop.circle.fill",  .red)
                case .paused:     return ("play.circle.fill",  .orange)
                }
            }()
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(color)
        }
        .buttonStyle(.plain)
    }

    private var seekBar: some View {
        VStack(spacing: 3) {
            Slider(
                value: Binding(
                    get: { player.elapsed },
                    set: { appState.transportSeek(to: $0) }
                ),
                in: 0...max(player.duration, 1)
            )
            .allowsHitTesting(false)
            .overlay {
                // GeometryReader in overlay is layout-neutral — never resizes the slider
                GeometryReader { geo in
                    let shouldShow = !appState.settings.markAsPlayedAfterCompletion
                        && player.duration > 0
                        && !player.isCurrentEntryMarkedAsPlayed
                    let fraction = min(1.0, Double(appState.settings.markAsPlayedAfterSeconds) / player.duration)
                    // macOS slider track has ~10pt inset on each side
                    let x = 10 + fraction * (geo.size.width - 20)
                    Rectangle()
                        .fill(ControlTheme.accent.opacity(0.7))
                        .frame(width: 2, height: 10)
                        .position(x: x, y: geo.size.height / 2)
                        .opacity(shouldShow ? 1 : 0)
                }
                .allowsHitTesting(false)
            }
            HStack {
                Text(formatTime(player.elapsed))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text("-\(formatTime(max(0, player.duration - player.elapsed)))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var volumeRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Slider(
                value: Binding(
                    get: { Double(player.volume) },
                    set: { appState.syncVolume(Float($0)) }
                ),
                in: 0...1
            )
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Fade buttons

    private var fadeButtons: some View {
        let isCortina = appState.displayState.mode == .cortina
        let mode = appState.fadeMode

        return HStack(spacing: 10) {
            Button {
                appState.transportFadeAndStop()
            } label: {
                Label(
                    mode == .fadeAndStop ? "Cancel" : "Fade & Stop",
                    systemImage: mode == .fadeAndStop ? "xmark.circle.fill" : "speaker.slash.fill"
                )
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(mode == .fadeAndStop ? .red : nil)
            .disabled(mode == .fadeAndContinue || (mode == .none && !isCortina))

            Button {
                appState.transportFadeAndContinue()
            } label: {
                Label(
                    mode == .fadeAndContinue ? "Cancel" : "Fade & Next",
                    systemImage: mode == .fadeAndContinue ? "xmark.circle.fill" : "speaker.wave.1"
                )
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(mode == .fadeAndContinue ? .red : nil)
            .disabled(mode == .fadeAndStop || (mode == .none && !isCortina))
        }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
