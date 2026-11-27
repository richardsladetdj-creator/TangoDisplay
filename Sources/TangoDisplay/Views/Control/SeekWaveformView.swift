import SwiftUI
import TangoDisplayCore

/// Waveform progress bar shown under the volume slider in the setlist window.
///
/// Two-step interaction to avoid accidental seeks during a milonga:
/// 1. First click arms the bar (highlighted border + tint). No seek happens.
/// 2. While armed, click or drag to scrub; releasing seeks to that point.
/// The bar disarms automatically after a few idle seconds, on track change,
/// or when the lock button is pressed.
struct SeekWaveformView: View {
    @ObservedObject var player: LocalPlayerSource
    @EnvironmentObject var appState: AppState

    @State private var waveform: WaveformLoader.WaveformData?
    @State private var isArmed = false
    @State private var scrubFraction: Double?
    @State private var hoverFraction: Double?
    @State private var disarmTask: Task<Void, Never>?

    private static let armTimeout: Duration = .seconds(6)
    private static let selectionColor = Color.yellow

    private var currentEntry: SetlistEntry? {
        guard let id = player.currentEntryID else { return nil }
        return appState.setlist.entries.first { $0.id == id }
    }

    /// Seeking is blocked while a fade runs — the fade owns the volume ramp and
    /// end-of-track transition, so jumping mid-fade would leave it inconsistent.
    private var canSeek: Bool {
        player.duration > 0 && currentEntry != nil && appState.fadeMode == .none
    }

