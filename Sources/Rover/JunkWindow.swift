// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import AppKit
import SwiftUI
import RoverCore

/// "Free Up Space": big, old, unused files, grouped, with Trash or backup-drive moves. Nothing moves until you click.
final class JunkModel: ObservableObject {
    @Published var report: JunkReport?
    @Published var selected: Set<String> = []
    @Published var open: Set<JunkCategory> = [.installers]
    @Published var scanning = false
    @Published var volumes: [JunkFinder.Volume] = []
    @Published var status = ""
    @Published var confirmTrash = false

    func scan() {
        scanning = true; status = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let r = JunkFinder.scan(), v = JunkFinder.backupVolumes()
            DispatchQueue.main.async {
                self.report = r; self.volumes = v; self.scanning = false
                // safe picks start checked: installers and extra copies
                self.selected = Set(r.items.filter { $0.category == .installers || $0.category == .duplicates }.map { $0.path })
                self.open = Set(JunkCategory.allCases.filter { !r.items(in: $0).isEmpty }.prefix(2))
            }
        }
    }
    var chosen: [JunkItem] { report?.items.filter { selected.contains($0.path) } ?? [] }
    var chosenBytes: Int64 { chosen.reduce(0) { $0 + $1.size } }

    func trash() {
        let items = chosen
        DispatchQueue.global().async {
            let r = JunkFinder.trash(items)
            DispatchQueue.main.async { self.finish(r, "Moved to the Trash") }
        }
    }
    func backup(_ v: JunkFinder.Volume) {
        let items = chosen; status = "Copying to \(v.name)…"
        DispatchQueue.global().async {
            let r = JunkFinder.backup(items, to: v)
            DispatchQueue.main.async { self.finish(r, "Backed up to \(v.name)") }
        }
    }
    private func finish(_ r: JunkFinder.Result, _ verb: String) {
        let f = ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file)
        status = r.moved > 0 ? "\(verb): \(r.moved) item\(r.moved == 1 ? "" : "s"), \(f) freed. ⌘Z in Rover undoes it." : ""
        if !r.failed.isEmpty { status += (status.isEmpty ? "" : "  ") + "Couldn’t move \(r.failed.count): \(r.failed.first!.1)" }
        let gone = Set(chosen.map { $0.path })
        if let rep = report { report = JunkReport(items: rep.items.filter { !gone.contains($0.path) || FileManager.default.fileExists(atPath: $0.path) }, millis: rep.millis) }
        selected = selected.filter { FileManager.default.fileExists(atPath: $0) }
    }
}

private let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
private let monthYear: DateFormatter = { let d = DateFormatter(); d.dateFormat = "MMM yyyy"; return d }()

