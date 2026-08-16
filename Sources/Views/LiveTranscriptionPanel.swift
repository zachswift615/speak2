import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - Panel Controller

@MainActor
class LiveTranscriptionPanelController {
    private var panel: NSPanel?
    private var bottomY: CGFloat = 0
    private var cancellable: AnyCancellable?
    private var hostingView: NSHostingView<LiveTranscriptionOverlayView>?

    func show() {
        if panel != nil { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true

        let screenMaxWidth = NSScreen.main?.visibleFrame.width ?? 800
        let maxPanelWidth = min(screenMaxWidth * 0.8, 700)
        let hostingView = NSHostingView(rootView: LiveTranscriptionOverlayView(maxPanelWidth: maxPanelWidth))
        panel.contentView = hostingView
        self.hostingView = hostingView

        // Use window layer for rounded corners
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 12
        panel.contentView?.layer?.masksToBounds = true

        // Position bottom-center, above the dock
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let fittingSize = hostingView.fittingSize
            let x = screenFrame.midX - fittingSize.width / 2
            bottomY = screenFrame.minY + 80
            panel.setFrame(NSRect(x: x, y: bottomY, width: fittingSize.width, height: fittingSize.height), display: true)
        }

        panel.orderFrontRegardless()
        self.panel = panel

        // Observe text changes to resize panel after SwiftUI layout
        cancellable = Publishers.CombineLatest(
            AppState.shared.$liveTranscriptionConfirmedText,
            AppState.shared.$liveTranscriptionUnconfirmedText
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.resizePanel()
            }
        }
    }

    private func resizePanel() {
        guard let panel, let hostingView, let screen = NSScreen.main else { return }
        let newSize = hostingView.fittingSize
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - newSize.width / 2
        panel.setFrame(NSRect(x: x, y: bottomY, width: newSize.width, height: newSize.height), display: true)
    }

    func dismiss() {
        cancellable?.cancel()
        cancellable = nil
        hostingView = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - SwiftUI Overlay View

struct LiveTranscriptionOverlayView: View {
    @ObservedObject private var appState = AppState.shared
    let maxPanelWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Pulsing recording indicator (orange until the microphone is actually live)
            Circle()
                .fill(appState.recordingState == .startingMicrophone ? Color.orange : Color.red)
                .frame(width: 10, height: 10)
                .modifier(PulseModifier())
                .padding(.top, 3)

            // Transcription text
            if !appState.liveTranscriptionConfirmedText.isEmpty || !appState.liveTranscriptionUnconfirmedText.isEmpty {
                (Text(appState.liveTranscriptionConfirmedText)
                    .font(.system(size: 14))
                 + Text(appState.liveTranscriptionUnconfirmedText.isEmpty ? "" : " " + appState.liveTranscriptionUnconfirmedText)
                    .font(.system(size: 14))
                    .italic()
                    .foregroundColor(.secondary))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(appState.recordingState == .startingMicrophone ? "Starting microphone..." : "Listening...")
                    .font(.system(size: 14))
                    .italic()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: 200, maxWidth: maxPanelWidth, alignment: .leading)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Pulse Animation

private struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}