    var body: some View {
        HStack(spacing: 6) {
            lockButton

            Text(formatTime(displayedSeconds))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(scrubFraction != nil ? Self.selectionColor : .secondary)
                .frame(width: 34, alignment: .trailing)

            GeometryReader { geo in
                waveformCanvas
                    .contentShape(Rectangle())
                    .gesture(seekGesture(width: geo.size.width))
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p) where isArmed:
                            hoverFraction = clampedFraction(p.x, width: geo.size.width)
                        default:
                            hoverFraction = nil
                        }
                    }
            }
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isArmed ? Self.selectionColor.opacity(0.10) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isArmed ? Self.selectionColor : Color.clear, lineWidth: 1.5)
            )
            .opacity(canSeek || waveform == nil ? 1 : 0.6)
            .help(isArmed ? "Click or drag to move playback" : "Click to select, then click or drag to seek")

            Text("-\(formatTime(max(0, player.duration - displayedSeconds)))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 38, alignment: .leading)
        }
        .animation(.easeInOut(duration: 0.15), value: isArmed)
        .task(id: currentEntry?.fileURL) {
            disarm()
            guard let url = currentEntry?.fileURL else {
                waveform = nil
                return
            }
            let data = await WaveformLoader.shared.load(url: url)
            guard !Task.isCancelled else { return }
            waveform = data
        }
        .onChange(of: canSeek) { allowed in
            if !allowed { disarm() }
        }
        .onDisappear { disarmTask?.cancel() }
    }

    // MARK: - Subviews

    private var lockButton: some View {
        Button {
            isArmed ? disarm() : arm()
        } label: {
            Image(systemName: isArmed ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 11))
                .foregroundColor(isArmed ? Self.selectionColor : .secondary)
                .frame(width: 14)
        }
        .buttonStyle(.plain)
        .disabled(!canSeek)
        .help(isArmed ? "Lock seek bar" : "Unlock seek bar")
    }

    private var waveformCanvas: some View {
        let duration = player.duration
        let progress = duration > 0 ? min(1, max(0, player.elapsed / duration)) : 0
        let trimStart = duration > 0 ? (currentEntry?.trimStartSeconds ?? 0) / duration : 0
        let trimEnd = duration > 0 ? (currentEntry?.trimEndSeconds ?? duration) / duration : 1
        let autoFade = autoFadeFraction
        let markPlayed = markPlayedFraction
        let playedColor: Color = currentEntry?.state == .paused ? .orange : ControlTheme.accent
        let samples = waveform?.samples ?? []
        let scrub = scrubFraction
        let hover = hoverFraction
        let armed = isArmed

        return Canvas { ctx, size in
            let midY = size.height / 2

            if samples.isEmpty {
                // No waveform (loading or unreadable): plain progress line.
                ctx.fill(Path(CGRect(x: 0, y: midY - 1.5, width: size.width, height: 3)),
                         with: .color(Color(nsColor: .separatorColor)))
                ctx.fill(Path(CGRect(x: 0, y: midY - 1.5, width: size.width * progress, height: 3)),
                         with: .color(playedColor))
            } else {
                let barWidth = size.width / CGFloat(samples.count)
                let playheadX = size.width * progress
                for (i, sample) in samples.enumerated() {
                    let x = CGFloat(i) * barWidth
                    let h = max(1.5, CGFloat(sample) * (size.height - 4))
                    let rect = CGRect(x: x, y: midY - h / 2, width: max(0.8, barWidth - 0.4), height: h)
                    let color = (x + barWidth / 2) < playheadX
                        ? playedColor
                        : Color.secondary.opacity(0.45)
                    ctx.fill(Path(rect), with: .color(color))
                }
            }

            // Trimmed-out regions dimmed.
            if trimStart > 0 {
                ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width * trimStart, height: size.height)),
                         with: .color(Color.black.opacity(0.35)))
            }
            if trimEnd < 1 {
                let x = size.width * trimEnd
                ctx.fill(Path(CGRect(x: x, y: 0, width: size.width - x, height: size.height)),
                         with: .color(Color.black.opacity(0.35)))
            }

            // "Mark as played after N seconds" threshold.
            if let markPlayed {
                ctx.fill(Path(CGRect(x: size.width * markPlayed - 1, y: 0, width: 2, height: size.height)),
                         with: .color(ControlTheme.accent.opacity(0.85)))
            }

            // Cortina auto-fade point.
            if let autoFade {
                ctx.fill(Path(CGRect(x: size.width * autoFade - 1, y: 0, width: 2, height: size.height)),
                         with: .color(Color.orange.opacity(0.85)))
            }

            // Playhead.
            ctx.fill(Path(CGRect(x: size.width * progress - 0.75, y: 0, width: 1.5, height: size.height)),
                     with: .color(.primary.opacity(0.9)))

            // Hover / scrub target.
            if armed, let target = scrub ?? hover {
                let x = size.width * target
                ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)),
                         with: .color(Self.selectionColor.opacity(scrub != nil ? 1 : 0.6)))
            }
        }
    }

    // MARK: - Interaction

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isArmed, canSeek else { return }
                disarmTask?.cancel()
                scrubFraction = clampedFraction(value.location.x, width: width)
            }
            .onEnded { value in
                guard canSeek else { return }
                guard isArmed else {
                    arm()
                    return
                }
                let fraction = clampedFraction(value.location.x, width: width)
                scrubFraction = nil
                appState.transportSeek(to: fraction * player.duration)
                scheduleDisarm()
            }
    }

    private func arm() {
        guard canSeek else { return }
        isArmed = true
        scheduleDisarm()
    }

    private func disarm() {
        disarmTask?.cancel()
        disarmTask = nil
        isArmed = false
        scrubFraction = nil
        hoverFraction = nil
    }

    private func scheduleDisarm() {
        disarmTask?.cancel()
        disarmTask = Task { @MainActor in
            try? await Task.sleep(for: Self.armTimeout)
            guard !Task.isCancelled else { return }
            disarm()
        }
    }

    // MARK: - Helpers

    private var displayedSeconds: Double {
        if let scrubFraction { return scrubFraction * player.duration }
        return player.elapsed
    }

    /// Shown until the track has been marked as played (setting off when marking at completion).
    private var markPlayedFraction: Double? {
        guard !appState.settings.markAsPlayedAfterCompletion,
              player.duration > 0,
              !player.isCurrentEntryMarkedAsPlayed else { return nil }
        return min(1, Double(appState.settings.markAsPlayedAfterSeconds) / player.duration)
    }

    /// Same delay rule the auto-fade scheduler uses, as a fraction of the track.
    private var autoFadeFraction: Double? {
        guard appState.settings.autoFadeCortinasEnabled,
              appState.displayState.mode == .cortina,
              currentEntry?.ignoresAutoFade != true,
              player.duration > 0 else { return nil }
        let fade = appState.settings.builtInFadeDuration
        let play = appState.settings.cortinaPlayTime
        let dur = player.duration
        if dur > play + fade { return play / dur }
        if dur > fade { return (dur - fade) / dur }
        return nil
    }

    private func clampedFraction(_ x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(1, max(0, Double(x / width)))
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
