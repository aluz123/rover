// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import AppKit
import SwiftUI
import RoverCore

// MARK: views

struct SearchView: View {
    @ObservedObject var model: SearchModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                Group {
                    if model.mode == .ask { AskView(model: model) } else { resultsList }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                if model.showPreview {
                    Divider().opacity(0.5)
                    PreviewPane(hit: model.current, model: model).frame(width: 400)
                }
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: modeIcon).font(.system(size: 21, weight: .medium))
                    .foregroundColor(model.mode == .search ? .secondary : .accentColor).frame(width: 26)
                if let badge = modeBadge {
                    Text(badge).font(.system(size: 11, weight: .bold)).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18))).foregroundColor(.accentColor)
                }
                SearchField(text: $model.text, placeholder: model.placeholder, focusToken: model.focusToken,
                            selectAllToken: model.selectAllToken, selectStemToken: model.renameSelectToken)
                    .frame(height: 30)
                if model.contentLoading || model.turns.last?.running == true && model.mode == .ask { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)
            if model.mode != .ask && (!model.chips.isEmpty || !model.expanded.isEmpty || !model.heading.isEmpty) {
                HStack(spacing: 6) {
                    if !model.heading.isEmpty { Text(model.heading).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary) }
                    ForEach(model.chips, id: \.self) { Chip(text: $0) }
                    if !model.expanded.isEmpty {
                        Text("also: " + model.expanded.prefix(4).joined(separator: ", ")).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if !model.marked.isEmpty {
                        Text("\(model.marked.count) selected").font(.system(size: 11, weight: .semibold)).foregroundColor(.accentColor)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 8)
            }
        }
    }

    var modeIcon: String {
        switch model.mode { case .search: return "magnifyingglass"; case .moveTo: return "folder"; case .rename: return "pencil"; case .ask: return "sparkles" }
    }
    var modeBadge: String? {
        switch model.mode { case .search: return nil; case .moveTo: return "MOVE TO"; case .rename: return "RENAME"; case .ask: return "ASK" }
    }

    var resultsList: some View {
        Group {
            if model.hits.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: Engine.shared.isReady ? "doc.text.magnifyingglass" : "hourglass")
                        .font(.system(size: 34)).foregroundColor(.secondary.opacity(0.6))
                    Text(emptyText).foregroundColor(.secondary).font(.system(size: 13)).multilineTextAlignment(.center)
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.hits.enumerated()), id: \.element.id) { i, h in
                                Row(hit: h, selected: i == model.selected, marked: model.marked.contains(h.path), index: i)
                                    .id("r\(i)")
                                    .contentShape(Rectangle())
                                    .gesture(TapGesture(count: 2).onEnded { model.select(i); model.mode == .moveTo ? model.commit() : model.open() })
                                    .simultaneousGesture(TapGesture().modifiers(.command).onEnded { model.toggleMark(i) })
                                    .simultaneousGesture(TapGesture().onEnded { model.select(i) })
                                    .onDrag { NSItemProvider(object: URL(fileURLWithPath: h.path) as NSURL) }
                                    .contextMenu { RowMenu(model: model, index: i) }
                                    .onHover { model.hover(i, $0) }
                            }
                        }
                        .id(model.version)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                    .onChange(of: model.selected) { s in withAnimation(.easeOut(duration: 0.08)) { proxy.scrollTo("r\(s)") } }
                }
            }
        }
    }

    var footer: some View {
        HStack(spacing: 14) {
            if let t = model.toast {
                Label(t, systemImage: "checkmark.circle.fill").foregroundColor(.accentColor).lineLimit(1)
            } else {
                Text(model.stats).lineLimit(1)
            }
            if model.limitedAccess && model.mode == .search && model.toast == nil {
                Button(action: { AccessWindow.shared.show() }) {
                    Label("Can't see some folders · Give access", systemImage: "lock.open").font(.system(size: 11, weight: .medium))
                }.buttonStyle(.plain).foregroundColor(.orange)
            }
            Spacer()
            switch model.mode {
            case .search:
                Hint(keys: "↩", label: "open"); Hint(keys: "⌘↩", label: "show in Finder"); Hint(keys: "⌘M", label: "move")
                Hint(keys: "space", label: "preview"); Hint(keys: "⇥", label: "ask")
            case .moveTo:
                Hint(keys: "↩", label: "move here"); Hint(keys: "esc", label: "cancel")
            case .rename:
                Hint(keys: "↩", label: "rename"); Hint(keys: "esc", label: "cancel")
            case .ask:
                Hint(keys: "↩", label: model.text.isEmpty ? "open file" : "send"); Hint(keys: "⌘↩", label: "show in Finder"); Hint(keys: "esc", label: "back to search")
            }
        }
        .font(.system(size: 11)).foregroundColor(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    var emptyText: String {
        if !Engine.shared.isReady { return "Indexing your Mac for the first time…\nThis takes a minute, then search is instant." }
        if model.mode == .moveTo { return "No folder by that name.\nType a path like ~/Documents/New Folder to create one." }
        if model.contentLoading { return "Looking inside files…" }
        return "Nothing found.\nPut words in \"quotes\" to search inside files, or press ⇥ Tab to ask Rover."
    }
}

struct RowMenu: View {
    @ObservedObject var model: SearchModel
    let index: Int
    var body: some View {
        Group {
            Button("Open") { model.select(index); model.open() }
            Button("Show in Finder") { model.select(index); model.reveal() }
            Button("Quick Look") { model.select(index); model.quickLook() }
            Divider()
            Button("Move to…") { model.select(index); model.startMove() }
            Button("Rename…") { model.select(index); model.startRename() }
            Button("Copy") { model.select(index); model.copyFiles() }
            Button("Copy Path") { model.select(index); model.copyPath() }
            Divider()
            Button("Move to Trash") { model.select(index); model.trash() }
        }
    }
}

struct Chip: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
            .foregroundColor(.accentColor)
    }
}

