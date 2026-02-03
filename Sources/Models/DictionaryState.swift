import Foundation
import Combine

@MainActor
class DictionaryState: ObservableObject {
    @Published var entries: [DictionaryEntry] = []
    @Published var selectedLanguage: SupportedLanguage = .english
    @Published var searchQuery: String = ""
    @Published var selectedCategory: EntryCategory? = nil
    @Published var errorMessage: String? = nil

    private let storage = DictionaryStorage()

    var filteredEntries: [DictionaryEntry] {
        entries.filter { entry in
            let matchesLanguage = entry.language == selectedLanguage
            let matchesSearch = searchQuery.isEmpty ||
                entry.word.localizedCaseInsensitiveContains(searchQuery) ||
                entry.aliases.contains { $0.localizedCaseInsensitiveContains(searchQuery) }
            let matchesCategory = selectedCategory == nil || entry.category == selectedCategory
            return matchesLanguage && matchesSearch && matchesCategory
        }
    }

    var enabledEntries: [DictionaryEntry] {
        entries.filter { $0.isEnabled }
    }

    func load() {
        entries = storage.load()
    }

    func save() {
        do {
            try storage.save(entries)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save dictionary. Changes may not persist."
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func add(_ entry: DictionaryEntry) {
        entries.append(entry)
        save()
    }

    func update(_ entry: DictionaryEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            var updated = entry
            updated.updatedAt = Date()
            entries[index] = updated
            save()
        }
    }

    func delete(_ entry: DictionaryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func toggle(_ entry: DictionaryEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].isEnabled.toggle()
            entries[index].updatedAt = Date()
            save()
        }
    }

    /// Generate prompt text for WhisperKit vocabulary biasing
    func promptText(for language: SupportedLanguage) -> String {
        let words = entries
            .filter { $0.language == language && $0.isEnabled }
            .map { $0.word }
        guard !words.isEmpty else { return "" }
        return words.joined(separator: ", ")
    }

    /// Get entries for a specific language (for post-processing)
    func enabledEntries(for language: SupportedLanguage) -> [DictionaryEntry] {
        entries.filter { $0.language == language && $0.isEnabled }
    }

    func exportData() -> Data? {
        storage.exportToJSON(entries)
    }

    func importData(_ data: Data) throws {
        let imported = try storage.importFromJSON(data)
        entries.append(contentsOf: imported)
        save()
    }
}
