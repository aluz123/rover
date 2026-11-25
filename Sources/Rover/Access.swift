// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import AppKit
import SwiftUI
import RoverCore

/// One-click file access setup: Full Disk Access (recommended) or just the three common folders.
enum Access {
    /// Full Disk Access can be detected without triggering a prompt: protected files fail with EPERM.
    static var hasFullDiskAccess: Bool {
        let probes = [NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
                      NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"]
        for p in probes {
            let fd = open(p, O_RDONLY)
            if fd >= 0 { close(fd); return true }
        }
        return false
    }

    static let folders = ["Desktop", "Documents", "Downloads"]

    /// Readable right now? (Only call after the person chose to grant, since it may show a prompt.)
    static func canRead(_ name: String) -> Bool {
        guard let d = opendir(NSHomeDirectory() + "/" + name) else { return false }
        closedir(d); return true
    }

    static func openSettings() {
        let urls = ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]
        for u in urls { if let url = URL(string: u), NSWorkspace.shared.open(url) { return } }
    }
}

final class AccessModel: ObservableObject {
    @Published var fda = Access.hasFullDiskAccess
    @Published var folderState: [String: Bool] = [:]
    @Published var openedSettings = false
    private var timer: Timer?
    var onGranted: (() -> Void)?

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !AccessWindow.shared.isVisible { self.stop(); return }   // window closed: stop polling
            let now = Access.hasFullDiskAccess
            if now && !self.fda { self.fda = true; self.onGranted?() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func askFolders() {
        // touching each folder makes macOS show its one-time Allow prompt
        DispatchQueue.global().async {
            var st: [String: Bool] = [:]
            for f in Access.folders { st[f] = Access.canRead(f) }
            DispatchQueue.main.async { self.folderState = st; self.onGranted?() }
        }
    }
}

struct AccessView: View {
    @ObservedObject var m: AccessModel
    var close: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            VStack(spacing: 6) {
                Text(m.fda ? "Rover can see everything" : "Let Rover see your files")
                    .font(.system(size: 20, weight: .bold))
                Text(m.fda ? "All set. Rover is re-indexing, and search covers every file now."
                           : "macOS hides some folders from apps until you say it's OK. Rover only reads file names and stays on your Mac.")
                    .font(.system(size: 12.5)).foregroundColor(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if m.fda {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundColor(.green)
                Button("Done") { close() }.keyboardShortcut(.defaultAction).controlSize(.large)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    step(1, "Open Privacy settings") {
                        Button(action: { Access.openSettings(); m.openedSettings = true }) {
                            Text("Open Full Disk Access").font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity)
                        }
                        .controlSize(.large).buttonStyle(.borderedProminent)
                    }
                    step(2, "Drag this into the list and switch it on") {
                        HStack(spacing: 10) {
                            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Rover").font(.system(size: 13, weight: .semibold))
                                Text("drag me ↗").font(.system(size: 11)).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                        .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                    }
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(m.openedSettings ? "Waiting for the switch… this window updates by itself." : "Rover notices as soon as access is on.")
                            .font(.system(size: 11.5)).foregroundColor(.secondary)
                    }
                }
                Divider()
                HStack {
                    Button("Only Desktop, Documents & Downloads") { m.askFolders() }.buttonStyle(.link).font(.system(size: 12))
                    Spacer()
                    Button("Later") { close() }.font(.system(size: 12))
                }
                if !m.folderState.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(Access.folders, id: \.self) { f in
                            Label(f, systemImage: m.folderState[f] == true ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundColor(m.folderState[f] == true ? .green : .orange).font(.system(size: 11.5))
                        }
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 440)
    }

    func step<C: View>(_ n: Int, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                .frame(width: 24, height: 24).background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .medium))
                content()
            }
        }
    }
}

final class AccessWindow {
    static let shared = AccessWindow()
    private var window: NSWindow?
    let model = AccessModel()
    var isVisible: Bool { window?.isVisible == true }

    func show() {
        model.fda = Access.hasFullDiskAccess
        model.onGranted = {
            DispatchQueue.global().async { Engine.shared.rebuild() }
        }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520), styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.contentView = NSHostingView(rootView: AccessView(m: model, close: { [weak self] in self?.hide() }))
            window = w
        }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.startPolling()
        UserDefaults.standard.set(true, forKey: "accessShown")
    }

    func hide() { model.stop(); window?.orderOut(nil) }
}