struct Hint: View {
    let keys: String, label: String
    var body: some View {
        HStack(spacing: 4) {
            Text(keys).font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
            Text(label)
        }
    }
}

enum Fmt {
    static let home = NSHomeDirectory()
    static let icloud = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"
    static func folder(_ path: String) -> String {
        var p = (path as NSString).deletingLastPathComponent
        if p.hasPrefix(icloud) { p = "iCloud Drive" + p.dropFirst(icloud.count) }
        else if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
        return p
    }
    static let rel: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f }()
    static let day: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f }()
    static func date(_ t: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(t))
        let age = Date().timeIntervalSince(d)
        if age < 60 { return "just now" }
        if age < 86400 * 7 { return rel.localizedString(for: d, relativeTo: Date()) }
        return day.string(from: d)
    }
    static func size(_ h: Hit) -> String { h.isDir || h.size == 0 ? "" : ByteCountFormatter.string(fromByteCount: h.size, countStyle: .file) }
}

final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()
    func icon(_ path: String) -> NSImage {
        if let i = cache.object(forKey: path as NSString) { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 32, height: 32)
        cache.setObject(i, forKey: path as NSString)
        return i
    }
}

struct Row: View {
    let hit: Hit
    let selected: Bool
    var marked = false
    let index: Int
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.shared.icon(hit.path)).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hit.path == Paths.icloudRoot ? "iCloud Drive" : (hit.kind == .app && hit.name.hasSuffix(".app") ? String(hit.name.dropLast(4)) : hit.name)).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if hit.source == .content {
                        Text("in contents").font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(selected ? 0.35 : 0.18)))
                            .foregroundColor(selected ? .white : .orange)
                    }
                }
                Text(hit.kind == .app && hit.name.hasSuffix(".app") ? "Application" : Fmt.folder(hit.path)).font(.system(size: 11)).lineLimit(1).truncationMode(.head)
                    .foregroundColor(selected ? .white.opacity(0.85) : .secondary)
            }
            Spacer(minLength: 8)
            if !(hit.kind == .app && hit.name.hasSuffix(".app")) {   // apps stay clean, like Spotlight
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.date(hit.mtime)).font(.system(size: 11))
                    Text(Fmt.size(hit)).font(.system(size: 10.5))
                }
                .foregroundColor(selected ? .white.opacity(0.85) : .secondary)
            }
            if index < 9 {
                Text("⌘\(index + 1)").font(.system(size: 10, weight: .medium)).frame(width: 24)
                    .foregroundColor(selected ? .white.opacity(0.7) : .secondary.opacity(0.6))
            } else { Spacer().frame(width: 24) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .foregroundColor(selected ? .white : .primary)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : (marked ? Color.accentColor.opacity(0.18) : Color.clear)))
    }
}

/// Large borderless text field with reliable focus handling.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusToken: Int
    var selectAllToken: Int
    var selectStemToken: Int

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        var lastFocus = -1, lastSelect = -1, lastStem = 0
        init(_ p: SearchField) { parent = p }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSTextField { parent.text = f.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            // let the panel's key monitor handle arrows/return
            [#selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertTab(_:)), #selector(NSResponder.cancelOperation(_:))].contains(sel)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = .systemFont(ofSize: 22, weight: .regular)
        f.delegate = context.coordinator
        f.cell?.usesSingleLineMode = true
        f.cell?.lineBreakMode = .byTruncatingTail
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.placeholderString != placeholder { f.placeholderString = placeholder }
        if f.stringValue != text { f.stringValue = text }
        if context.coordinator.lastStem != selectStemToken {
            context.coordinator.lastStem = selectStemToken
            DispatchQueue.main.async {
                f.window?.makeFirstResponder(f)
                let stem = (text as NSString).deletingPathExtension
                f.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
            }
        }
        if context.coordinator.lastFocus != focusToken {
            context.coordinator.lastFocus = focusToken
            DispatchQueue.main.async {
                f.window?.makeFirstResponder(f)
                if context.coordinator.lastSelect != selectAllToken {
                    context.coordinator.lastSelect = selectAllToken
                    f.currentEditor()?.selectAll(nil)
                }
            }
        }
    }
}