struct JunkView: View {
    @ObservedObject var m: JunkModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if m.scanning || m.report == nil {
                VStack(spacing: 10) { Spacer(); ProgressView(); Text("Looking for space you could free up…").foregroundColor(.secondary); Spacer() }.frame(maxWidth: .infinity)
            } else if m.report!.items.isEmpty {
                VStack(spacing: 10) { Spacer(); Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundColor(.green)
                    Text("Nothing worth cleaning up. Nice.").font(.system(size: 15, weight: .medium)); Spacer() }.frame(maxWidth: .infinity)
            } else {
                ScrollView { LazyVStack(spacing: 8) { ForEach(JunkCategory.allCases, id: \.self) { section($0) } }.padding(14) }
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 560)
        .alert("Move \(m.chosen.count) item\(m.chosen.count == 1 ? "" : "s") (\(fmt(m.chosenBytes))) to the Trash?", isPresented: $m.confirmTrash) {
            Button("Move to Trash", role: .destructive) { m.trash() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Nothing is deleted: you can put everything back with ⌘Z in Rover, or from the Trash until you empty it.") }
    }

    var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 26, weight: .semibold)).foregroundColor(.orange)
                .frame(width: 48, height: 48).background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                if let r = m.report, !m.scanning {
                    Text("You could free up \(fmt(r.total))").font(.system(size: 20, weight: .bold))
                    Text("Big, old and unused files. Nothing moves until you choose, and everything can be undone.")
                        .font(.system(size: 12.5)).foregroundColor(.secondary)
                } else {
                    Text("Free up space").font(.system(size: 20, weight: .bold))
                    Text("Checking your files…").font(.system(size: 12.5)).foregroundColor(.secondary)
                }
            }
            Spacer()
            Button(action: m.scan) { Image(systemName: "arrow.clockwise") }.help("Scan again").disabled(m.scanning)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    func section(_ c: JunkCategory) -> some View {
        let items = m.report?.items(in: c) ?? []
        let allOn = !items.isEmpty && items.allSatisfy { m.selected.contains($0.path) }
        return Group {
            if !items.isEmpty {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Toggle("", isOn: Binding(get: { allOn }, set: { on in
                            for it in items { if on { m.selected.insert(it.path) } else { m.selected.remove(it.path) } } })).labelsHidden()
                        Image(systemName: c.symbol).font(.system(size: 15, weight: .semibold)).foregroundColor(.accentColor).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(.system(size: 13.5, weight: .semibold))
                            Text(c.why).font(.system(size: 11.5)).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("\(items.count) · \(fmt(items.reduce(0) { $0 + $1.size }))").font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                        Image(systemName: m.open.contains(c) ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary).frame(width: 14)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .contentShape(Rectangle())
                    .onTapGesture { if m.open.contains(c) { m.open.remove(c) } else { m.open.insert(c) } }
                    if m.open.contains(c) {
                        Divider().padding(.leading, 14)
                        ForEach(items.prefix(200)) { row($0) }
                        if items.count > 200 { Text("and \(items.count - 200) more").font(.system(size: 11.5)).foregroundColor(.secondary).padding(8) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
            }
        }
    }

    func row(_ it: JunkItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { m.selected.contains(it.path) }, set: { on in if on { m.selected.insert(it.path) } else { m.selected.remove(it.path) } })).labelsHidden()
            Image(nsImage: IconCache.shared.icon(it.path)).resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(it.name.hasSuffix(".app") ? String(it.name.dropLast(4)) : it.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(it.keptCopy.map { "Copy of " + Paths.pretty($0) } ?? Paths.pretty((it.path as NSString).deletingLastPathComponent))
                    .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text("Last opened \(monthYear.string(from: Date(timeIntervalSince1970: TimeInterval(it.lastUsed))))").font(.system(size: 11)).foregroundColor(.secondary)
            Text(fmt(it.size)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 74, alignment: .trailing)
            Button(action: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: it.path)]) }) { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder")
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    var footer: some View {
        HStack(spacing: 12) {
            if !m.status.isEmpty {
                Label(m.status, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundColor(.accentColor).lineLimit(2)
            } else {
                Text(m.chosen.isEmpty ? "Choose what to clean up" : "\(m.chosen.count) selected · \(fmt(m.chosenBytes))").font(.system(size: 12.5, weight: .medium))
            }
            Spacer()
            Menu {
                if m.volumes.isEmpty { Text("Connect an external drive to back up to it") }
                ForEach(m.volumes, id: \.self) { v in Button("\(v.name) (\(fmt(v.free)) free)") { m.backup(v) } }
            } label: { Label("Move to Backup Drive", systemImage: "externaldrive.badge.plus") }
            .fixedSize().disabled(m.chosen.isEmpty)
            .help("Copies each file to “Rover Backup” on the drive, checks the copy, then moves the original to the Trash")
            Button(action: { m.confirmTrash = true }) { Label("Move to Trash", systemImage: "trash") }
                .keyboardShortcut(.defaultAction).disabled(m.chosen.isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

final class JunkWindow {
    static let shared = JunkWindow()
    private var window: NSWindow?
    let model = JunkModel()
    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Free Up Space"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: JunkView(m: model))
            window = w
        }
        if !(window?.isVisible ?? false) { window?.center() }
        if !model.scanning { model.scan() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
