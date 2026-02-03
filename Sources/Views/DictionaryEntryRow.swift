import SwiftUI

struct DictionaryEntryRow: View {
    let entry: DictionaryEntry
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            // Enable toggle
            Button(action: onToggle) {
                Image(systemName: entry.isEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(entry.isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .help(entry.isEnabled ? "Disable" : "Enable")

            // Category badge
            Image(systemName: entry.category.icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .help(entry.category.displayName)

            // Word and metadata
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.word)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(entry.isEnabled ? .primary : .secondary)

                if !entry.aliases.isEmpty || entry.pronunciation != nil {
                    HStack(spacing: 8) {
                        if !entry.aliases.isEmpty {
                            Label {
                                Text(entry.aliases.joined(separator: ", "))
                                    .lineLimit(1)
                            } icon: {
                                Image(systemName: "arrow.triangle.branch")
                            }
                        }

                        if let pronunciation = entry.pronunciation, !pronunciation.isEmpty {
                            Label {
                                Text(pronunciation)
                            } icon: {
                                Image(systemName: "waveform")
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Actions
            HStack(spacing: 6) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 14))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Edit")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red.opacity(0.8))
                .help("Delete")
            }
            .opacity(isHovering ? 1 : 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}
