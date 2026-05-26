import AppKit
import SwiftUI
import TangoDisplayCore

// MARK: - Wrapper VC that adds a preset bar below the AU's native view

final class PluginWindowViewController: NSViewController {
    private let pluginVC: NSViewController
    private let player: LocalPlayerSource

    init(pluginVC: NSViewController, player: LocalPlayerSource) {
        self.pluginVC = pluginVC
        self.player = player
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(pluginVC)
        view.addSubview(pluginVC.view)
        pluginVC.view.translatesAutoresizingMaskIntoConstraints = false

        let barVC = NSHostingController(rootView: PluginWindowPresetBar(player: player))
        addChild(barVC)
        view.addSubview(barVC.view)
        barVC.view.translatesAutoresizingMaskIntoConstraints = false

        let barHeight: CGFloat = 44
        NSLayoutConstraint.activate([
            pluginVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            pluginVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pluginVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pluginVC.view.bottomAnchor.constraint(equalTo: barVC.view.topAnchor),

            barVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            barVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            barVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            barVC.view.heightAnchor.constraint(equalToConstant: barHeight),
        ])
    }

    override var preferredContentSize: NSSize {
        get {
            let inner = pluginVC.preferredContentSize
            guard inner != .zero else { return .zero }
            return NSSize(width: inner.width, height: inner.height + 44)
        }
        set { super.preferredContentSize = newValue }
    }
}

// MARK: - Preset bar rendered inside the plugin window

private struct PluginWindowPresetBar: View {
    @ObservedObject var player: LocalPlayerSource
    @State private var showSaveAlert = false
    @State private var presetName = ""

    private var activePresetLabel: String {
        guard let id = player.activePresetID,
              let p = player.availablePresets.first(where: { $0.id == id }) else { return "None" }
        return p.name
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Text("Preset:")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))

                if !player.availablePresets.isEmpty {
                    let factoryPresets = player.availablePresets.filter(\.isFactory)
                    let userPresets = player.availablePresets.filter(\.isUser)
                    Menu {
                        if !factoryPresets.isEmpty {
                            Section("Factory") {
                                ForEach(factoryPresets) { p in
                                    Button(p.name) { player.applyPreset(p) }
                                }
                            }
                        }
                        if !userPresets.isEmpty {
                            Section("Saved") {
                                ForEach(userPresets) { p in
                                    Button(p.name) { player.applyPreset(p) }
                                }
                            }
                            Divider()
                            ForEach(userPresets) { p in
                                Button("Delete \"\(p.name)\"", role: .destructive) {
                                    try? player.deletePreset(p)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(activePresetLabel)
                                .font(.system(size: 12))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(minWidth: 120)
                }

                Spacer()

                Button("Save as Preset…") {
                    presetName = ""
                    showSaveAlert = true
                }
                .font(.system(size: 12))
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
        }
        .background(.regularMaterial)
        .alert("Save as Preset", isPresented: $showSaveAlert) {
            TextField("Preset name", text: $presetName)
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                try? player.saveCurrentAsPreset(named: name)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the current EQ settings.")
        }
    }
}
