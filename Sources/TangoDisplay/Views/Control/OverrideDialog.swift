import SwiftUI

struct OverrideDialog: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Override Display")
                .font(.headline)

            Text("The presentation window will show this text until you clear the override.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            TextEditor(text: $text)
                .font(.system(size: 16))
                .frame(minHeight: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                )

            HStack {
                Button("Clear Override") {
                    appState.clearOverride()
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .tint(.orange)

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])

                Button("Activate Override") {
                    appState.activateOverride(text: text)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(minWidth: 400, minHeight: 220)
        .onAppear {
            text = appState.displayState.overrideText ?? ""
        }
    }
}
