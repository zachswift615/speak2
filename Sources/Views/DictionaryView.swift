import SwiftUI
import UniformTypeIdentifiers

struct DictionaryView: View {
    @EnvironmentObject var dictionaryState: DictionaryState
    @State private var showingAddSheet = false
    @State private var editingEntry: DictionaryEntry? = nil
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Error banner
            if let error = dictionaryState.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.subheadline)
                    Spacer()
                    Button {
                        withAnimation { dictionaryState.dismissError() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
                .padding(.top, 8)
            }

            // Main content
            if dictionaryState.filteredEntries.isEmpty && searchText.isEmpty {
                emptyStateView
            } else {
                listView
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(NSColor.windowBackgroundColor))
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search words...")
        .onChange(of: searchText) { _, newValue in
            dictionaryState.searchQuery = newValue
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // Language picker
                Picker("Language", selection: $dictionaryState.selectedLanguage) {
                    ForEach(SupportedLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .frame(width: 120)

                // Category filter
                Menu {
                    Button {
                        dictionaryState.selectedCategory = nil
                    } label: {
                        if dictionaryState.selectedCategory == nil {
                            Label("All Categories", systemImage: "checkmark")
                        } else {
                            Text("All Categories")
                        }
                    }
                    Divider()
                    ForEach(EntryCategory.allCases, id: \.self) { category in
                        Button {
                            dictionaryState.selectedCategory = category
                        } label: {
                            if dictionaryState.selectedCategory == category {
                                Label(category.displayName, systemImage: "checkmark")
                            } else {
                                Label(category.displayName, systemImage: category.icon)
                            }
                        }
                    }
                } label: {
                    Label(
                        dictionaryState.selectedCategory?.displayName ?? "All",
                        systemImage: dictionaryState.selectedCategory?.icon ?? "line.3.horizontal.decrease.circle"
                    )
                }

                // Import/Export
                Menu {
                    Button("Import...", systemImage: "square.and.arrow.down") {
                        importDictionary()
                    }
                    Button("Export...", systemImage: "square.and.arrow.up") {
                        exportDictionary()
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }

                // Add button
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Word", systemImage: "plus")
                }
            }
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

    private var listView: some View {
        VStack(spacing: 0) {
            List {
                ForEach(dictionaryState.filteredEntries) { entry in
                    DictionaryEntryRow(
                        entry: entry,
                        onToggle: { dictionaryState.toggle(entry) },
                        onEdit: { editingEntry = entry },
                        onDelete: { dictionaryState.delete(entry) }
                    )
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let entry = dictionaryState.filteredEntries[index]
                        dictionaryState.delete(entry)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            // Footer
            HStack {
                Text("\(dictionaryState.filteredEntries.count) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !searchText.isEmpty || dictionaryState.selectedCategory != nil {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(dictionaryState.entries.count) total")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.tertiary)

            VStack(spacing: 6) {
                Text("No Words Yet")
                    .font(.title2)
                    .fontWeight(.medium)
                Text("Add words to improve transcription accuracy\nfor names, technical terms, and jargon.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                showingAddSheet = true
            } label: {
                Text("Add Your First Word")
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
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
