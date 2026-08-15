import AppKit
import SwiftUI

internal struct MiniPlayerControlButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .bold))

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white.opacity(isHovering ? 1 : 0.92))
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.white.opacity(isHovering ? 0.06 : 0.025))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonTreatment(.content)
        .onHover { isHovering = $0 }
        .help(title)
    }
}

internal struct MiniPlayerSeekButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(Color.white.opacity(isHovering ? 1 : 0.92))
                .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                .frame(width: 52, height: 64)
                .contentShape(Rectangle())
        }
        .buttonTreatment(.content)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

internal struct MiniPlayerPlayPauseButton: View {
    let isPlaying: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                HStack(spacing: 13) {
                    Capsule(style: .continuous)
                        .frame(width: 10, height: 58)
                    Capsule(style: .continuous)
                        .frame(width: 10, height: 58)
                }
                .opacity(isPlaying ? 1 : 0)
                .scaleEffect(isPlaying ? 1 : 0.72)

                Image(systemName: "play.fill")
                    .font(.system(size: 48, weight: .regular))
                    .opacity(isPlaying ? 0 : 1)
                    .scaleEffect(isPlaying ? 0.72 : 1)
            }
            .foregroundStyle(Color.white.opacity(isHovering ? 1 : 0.94))
            .shadow(color: .black.opacity(0.4), radius: 5, y: 1)
            .frame(width: 64, height: 64)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.30, dampingFraction: 0.78), value: isPlaying)
        }
        .buttonTreatment(.content)
        .onHover { isHovering = $0 }
        .help(isPlaying ? "Pause" : "Play")
    }
}

internal struct MiniPlayerProgressBar: View {
    let currentTime: Double
    let duration: Double
    let onSeek: (Double) -> Void
    let onScrubbingChanged: (Bool) -> Void

    @State private var isHovering = false
    @State private var isScrubbing = false
    @State private var scrubbedTime: Double?

    private var progress: CGFloat {
        guard duration > 0, displayedTime.isFinite, duration.isFinite else { return 0 }
        return CGFloat(min(max(displayedTime / duration, 0), 1))
    }

    private var displayedTime: Double {
        scrubbedTime ?? currentTime
    }

    private var isSeekable: Bool {
        duration > 0 && duration.isFinite
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))

                Capsule()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: max(5, proxy.size.width * progress))
            }
            .frame(height: isHovering ? 7 : 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(seekGesture(width: proxy.size.width))
        }
        .frame(height: 16)
        .disabled(!isSeekable)
        .candoaCursor(isSeekable ? .pointingHand : .arrow)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.10), value: isHovering)
        .onChange(of: currentTime) { _, _ in
            if !isScrubbing, scrubbedTime != nil {
                scrubbedTime = nil
            }
        }
        .onDisappear {
            onScrubbingChanged(false)
        }
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                isScrubbing = true
                onScrubbingChanged(true)
                seek(toXPosition: value.location.x, width: width)
            }
            .onEnded { value in
                seek(toXPosition: value.location.x, width: width)
                isScrubbing = false
                onScrubbingChanged(false)
            }
    }

    private func seek(toXPosition xPosition: CGFloat, width: CGFloat) {
        guard isSeekable, width > 0 else { return }

        let ratio = min(max(xPosition / width, 0), 1)
        let targetTime = Double(ratio) * duration
        scrubbedTime = targetTime
        onSeek(targetTime)
    }
}
