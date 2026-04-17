import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor
final class TextInjector {

    // MARK: - Types

    private enum OriginalClipboard {
        case empty
        case items([NSPasteboardItem])
        case unrecoverable
    }

    private struct ClipboardSession {
        let original: OriginalClipboard
        let id: UUID
        let injectedChangeCount: Int
        let injectedText: String
    }

    private struct TextStateSnapshot: Equatable {
        let selectedTextRange: NSRange?
        let numberOfCharacters: Int?

        var hasSignal: Bool {
            selectedTextRange != nil || numberOfCharacters != nil
        }
    }

    /// Result of waiting for paste completion
    private enum PasteDetectionResult {
        case detected          // Accessibility notification confirmed paste
        case clipboardChanged  // Something else modified the clipboard
        case timeout           // Timed out waiting (still restore)
        case noSignalAvailable // App doesn't support accessibility detection
    }

    // MARK: - Configuration

    /// Timeout for event-driven accessibility notification.
    /// If the app supports notifications but we don't hear back in this time, proceed anyway.
    private let accessibilityTimeout: Duration = .seconds(3)

    /// Fallback delay for apps that don't support accessibility notifications.
    /// Most paste operations complete within 50ms. We use 100ms as a conservative
    /// fallback to minimize the window where users could accidentally paste again.
    /// Users can override via the "clipboardRestoreDelayMs" UserDefaults key — useful
    /// for slow SSH/remote terminals where the default may restore the original
    /// clipboard before the target app finishes reading the injected text.
    static let defaultFallbackDelayMs: Int = 100
    static let minFallbackDelayMs: Int = 50
    static let maxFallbackDelayMs: Int = 2000

    private var fallbackDelay: Duration {
        let raw = UserDefaults.standard.object(forKey: "clipboardRestoreDelayMs") as? Int
        let ms = raw ?? Self.defaultFallbackDelayMs
        let clamped = min(max(ms, Self.minFallbackDelayMs), Self.maxFallbackDelayMs)
        return .milliseconds(clamped)
    }

    // MARK: - State

    private var session: ClipboardSession?
    private var restoreTask: Task<Void, Never>?

    // MARK: - Public API

    /// Inject text into the currently focused application via clipboard paste.
    ///
    /// This method:
    /// 1. Snapshots the current clipboard contents
    /// 2. Places the text on the clipboard
    /// 3. Simulates Cmd+V
    /// 4. Waits for paste completion using event-driven detection
    /// 5. Restores the original clipboard contents
    ///
    /// The method uses `AXObserver` for event-driven paste detection when available,
    /// falling back to a brief heuristic delay for apps without accessibility support.
    func inject(text: String) async {
        let pasteboard = NSPasteboard.general

        // Snapshot original clipboard, preserving across rapid successive calls
        let original: OriginalClipboard
        if let existingSession = session, pasteboard.changeCount == existingSession.injectedChangeCount {
            original = existingSession.original
        } else {
            session = nil
            original = snapshotOriginalClipboard(from: pasteboard)
        }

        // Cancel any pending restore from a previous injection
        restoreTask?.cancel()

        // Write text to clipboard (synchronous - no delay needed)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let injectedChangeCount = pasteboard.changeCount

        // Create session to track this injection
        let sessionId = UUID()
        session = ClipboardSession(
            original: original,
            id: sessionId,
            injectedChangeCount: injectedChangeCount,
            injectedText: text
        )

        // Capture focused element state BEFORE paste for change detection
        let focusedElement = fetchFocusedUIElement()
        let baseline = focusedElement.map { snapshotTextState(of: $0) }

        // Simulate Cmd+V to paste
        simulatePaste()

        // Wait for paste completion and restore clipboard
        restoreTask = Task { @MainActor in
            let result = await self.waitForPasteCompletion(
                pasteboard: pasteboard,
                sessionId: sessionId,
                focusedElement: focusedElement,
                baseline: baseline
            )

            // Log detection method for debugging (remove in production or use proper logging)
            #if DEBUG
            switch result {
            case .detected:
                print("[TextInjector] Paste detected via accessibility notification")
            case .clipboardChanged:
                print("[TextInjector] Clipboard changed externally, skipping restore")
            case .timeout:
                print("[TextInjector] Accessibility timeout reached, restoring clipboard")
            case .noSignalAvailable:
                print("[TextInjector] No accessibility signal, used fallback delay")
            }
            #endif

            // Don't restore if clipboard was modified externally
            if case .clipboardChanged = result {
                self.session = nil
                return
            }

            self.restoreClipboard(on: pasteboard, sessionId: sessionId)
        }
    }

    // MARK: - Paste Detection

