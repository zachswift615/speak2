import Foundation
import os

/// Opt-in diagnostics: keep the last few raw recordings (16 kHz mono WAV) on disk so audio problems
/// (clipped first words, silent inputs) can be inspected. Enable with:
///     defaults write com.zachswift.speak2 debugSaveRecordings -bool YES   # installed .app
///     defaults write Speak2 debugSaveRecordings -bool YES                 # bare dev binary
/// Files land in ~/Library/Application Support/Speak2/debug-recordings/.
enum DebugRecordingStore {
    static let userDefaultsKey = "debugSaveRecordings"
    private static let keepCount = 5
    private static let log = Logger(subsystem: "com.speak2", category: "DebugRecordings")

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: userDefaultsKey)
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Speak2/debug-recordings", isDirectory: true)
    }

    /// Save `samples` if the debug switch is on. Never throws — diagnostics must not affect dictation.
    static func saveIfEnabled(_ samples: [Float], engine: String) {
        guard isEnabled, !samples.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let temp = try writeSamplesToTempWAV(samples, filenamePrefix: "debug")
            let dest = directory.appendingPathComponent("\(stamp)_\(engine).wav")
            try FileManager.default.moveItem(at: temp, to: dest)
            log.info("Saved debug recording to \(dest.path, privacy: .public)")
            prune()
        } catch {
            log.error("Could not save debug recording: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        let sorted = files.filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in sorted.dropFirst(keepCount) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
