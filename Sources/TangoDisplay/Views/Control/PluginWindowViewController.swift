import AppKit
import SwiftUI
import TangoDisplayCore

// MARK: - Wrapper VC that adds a preset bar below the AU's native view

final class PluginWindowViewController: NSViewController {
    private let pluginVC: NSViewController
    private let player: LocalPlayerSource
    private var sizeObservation: NSKeyValueObservation?

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

        // Legacy V2 AU views carry their natural size in frame before TAMC is cleared.
        // Capture it now so we can set preferredContentSize synchronously below.
        let naturalPluginSize = pluginVC.view.frame.size

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

        // For V2 AUs (e.g. AUGraphicEQ): use the natural frame captured above.
        if naturalPluginSize != .zero {
            preferredContentSize = NSSize(width: naturalPluginSize.width,
                                          height: naturalPluginSize.height + barHeight)
        }

        // For V3 AUs that report size via preferredContentSize (possibly async):
        // KVO fires with .initial immediately and then again whenever the size changes.
        // NSWindow does not auto-resize after creation, so we also call setContentSize.
        sizeObservation = pluginVC.observe(\.preferredContentSize, options: [.initial, .new]) { [weak self] vc, _ in
            guard let self else { return }
            let sz = vc.preferredContentSize
            guard sz != .zero else { return }
            let newSize = NSSize(width: sz.width, height: sz.height + 44)
            self.preferredContentSize = newSize
            DispatchQueue.main.async { [weak self] in
                self?.view.window?.setContentSize(newSize)
            }
        }
    }

    override var preferredContentSize: NSSize {
        get { super.preferredContentSize }
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
