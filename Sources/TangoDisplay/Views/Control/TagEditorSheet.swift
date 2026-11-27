import SwiftUI
import TangoDisplayCore
import TangoDisplayTagging

/// Setlist's "Edit Tags…": rewrites the track's tags in the file itself (via TagEditor),
/// then re-reads the row so the setlist and the live display pick the change up.
/// Unlike Edit Upcoming Info, nothing here is a local override.
struct TagEditorSheet: View {
    let entry: SetlistEntry
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var values: [String: String] = [:]
    @State private var original: [String: String] = [:]
    @State private var loading = true
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var saved = false   // a Music-side warning still closes the sheet

    /// TagLib property name → label, in display order.
    private static let fields: [(key: String, label: String)] = [
        ("TITLE", "Title"), ("ARTIST", "Artist"), ("GENRE", "Genre"), ("DATE", "Year"),
        ("GROUPING", "Grouping"), ("ALBUMARTIST", "Album Artist"), ("COMMENT", "Comment"),
    ]

    private var changes: [String: String] {
        values.mapValues { $0.trimmingCharacters(in: .whitespaces) }
            .filter { (original[$0.key] ?? "") != $0.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Tags")
                .font(.headline)

            Text("Writes to \(entry.fileURL.lastPathComponent). A blank field removes that tag.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(Self.fields, id: \.key) { field in
                    GridRow {
                        Text(field.label)
                        TextField(field.label, text: binding(field.key))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .disabled(loading || saving)

            HStack {
                if loading || saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || saving || changes.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .task(id: entry.id) {
            let embedded = await EmbeddedTagReader.read(from: entry.fileURL)
            original = embedded
            values = embedded
            loading = false
        }
        .alert("Edit Tags", isPresented: Binding(get: { errorMessage != nil },
                                                 set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil; if saved { dismiss() } }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func save() {
        let changes = self.changes
        saving = true
        Task { @MainActor in
            defer { saving = false }
            let result: TagEditor.Result
            do {
                result = try await TagEditor.apply(changes, to: entry)
            } catch {
                errorMessage = error.localizedDescription   // file untouched; edits stay in the sheet
                return
            }
            saved = !result.local.written.isEmpty
            if saved {
                await appState.setlist.reloadMetadata(id: entry.id, force: true, editedFields: result.local.written)
                appState.localPlayer?.refreshReports()
            }
            let warnings = report(result)
            if warnings.isEmpty { dismiss() }
            else { errorMessage = warnings.joined(separator: "\n\n") }
        }
    }

    private func report(_ result: TagEditor.Result) -> [String] {
        var warnings = result.musicWarnings
        for field in Self.fields {
            if let reason = result.local.issues[field.key] {
                warnings.append("\(field.label) in the setlist file. \(reason)")
            }
            if let reason = result.music?.issues[field.key], result.local.written.contains(field.key) {
                warnings.append("\(field.label) in Music’s file. \(reason)")
            }
        }
        if !warnings.isEmpty && saved {
            let written = Self.fields.filter { result.local.written.contains($0.key) }.map(\.label)
            warnings.insert("Saved to the setlist file: \(written.joined(separator: ", ")).", at: 0)
        }
        return warnings
    }
}
