import SwiftUI
import UniformTypeIdentifiers

struct DictionaryView: View {
    @EnvironmentObject var dictionaryState: DictionaryState
    @State private var showingAddSheet = false
    @State private var editingEntry: DictionaryEntry? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Error banner
            if let error = dictionaryState.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.callout)
                    Spacer()
                    Button("Dismiss") {
                        dictionaryState.dismissError()
                    }
                    .buttonStyle(.borderless)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
            }

            // Toolbar
            HStack(spacing: 12) {
                // Language Picker
                Picker("Language", selection: $dictionaryState.selectedLanguage) {
                    ForEach(SupportedLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 140)

                // Category Filter
                Picker("Category", selection: $dictionaryState.selectedCategory) {
                    Text("All Categories").tag(nil as EntryCategory?)
                    Divider()
                    ForEach(EntryCategory.allCases, id: \.self) { category in
                        Label(category.displayName, systemImage: category.icon)
                            .tag(category as EntryCategory?)
                    }
                }
                .labelsHidden()
                .frame(width: 160)

                Spacer()

                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search...", text: $dictionaryState.searchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .frame(width: 180)

                // Add Button
                Button(action: { showingAddSheet = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .help("Add new word")

                // Import/Export Menu
                Menu {
                    Button("Export Dictionary...") { exportDictionary() }
                    Button("Import Dictionary...") { importDictionary() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                .help("Import/Export")
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Entry List
            if dictionaryState.filteredEntries.isEmpty {
                emptyStateView
            } else {
                List {
                    ForEach(dictionaryState.filteredEntries) { entry in
                        DictionaryEntryRow(
                            entry: entry,
                            onToggle: { dictionaryState.toggle(entry) },
                            onEdit: { editingEntry = entry },
                            onDelete: { dictionaryState.delete(entry) }
                        )
                    }
                }
                .listStyle(.inset)
            }

            // Footer
            HStack {
                Text("\(dictionaryState.filteredEntries.count) entries")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Spacer()
                if dictionaryState.entries.count != dictionaryState.filteredEntries.count {
                    Text("(\(dictionaryState.entries.count) total)")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .sheet(isPresented: $showingAddSheet) {
            DictionaryEntryEditor(
                entry: nil,
                defaultLanguage: dictionaryState.selectedLanguage
            ) { newEntry in
                dictionaryState.add(newEntry)
            }
        }
        .sheet(item: $editingEntry) { entry in
            DictionaryEntryEditor(
                entry: entry,
                defaultLanguage: entry.language
            ) { updatedEntry in
                dictionaryState.update(updatedEntry)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No dictionary entries")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("Add words to improve transcription accuracy")
                .foregroundColor(.secondary)
            Button("Add First Entry") { showingAddSheet = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exportDictionary() {
        guard let data = dictionaryState.exportData() else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "speak2_dictionary.json"

        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private func importDictionary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.json]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.urls.first {
            if let data = try? Data(contentsOf: url) {
                try? dictionaryState.importData(data)
            }
        }
    }
}
