import SwiftUI

struct PlayerControlsView: View {
    @ObservedObject var player: LocalPlayerSource
    @EnvironmentObject var appState: AppState
    var onScrollToCurrentTrack: (() -> Void)? = nil

    @State private var holdPauseArmed = false
    @State private var holdPauseArmTask: Task<Void, Never>?
    private static let holdPauseButtonWidth: CGFloat = 44

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                LevelMeterView(meter: player.levelMeter)
                    .frame(maxHeight: .infinity)

                VStack(spacing: 10) {
                    trackInfo
                    transportButtons
                    fadeButtons
                }
                .frame(maxWidth: .infinity)

                artworkPanel
            }
            .fixedSize(horizontal: false, vertical: true)
            volumeRow
            SeekWaveformView(player: player)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(.easeInOut(duration: 0.2), value: appState.currentArtwork != nil)
    }

    // MARK: - Artwork panel

    @ViewBuilder
    private var artworkPanel: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.08)
            if let art = appState.currentArtwork {
                Image(nsImage: art)
                    .resizable()
                    .scaledToFill()
            } else if let url = Bundle.main.url(forResource: "SetlistLogo", withExtension: "png"),
                      let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: LevelMeterView.totalWidth, height: LevelMeterView.totalWidth)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Subviews

    private var trackInfo: some View {
        let track = appState.displayState.currentTrack
        return VStack(spacing: 3) {
            HStack(spacing: 8) {
                Text(track?.title ?? "No track loaded")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(track == nil ? .secondary : .primary)
                    .lineLimit(1)
                if track != nil,
                   appState.currentPlayerState == .playing || appState.currentPlayerState == .pauseArmed {
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
            Text(track?.artist ?? " ")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
            if !player.replayGainStatus.isEmpty {
                Text(player.replayGainStatus)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.75))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            if !player.audioUnitPluginStatus.isInert {
                Text(player.audioUnitPluginStatus.shortDisplayText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var transportButtons: some View {
        HStack(spacing: 10) {
            Spacer()
            // Mirrors the pause button so the main button stays centred.
            Color.clear.frame(width: Self.holdPauseButtonWidth, height: 1)
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
            holdPauseButton
            Spacer()
        }
        .onChange(of: player.isActivePlaying) { playing in
            if !playing { disarmHoldPause() }
        }
        .onDisappear { holdPauseArmTask?.cancel() }
    }

    // MARK: - Hold pause (pause in place, two presses to confirm)

    private var holdPauseButton: some View {
        let isHeld = player.isHeld
        let enabled = appState.fadeMode == .none && (isHeld || player.isActivePlaying)
        let (icon, color): (String, Color) = {
            if isHeld          { return ("pause.circle.fill", .orange) }
            if holdPauseArmed  { return ("pause.circle.fill", .red) }
            return ("pause.circle", .secondary)
        }()
        return Button {
            if isHeld {
                appState.transportResumeHeld()
            } else if holdPauseArmed {
                disarmHoldPause()
                appState.transportHoldPause()
            } else {
                armHoldPause()
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(color)
                .scaleEffect(holdPauseArmed ? 1.12 : 1)
                .animation(.easeInOut(duration: 0.15), value: holdPauseArmed)
        }
        .buttonStyle(.plain)
        .frame(width: Self.holdPauseButtonWidth)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(isHeld ? "Resume from paused position"
              : holdPauseArmed ? "Click again to pause"
              : "Pause in place (click twice)")
    }

    private func armHoldPause() {
        holdPauseArmed = true
        holdPauseArmTask?.cancel()
        holdPauseArmTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            holdPauseArmed = false
        }
    }

    private func disarmHoldPause() {
        holdPauseArmTask?.cancel()
        holdPauseArmTask = nil
        holdPauseArmed = false
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
        let autoFadeBlocksButtons: Bool = {
            guard appState.settings.autoFadeCortinasEnabled, isCortina else { return false }
            if appState.setlist.entries.first(where: { $0.id == player.currentEntryID })?.ignoresAutoFade == true { return false }
            let fade = appState.settings.builtInFadeDuration
            let play = appState.settings.cortinaPlayTime
            let dur = player.duration
            guard dur > 0 else { return true }
            let delay: Double
            if dur > play + fade      { delay = play }
            else if dur > fade        { delay = dur - fade }
            else                      { return true }
            return player.elapsed >= delay
        }()

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
            .disabled(mode == .fadeAndContinue || (mode == .none && (!isCortina || autoFadeBlocksButtons)))

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
            .disabled(mode == .fadeAndStop || (mode == .none && (!isCortina || autoFadeBlocksButtons)))
        }
    }

}
