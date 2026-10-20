import AppKit
import Carbon
import Combine
import LimelightCore
import ServiceManagement
import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var hotKey: KeyCombo?
    @Published var hotKeyWorks = true
    @Published var spotlightConflict = false
    @Published var launchAtLogin = false
    @Published var webSearch = WebSearchProvider.all[0].name
    @Published var config = IndexConfig.standard()
    @Published var itemCount = 0
    @Published var indexing = false

    var setHotKey: (KeyCombo) -> Void = { _ in }
    var pauseHotKey: (Bool) -> Void = { _ in }
    var setWebSearch: (String) -> Void = { _ in }
    var setConfig: (IndexConfig) -> Void = { _ in }
    var rebuild: () -> Void = {}

    func refreshSystemState() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        spotlightConflict = hotKey == .commandSpace && HotKeyCenter.spotlightOwnsCommandSpace
    }

    func toggleLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()
        }
        refreshSystemState()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Shortcut") {
                HStack {
                    Text("Open Limelight")
                    Spacer()
                    ShortcutRecorder(combo: model.hotKey, onChange: model.setHotKey, onRecording: model.pauseHotKey)
                        .frame(width: 160, height: 24)
                }
                if model.hotKey != .commandSpace {
                    HStack {
                        Text("Replace Spotlight on ⌘Space")
                        Spacer()
                        Button("Use ⌘Space") { model.setHotKey(.commandSpace) }
                    }
                }
                if !model.hotKeyWorks {
                    Label("Another app already uses this shortcut. Pick a different one.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if model.spotlightConflict {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Spotlight still owns ⌘Space, so it opens instead of Limelight.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("In System Settings → Keyboard → Keyboard Shortcuts → Spotlight, turn off “Show Spotlight search”. Limelight takes over as soon as it’s off.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Keyboard Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        }
                    }
                }
            }

            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.toggleLaunchAtLogin($0) }))
                Picker("Web search", selection: Binding(get: { model.webSearch }, set: { model.webSearch = $0; model.setWebSearch($0) })) {
                    ForEach(WebSearchProvider.all, id: \.name) { Text($0.name).tag($0.name) }
                }
            }

            Section("Search folders") {
                FolderList(paths: model.config.roots) { model.config.roots = $0; model.setConfig(model.config) }
            }

            Section("Skipped folders") {
                FolderList(paths: model.config.excludedPaths) { model.config.excludedPaths = $0; model.setConfig(model.config) }
                LabeledContent("Always skipped") {
                    Text((model.config.excludedNames + ["*.noindex"]).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Include hidden files and folders", isOn: Binding(
                    get: { model.config.includeHidden },
                    set: { model.config.includeHidden = $0; model.setConfig(model.config) }
                ))
            }

            Section("Index") {
                HStack {
                    if model.indexing {
                        ProgressView().controlSize(.small)
                        Text("Indexing…")
                    } else {
                        Text("\(model.itemCount.formatted()) files and folders")
                    }
                    Spacer()
                    Button("Rebuild Index") { model.rebuild() }.disabled(model.indexing)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560)
        .onAppear { model.refreshSystemState() }
        .onReceive(tick) { _ in model.refreshSystemState() }
    }
}

struct FolderList: View {
    let paths: [String]
    let onChange: ([String]) -> Void
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(paths, id: \.self) { path in
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(abbreviated(path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        onChange(paths.filter { $0 != path })
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                }
            }
            Button("Add Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = true
                if panel.runModal() == .OK {
                    let added = panel.urls.map(\.path).filter { !paths.contains($0) }
                    onChange(paths + added)
                }
            }
        }
    }

    private func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let combo: KeyCombo?
    let onChange: (KeyCombo) -> Void
    let onRecording: (Bool) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let b = ShortcutRecorderButton()
        b.onChange = onChange
        b.onRecording = onRecording
        b.combo = combo
        return b
    }

    func updateNSView(_ b: ShortcutRecorderButton, context: Context) {
        b.onChange = onChange
        b.onRecording = onRecording
        if !b.isRecording { b.combo = combo }
    }
}

final class ShortcutRecorderButton: NSButton {
    var combo: KeyCombo? { didSet { updateTitle() } }
    var onChange: ((KeyCombo) -> Void)?
    var onRecording: ((Bool) -> Void)?
    private(set) var isRecording = false
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .push
        target = self
        action = #selector(toggleRecording)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleRecording() {
        isRecording ? stop() : start()
    }

    private func start() {
        isRecording = true
        onRecording?(true)
        updateTitle()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.stop()
            } else if let c = KeyCombo(event: event) {
                self.combo = c
                self.stop()
                self.onChange?(c)
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        onRecording?(false)
        updateTitle()
    }

    private func updateTitle() {
        title = isRecording ? "Type a shortcut…" : (combo?.display ?? "Record Shortcut")
    }
}
