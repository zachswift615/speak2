import Foundation
import Combine
import AppKit

@MainActor
class TranscriptionHistoryState: ObservableObject {
    @Published var entries: [TranscriptionHistoryEntry] = []
    @Published var searchQuery: String = ""
    @Published var modelFilter: String? = nil
    @Published var errorMessage: String? = nil

    private let storage = TranscriptionHistoryStorage()
    private var expiryTimer: Timer?

    /// UserDefaults keys for history-related settings.
    static let historyEnabledKey = "historyEnabled"
    static let historyRetentionMinutesKey = "historyRetentionMinutes"

    /// Whether new transcriptions should be saved to history. Defaults to true.
    static var historyEnabled: Bool {
        UserDefaults.standard.object(forKey: historyEnabledKey) as? Bool ?? true
    }

    /// Minutes after which entries are auto-deleted. 0 (default) means never expire.
    static var historyRetentionMinutes: Int {
        UserDefaults.standard.integer(forKey: historyRetentionMinutesKey)
    }

    /// All unique model names present in history, for the filter dropdown
    var availableModels: [String] {
        Array(Set(entries.map { $0.modelUsed })).sorted()
    }

    var filteredEntries: [TranscriptionHistoryEntry] {
        var result = entries

        if let modelFilter, !modelFilter.isEmpty {
            result = result.filter { $0.modelUsed == modelFilter }
        }

        if !searchQuery.isEmpty {
            result = result.filter { entry in
                entry.text.localizedCaseInsensitiveContains(searchQuery) ||
                entry.modelUsed.localizedCaseInsensitiveContains(searchQuery)
            }
        }

        return result
    }

    /// Group filtered entries by date section
    var groupedEntries: [(section: DateSection, entries: [TranscriptionHistoryEntry])] {
        let grouped = Dictionary(grouping: filteredEntries) { entry in
            DateSection.from(entry.timestamp)
        }
        return DateSection.allCases.compactMap { section in
            guard let entries = grouped[section], !entries.isEmpty else { return nil }
            return (section: section, entries: entries)
        }
    }

    func load() {
        entries = storage.load()
        sweepExpired()
        startExpiryTimerIfNeeded()
    }

    /// Remove entries older than the configured retention window.
    /// No-op if retention is 0 (never expire).
    func sweepExpired() {
        let retentionMinutes = Self.historyRetentionMinutes
        guard retentionMinutes > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionMinutes) * 60)
        let originalCount = entries.count
        entries.removeAll { $0.timestamp < cutoff }
        if entries.count != originalCount {
            save()
        }
    }

    /// Run a sweep every minute so retention takes effect while the app is open.
    private func startExpiryTimerIfNeeded() {
        guard expiryTimer == nil else { return }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sweepExpired()
            }
        }
    }

    func save() {
        do {
            try storage.save(entries)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save history. Changes may not persist."
        }
    }

    func add(_ entry: TranscriptionHistoryEntry) {
        // Respect the user's history-enabled preference
        guard Self.historyEnabled else { return }

        // Deduplicate: skip if identical to last entry
        if let lastEntry = entries.first,
           lastEntry.text == entry.text,
           lastEntry.modelUsed == entry.modelUsed {
            return
        }

        // Skip empty transcriptions
        guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // Insert at beginning (most recent first)
        entries.insert(entry, at: 0)

        // Auto-trim to 500
        if entries.count > 500 {
            entries = Array(entries.prefix(500))
        }

        save()
    }

    func delete(_ entry: TranscriptionHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func deleteMultiple(_ entriesToDelete: [TranscriptionHistoryEntry]) {
        let idsToDelete = Set(entriesToDelete.map { $0.id })
        entries.removeAll { idsToDelete.contains($0.id) }
        save()
    }

    func clearAll() {
        entries = []
        do {
            try storage.clearAll()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to clear history."
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func exportData() -> Data? {
        storage.exportToJSON(entries)
    }

    /// Copy text to clipboard
    func copyToClipboard(_ entry: TranscriptionHistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }
}
