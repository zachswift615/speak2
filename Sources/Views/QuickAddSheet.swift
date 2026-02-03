import SwiftUI

struct QuickAddSheet: View {
    @EnvironmentObject var dictionaryState: DictionaryState
    @Environment(\.dismiss) private var dismiss

    @State private var word: String = ""
    @State private var aliases: String = ""
    @State private var category: EntryCategory = .custom
    @State private var selectedLanguage: SupportedLanguage = .english

    private var canSave: Bool { !word.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // Form
            VStack(alignment: .leading, spacing: 20) {
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
                    TextField("Misspellings, separated by commas", text: $aliases)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }

                // Category and Language row
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
                    }

                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Spacer()

            // Footer
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Add Word") {
                    addWord()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 20)
        }
        .frame(width: 340, height: 320)
        .onAppear {
            selectedLanguage = dictionaryState.selectedLanguage
        }
    }

    private func addWord() {
        let aliasArray = aliases
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let entry = DictionaryEntry(
            word: word.trimmingCharacters(in: .whitespaces),
            language: selectedLanguage,
            aliases: aliasArray,
            category: category
        )

        dictionaryState.add(entry)
        dismiss()
    }
}
