import SwiftUI

struct DictionaryEntryEditor: View {
    let entry: DictionaryEntry?
    let defaultLanguage: SupportedLanguage
    let onSave: (DictionaryEntry) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var word: String = ""
    @State private var pronunciation: String = ""
    @State private var aliases: String = ""
    @State private var category: EntryCategory = .custom
    @State private var selectedLanguage: SupportedLanguage = .english

    private var isEditing: Bool { entry != nil }
    private var canSave: Bool { !word.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // Form content
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Word field
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Word")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        TextField("Enter the correct spelling", text: $word)
                            .textFieldStyle(.plain)
                            .font(.title3)
                            .padding(10)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Aliases field
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Aliases")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                            Text("Optional")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        TextField("Common misspellings, separated by commas", text: $aliases)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        Text("e.g., \"Antropik, Ann Tropic\" for Anthropic")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    // Pronunciation field
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Pronunciation Hint")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                            Text("Optional")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        TextField("How it sounds phonetically", text: $pronunciation)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Category and Language
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Category")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                            Picker("Category", selection: $category) {
                                ForEach(EntryCategory.allCases, id: \.self) { cat in
                                    Label(cat.displayName, systemImage: cat.icon).tag(cat)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Language")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                            Picker("Language", selection: $selectedLanguage) {
                                ForEach(SupportedLanguage.allCases, id: \.self) { lang in
                                    Text(lang.displayName).tag(lang)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(20)
            }

            // Footer
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button(isEditing ? "Save Changes" : "Add Word") {
                    saveEntry()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!canSave)
            }
            .padding(20)
        }
        .frame(width: 420, height: 420)
        .onAppear {
            if let entry = entry {
                word = entry.word
                pronunciation = entry.pronunciation ?? ""
                aliases = entry.aliases.joined(separator: ", ")
                category = entry.category
                selectedLanguage = entry.language
            } else {
                selectedLanguage = defaultLanguage
            }
        }
    }

    private func saveEntry() {
        let aliasArray = aliases
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let newEntry: DictionaryEntry

        if let existing = entry {
            newEntry = DictionaryEntry(
                id: existing.id,
                word: word.trimmingCharacters(in: .whitespaces),
                pronunciation: pronunciation.isEmpty ? nil : pronunciation,
                language: selectedLanguage,
                aliases: aliasArray,
                category: category,
                isEnabled: existing.isEnabled,
                createdAt: existing.createdAt,
                updatedAt: Date()
            )
        } else {
            newEntry = DictionaryEntry(
                word: word.trimmingCharacters(in: .whitespaces),
                pronunciation: pronunciation.isEmpty ? nil : pronunciation,
                language: selectedLanguage,
                aliases: aliasArray,
                category: category
            )
        }

        onSave(newEntry)
        dismiss()
    }
}
