import SwiftUI
import TangoDisplayCore

struct ProfilesView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingSaveSheet = false
    @State private var newProfileName = ""
    @State private var profileToDelete: AppearanceProfile? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionHeader("Built-in")
                    VStack(spacing: 2) {
                        ForEach(AppearanceProfile.builtIns) { profile in
                            profileRow(profile, isBuiltIn: true)
                        }
                    }
                    .padding(.horizontal, 12)

                    if !appState.profileStore.userProfiles.isEmpty {
                        sectionHeader("Custom")
                            .padding(.top, 20)
                        VStack(spacing: 2) {
                            ForEach(appState.profileStore.userProfiles) { profile in
                                profileRow(profile, isBuiltIn: false)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 12)
            }

            Divider()

            HStack {
                Spacer()
                Button("Save Current Settings As New Profile…") {
                    newProfileName = ""
                    showingSaveSheet = true
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
        .sheet(isPresented: $showingSaveSheet) {
            saveSheet
        }
        .alert(
            "Delete \"\(profileToDelete?.name ?? "Profile")\"?",
            isPresented: Binding(
                get: { profileToDelete != nil },
                set: { if !$0 { profileToDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This profile will be permanently removed.")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(ControlTheme.accent)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
    }

    private func profileRow(_ profile: AppearanceProfile, isBuiltIn: Bool) -> some View {
        let isActive = appState.settings.activeProfileID == profile.id
        return HStack(spacing: 10) {
            colorSwatch(profile)

            HStack(spacing: 6) {
                Text(profile.name)
                    .font(.system(size: 13, weight: .semibold))
                if isActive {
                    Text("Active")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                }
            }

            Spacer()

            if !isBuiltIn {
                Button { profileToDelete = profile } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }

            Button("Apply") {
                appState.settings.activeProfileID = profile.id
            }
            .buttonStyle(.bordered)
            .disabled(isActive)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive
                      ? ControlTheme.accent.opacity(0.08)
                      : Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isActive ? ControlTheme.accent.opacity(0.55) : Color.clear,
                            lineWidth: 1.5
                        )
                )
        )
    }

    private func colorSwatch(_ profile: AppearanceProfile) -> some View {
        HStack(spacing: 4) {
            ForEach([profile.backgroundColor, profile.artistColor, profile.genreColor], id: \.self) { hex in
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
            }
        }
    }

    private var saveSheet: some View {
        VStack(spacing: 16) {
            Text("Save Profile")
                .font(.headline)

            TextField("Profile name", text: $newProfileName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { saveNewProfile() }

            HStack {
                Button("Cancel") { showingSaveSheet = false }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])

                Button("Save") { saveNewProfile() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(24)
        .frame(minWidth: 320)
    }

    private func performDelete() {
        guard let profile = profileToDelete else { return }
        if appState.settings.activeProfileID == profile.id {
            appState.settings.activeProfileID = AppearanceProfile.classic.id
        }
        try? appState.profileStore.delete(profile)
        profileToDelete = nil
    }

    private func saveNewProfile() {
        let trimmed = newProfileName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let all = appState.profileStore.allProfiles
        var base = all.first(where: { $0.id == appState.settings.activeProfileID }) ?? .classic
        base.id = UUID()
        base.name = trimmed
        base.isBuiltIn = false

        try? appState.profileStore.save(base)
        appState.settings.activeProfileID = base.id
        showingSaveSheet = false
    }
}
