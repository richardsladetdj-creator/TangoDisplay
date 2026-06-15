import AppKit
import SwiftUI
import TangoDisplayCore

struct AppearanceVisibilityTab: View {
    @EnvironmentObject var settings: AppSettings
    @Binding var working: AppearanceProfile
    @Binding var danceDragItem: OrderEntry?
    @Binding var cortinaTrackDragItem: OrderEntry?
    @Binding var cortinaUpDragItem: OrderEntry?

    private let availableFonts: [String] = ["System"] + NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Dance")
                        .frame(width: 70, alignment: .center)
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                    Text("Next Up")
                        .frame(width: 70, alignment: .center)
                        .foregroundColor(working.showNextTrackDuringCortina ? .secondary : .secondary.opacity(0.4))
                        .font(.subheadline)
                }
                visibilityRow("Genre",   dance: $working.showGenreDance,   cortina: $working.showGenreCortina)
                visibilityRow("Artist",  dance: $working.showArtistDance,  cortina: $working.showArtistCortina)
                visibilityRow("Year",    dance: $working.showYearDance,    cortina: $working.showYearCortina)
                visibilityRow("Title",   dance: $working.showTitleDance,   cortina: $working.showTitleCortina)
                visibilityRow("Singer",  dance: $working.showSingerDance,  cortina: $working.showSingerCortina)
                visibilityRow("Artwork", dance: $working.showArtworkDance, cortina: $working.showArtworkCortina)
                ForEach(working.customTextLines) { line in
                    let b = customLineBinding(id: line.id)
                    visibilityRow(customLabel(line), dance: b.showInDance, cortina: b.showInCortina)
                }
                Divider()
                Toggle("Show next track during cortina", isOn: $working.showNextTrackDuringCortina)
            } header: {
                Text("Field Visibility")
                    .foregroundColor(ControlTheme.accent)
            } footer: {
                Label {
                    Text("The Next Up column applies when 'Show next track during cortina' is enabled.")
                } icon: {
                    Image(systemName: "info.circle")
                }
            }

            Section {
                orderRows(items: $working.danceItemOrder, dragItem: $danceDragItem,
                          filter: {
                              ($0 != .builtin(.trackCounter) || settings.trackCounterPosition == .centre) &&
                              ($0 != .builtin(.tdjName)       || settings.tdjNamePosition == .centre)
                          })
            } header: {
                orderHeader("Dance Tracks")
            }

            Section {
                orderRows(items: $working.cortinaTrackItemOrder, dragItem: $cortinaTrackDragItem)
            } header: {
                orderHeader("Cortinas — Cortina Track")
            }

            Section {
                orderRows(items: $working.cortinaItemOrder, dragItem: $cortinaUpDragItem,
                          filter: { $0 != .builtin(.tdjName) || settings.tdjNamePosition == .centre })
            } header: {
                orderHeader("Cortinas — Coming Up")
            } footer: {
                Label {
                    Text("Sets the display order only. Use Field Visibility to show or hide individual fields.")
                } icon: {
                    Image(systemName: "info.circle")
                }
            }

            Section {
                Text("Free text with placeholders, resolved from the current/next track. Available: {Artist} {Title} {Genre} {Year} {Singer} {AlbumArtist} {Comment} {Grouping} (case-insensitive).")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(working.customTextLines) { line in
                    customLineRow(line: customLineBinding(id: line.id))
                }

                Button {
                    addCustomLine()
                } label: {
                    Label("Add Custom Line", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            } header: {
                Text("Custom Lines")
                    .foregroundColor(ControlTheme.accent)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private func orderHeader(_ subtitle: String) -> some View {
        Text("Text Order for \(subtitle)")
            .foregroundColor(ControlTheme.accent)
    }

    private func visibilityRow(_ label: String, dance: Binding<Bool>, cortina: Binding<Bool>) -> some View {
        HStack {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: dance).labelsHidden().frame(width: 70, alignment: .center)
            Toggle("", isOn: cortina).labelsHidden().frame(width: 70, alignment: .center)
                .disabled(!working.showNextTrackDuringCortina)
        }
    }

    /// Display label for a custom line: its (truncated) text, or a placeholder name when empty.
    private func customLabel(_ line: CustomTextLine) -> String {
        let trimmed = line.text.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? "Custom Line" : trimmed
        return base.count > 28 ? String(base.prefix(28)) + "…" : base
    }

    private func label(for entry: OrderEntry) -> String {
        switch entry {
        case .builtin(let item):
            return item.displayName
        case .custom(let id):
            if let line = working.customTextLines.first(where: { $0.id == id }) {
                return customLabel(line)
            }
            return "Custom Line"
        }
    }

    private func dragToken(for entry: OrderEntry) -> String {
        switch entry {
        case .builtin(let item): return "builtin:\(item.rawValue)"
        case .custom(let id):    return "custom:\(id.uuidString)"
        }
    }

    /// Custom entries whose line no longer exists are hidden (deletes remove them from
    /// the order arrays, but this is a safety net).
    private func entryExists(_ entry: OrderEntry) -> Bool {
        switch entry {
        case .builtin:        return true
        case .custom(let id): return working.customTextLines.contains { $0.id == id }
        }
    }

    @ViewBuilder
    private func orderRows(items: Binding<[OrderEntry]>, dragItem: Binding<OrderEntry?>,
                           filter: ((OrderEntry) -> Bool)? = nil) -> some View {
        let visibleIndices = items.wrappedValue.indices.filter {
            entryExists(items.wrappedValue[$0]) && (filter?(items.wrappedValue[$0]) ?? true)
        }
        VStack(spacing: 0) {
            ForEach(visibleIndices, id: \.self) { index in
                let isFirstVisible = index == visibleIndices.first
                let isLastVisible  = index == visibleIndices.last
                if !isFirstVisible { Divider() }
                HStack {
                    Image(systemName: "line.3.horizontal")
                        .foregroundColor(.secondary)
                        .frame(width: 20)
                    Text(label(for: items.wrappedValue[index]))
                    Spacer()
                    Button {
                        items.wrappedValue.swapAt(index, index - 1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isFirstVisible)
                    Button {
                        items.wrappedValue.swapAt(index, index + 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLastVisible)
                }
                .padding(.vertical, 8)
                .onDrag {
                    dragItem.wrappedValue = items.wrappedValue[index]
                    return NSItemProvider(object: dragToken(for: items.wrappedValue[index]) as NSString)
                }
                .onDrop(of: [.plainText], delegate: OrderDropDelegate(
                    target: items.wrappedValue[index],
                    items: items,
                    dragging: dragItem
                ))
            }
        }
    }

    // MARK: - Custom line editor

    @ViewBuilder
    private func customLineRow(line: Binding<CustomTextLine>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("e.g. {Artist} {Year} ({Genre}) {Title}", text: line.text)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Picker("Font", selection: line.fontName) {
                    ForEach(availableFonts, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .labelsHidden()
                .frame(width: 160)

                Text(String(format: "%.0fpt", line.wrappedValue.fontSize))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing)

                Stepper("", value: line.fontSize, in: 8...300, step: 4)
                    .labelsHidden()
                    .fixedSize()

                Toggle("B", isOn: line.fontBold)
                    .toggleStyle(.button)
                    .help("Bold")

                Toggle("I", isOn: line.fontItalic)
                    .toggleStyle(.button)
                    .help("Italic")

                Spacer()

                ColorPicker("", selection: Binding(
                    get: { Color(hex: line.wrappedValue.colorHex) },
                    set: { line.wrappedValue.colorHex = $0.hexString }
                ))
                .labelsHidden()
                .frame(width: 32)

                Button(role: .destructive) {
                    deleteCustomLine(id: line.wrappedValue.id)
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    /// Stable, id-keyed binding to a custom line. The getter looks up by id rather than
    /// array index, so a transient read during a delete (when the index is stale) falls
    /// back to a throwaway value instead of trapping on an out-of-bounds subscript.
    private func customLineBinding(id: UUID) -> Binding<CustomTextLine> {
        Binding(
            get: { working.customTextLines.first(where: { $0.id == id }) ?? CustomTextLine() },
            set: { newValue in
                if let idx = working.customTextLines.firstIndex(where: { $0.id == id }) {
                    working.customTextLines[idx] = newValue
                }
            }
        )
    }

    private func addCustomLine() {
        let line = CustomTextLine()
        working.customTextLines.append(line)
        working.danceItemOrder.append(.custom(line.id))
        working.cortinaItemOrder.append(.custom(line.id))
    }

    private func deleteCustomLine(id: UUID) {
        working.customTextLines.removeAll { $0.id == id }
        working.danceItemOrder.removeAll { $0 == .custom(id) }
        working.cortinaItemOrder.removeAll { $0 == .custom(id) }
        working.cortinaTrackItemOrder.removeAll { $0 == .custom(id) }
    }
}

// MARK: - Drop delegate (shared with visibility tab)

struct OrderDropDelegate: DropDelegate {
    let target: OrderEntry
    var items: Binding<[OrderEntry]>
    var dragging: Binding<OrderEntry?>

    func dropUpdated(info: DropInfo) -> DropProposal? {
        .init(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging.wrappedValue = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let src = dragging.wrappedValue,
              src != target,
              let from = items.wrappedValue.firstIndex(of: src),
              let to = items.wrappedValue.firstIndex(of: target) else { return }
        withAnimation {
            items.wrappedValue.move(fromOffsets: .init(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }
}