    private func waitForPasteCompletion(
        pasteboard: NSPasteboard,
        sessionId: UUID,
        focusedElement: AXUIElement?,
        baseline: TextStateSnapshot?
    ) async -> PasteDetectionResult {

        // Check if clipboard was modified externally
        guard let currentSession = session, currentSession.id == sessionId else {
            return .clipboardChanged
        }
        if pasteboard.changeCount != currentSession.injectedChangeCount {
            return .clipboardChanged
        }

        // Strategy 1: Event-driven detection via AXObserver
        if let element = focusedElement,
           AccessibilityObserver.supportsTextChangeNotifications(element: element) {
            let observer = AccessibilityObserver()
            do {
                try await observer.waitForTextChange(on: element, timeout: accessibilityTimeout)
                return .detected
            } catch AccessibilityObserver.ObserverError.timeout {
                return .timeout
            } catch {
                // Fall through to polling/fallback
            }
        }

        // Strategy 2: Polling-based detection (for elements that support attributes but not notifications)
        if let element = focusedElement, let baseline = baseline, baseline.hasSignal {
            let pollResult = await pollForTextChange(
                element: element,
                baseline: baseline,
                pasteboard: pasteboard,
                sessionId: sessionId
            )
            if pollResult != .noSignalAvailable {
                return pollResult
            }
        }

        // Strategy 3: Fallback delay for apps without any accessibility support
        // This is the least desirable path but necessary for compatibility
        try? await Task.sleep(for: fallbackDelay)

        // Final clipboard check
        guard let currentSession = session, currentSession.id == sessionId else {
            return .clipboardChanged
        }
        if pasteboard.changeCount != currentSession.injectedChangeCount {
            return .clipboardChanged
        }

        return .noSignalAvailable
    }

    /// Poll for text changes when notifications aren't available but attributes are.
    /// Uses short intervals since we already know the element supports accessibility.
    private func pollForTextChange(
        element: AXUIElement,
        baseline: TextStateSnapshot,
        pasteboard: NSPasteboard,
        sessionId: UUID
    ) async -> PasteDetectionResult {
        let pollInterval: Duration = .milliseconds(50)
        let maxPolls = 20 // 1 second max polling time

        for _ in 0..<maxPolls {
            // Check for external clipboard modification
            guard let currentSession = session, currentSession.id == sessionId else {
                return .clipboardChanged
            }
            if pasteboard.changeCount != currentSession.injectedChangeCount {
                return .clipboardChanged
            }

            // Check for text change
            let current = snapshotTextState(of: element)
            if current.hasSignal && indicatesPasteConsumed(baseline: baseline, current: current) {
                return .detected
            }

            try? await Task.sleep(for: pollInterval)
        }

        return .timeout
    }

    // MARK: - Clipboard Operations

    private func snapshotOriginalClipboard(from pasteboard: NSPasteboard) -> OriginalClipboard {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return .empty }

        let snapshots: [NSPasteboardItem] = items.compactMap { item in
            let snapshot = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    snapshot.setData(data, forType: type)
                } else if let string = item.string(forType: type) {
                    snapshot.setString(string, forType: type)
                } else if let propertyList = item.propertyList(forType: type) {
                    snapshot.setPropertyList(propertyList, forType: type)
                }
            }
            return snapshot.types.isEmpty ? nil : snapshot
        }

        if !snapshots.isEmpty {
            return .items(snapshots)
        }

        // Clipboard wasn't empty, but we couldn't snapshot any writable types
        return .unrecoverable
    }

    private func restoreClipboard(on pasteboard: NSPasteboard, sessionId: UUID) {
        guard let currentSession = session, currentSession.id == sessionId else { return }
        guard pasteboard.changeCount == currentSession.injectedChangeCount else {
            session = nil
            return
        }

        switch currentSession.original {
        case .unrecoverable:
            break
        case .empty:
            pasteboard.clearContents()
        case .items(let items):
            // IMPORTANT: clearContents() must be called before writeObjects()
            // writeObjects() appends to the pasteboard, it doesn't replace
            pasteboard.clearContents()
            let didWrite = pasteboard.writeObjects(items)
            if !didWrite {
                // Restore failed - put back what we injected so user doesn't lose it
                pasteboard.clearContents()
                pasteboard.setString(currentSession.injectedText, forType: .string)
            }
        }
        session = nil
    }

    // MARK: - Accessibility Helpers

    private func fetchFocusedUIElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard error == .success, let focused else { return nil }
        return (focused as! AXUIElement)
    }

    private func snapshotTextState(of element: AXUIElement) -> TextStateSnapshot {
        TextStateSnapshot(
            selectedTextRange: copyRangeAttribute(of: element, attribute: kAXSelectedTextRangeAttribute),
            numberOfCharacters: copyIntAttribute(of: element, attribute: kAXNumberOfCharactersAttribute)
        )
    }

    private func indicatesPasteConsumed(baseline: TextStateSnapshot, current: TextStateSnapshot) -> Bool {
        if let baselineRange = baseline.selectedTextRange, let currentRange = current.selectedTextRange {
            if baselineRange != currentRange { return true }
        }

        if let baselineCount = baseline.numberOfCharacters, let currentCount = current.numberOfCharacters {
            if baselineCount != currentCount { return true }
        }

        return false
    }

    private func copyIntAttribute(of element: AXUIElement, attribute: String) -> Int? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success, let rawValue else { return nil }
        if let numberValue = rawValue as? NSNumber {
            return numberValue.intValue
        }
        return rawValue as? Int
    }

    private func copyRangeAttribute(of element: AXUIElement, attribute: String) -> NSRange? {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue)
        guard error == .success, let rawValue else { return nil }
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        let axValue = (rawValue as! AXValue)

        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    // MARK: - Keyboard Simulation

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode: CGKeyCode = 9 // 'V' key

        // Key down with Command modifier
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }

        // Key up with Command modifier
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
