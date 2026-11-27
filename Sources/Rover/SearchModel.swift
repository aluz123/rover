// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import AppKit
import Carbon.HIToolbox
import RoverCore

struct Turn: Identifiable {
    let id = UUID()
    var question: String
    var answer = ""
    var status = ""
    var files: [Hit] = []
    var proposal: Assistant.Proposal?
    var proposalState = 0 // 0 pending, 1 approved, 2 declined
    var error: String?
    var running = true
}

final class SearchModel: ObservableObject {
    enum Mode { case search, moveTo, rename, ask }

    @Published var mode: Mode = .search
    @Published var text = "" { didSet { if text != oldValue { textChanged() } } }
    @Published var hits: [Hit] = [] { didSet { version &+= 1 } }
    @Published var version = 0
    @Published var limitedAccess = false
    @Published var selected = 0
    @Published var marked: Set<String> = []
    @Published var chips: [String] = []
    @Published var expanded: [String] = []
    @Published var stats = ""
    @Published var heading = ""
    @Published var toast: String?
    @Published var focusToken = 0
    @Published var selectAllToken = 0
    @Published var contentLoading = false
    @Published var showPreview = UserDefaults.standard.object(forKey: "showPreview") as? Bool ?? true
    @Published var turns: [Turn] = []
    @Published var askSelected = 0

    var previewing = false
    /// Row under the mouse, and where the mouse was at the last key press (to tell real hovering from rows sliding under a still cursor).
    var hovered: Int?
    private var mouseAtKey = NSPoint(x: -1, y: -1)
    private var spaceArmed = false
    let assistant = Assistant()
    private var gen = 0
    private var savedSearch = ""
    private var moveItems: [Hit] = []
    private var renameItem: Hit?
    private let q = DispatchQueue(label: "rover.search", qos: .userInteractive)

    init() { schedule() }

    /// Files changed somewhere. While the panel is hidden nobody is looking, so just remember the results are stale
    /// (re-searching on every file change was burning CPU in the menu bar). While it's open, refresh at most every 1.5 s.
    private var stale = false
    private var refreshQueued = false
    func engineChanged() {
        guard mode == .search || mode == .moveTo else { return }
        guard AppDelegate.shared?.panel?.isVisible == true else { stale = true; return }
        if refreshQueued { return }
        refreshQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            self.refreshQueued = false
            if AppDelegate.shared?.panel?.isVisible == true { self.schedule() } else { self.stale = true }
        }
    }
    func panelShown() { if stale { stale = false; schedule() } }

    private func textChanged() {
        switch mode {
        case .search, .moveTo: schedule()
        case .rename, .ask: break
        }
    }

    var placeholder: String {
        switch mode {
        case .search: return "Find anything… try “pdf from last week” or “invoice in downloads”"
        case .moveTo: return moveItems.count == 1 ? "Move “\(moveItems[0].name)” to… (type a folder)" : "Move \(moveItems.count) items to… (type a folder)"
        case .rename: return "New name"
        case .ask: return turns.isEmpty ? "Ask about your files, or tell Rover what to organize…" : "Ask a follow-up…"
        }
    }

    // MARK: search

    static func isFreeUpPhrase(_ t: String) -> Bool {
        ["free up space", "free space", "free up", "junk", "clean up", "cleanup", "disk space", "storage", "clear space"]
            .contains(t.lowercased().trimmingCharacters(in: .whitespaces))
    }

    /// "~/Documents/Inv" or "/Users/me/Down": behave like Finder's Go to Folder (contents, or names that start with what's typed).
    static func isPathQuery(_ t: String) -> Bool {
        let x = t.trimmingCharacters(in: .whitespaces)
        return x.hasPrefix("/") || x.hasPrefix("~/") || x == "~" || (x.contains("/") && !x.hasPrefix("*") && x.count > 2)
    }
    static func pathHits(_ t: String) -> (hits: [Hit], folder: String)? {
        guard isPathQuery(t) else { return nil }
        var raw = t.trimmingCharacters(in: .whitespaces)
        // a relative path ("acme/reports/2026/"): relative to home if it exists there, else the indexed folder whose path ends with it
        if !raw.hasPrefix("/") && !raw.hasPrefix("~") {
            let trail = raw.hasSuffix("/") ? "/" : ""
            if FileManager.default.fileExists(atPath: NSHomeDirectory() + "/" + raw) { raw = "~/" + raw }
            else if let full = Engine.shared.folders(endingWith: raw).first { raw = full + trail }
            else {
                // the last part is still being typed: find the parent, then match what's typed inside it
                let parentFrag = (raw as NSString).deletingLastPathComponent, last = (raw as NSString).lastPathComponent
                if !parentFrag.isEmpty, let parent = Engine.shared.folders(endingWith: parentFrag).first { raw = parent + "/" + last }
                else { return nil }   // not a real path ("invoice 11/20"): search normally
            }
        }
        let p = Paths.expand(raw)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        func list(_ dir: String, prefix: String) -> [String] {
            let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            return names.filter { !$0.hasPrefix(".") && (prefix.isEmpty || $0.lowercased().hasPrefix(prefix)) }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }.prefix(80).map { (dir as NSString).appendingPathComponent($0) }
        }
        if fm.fileExists(atPath: p, isDirectory: &isDir) {
            if !isDir.boolValue { return (Assistant.hits(for: [p]), (p as NSString).deletingLastPathComponent) }   // a file: just it
            if raw.hasSuffix("/") || raw == "~" {                                                             // "~/Documents/": what's inside
                return (sortFoldersFirst(Assistant.hits(for: list(p, prefix: "")), keepFirst: false), p)
            }
            // "~/Documents": the folder itself first (↩ opens it), then what's inside
            return (sortFoldersFirst(Assistant.hits(for: [p] + list(p, prefix: "")), keepFirst: true), p)
        }
        let parent = (p as NSString).deletingLastPathComponent, prefix = (p as NSString).lastPathComponent.lowercased()
        guard fm.fileExists(atPath: parent, isDirectory: &isDir), isDir.boolValue else { return ([], parent) }
        return (sortFoldersFirst(Assistant.hits(for: list(parent, prefix: prefix)), keepFirst: false), parent)
    }
    static func tilde(_ p: String) -> String { let h = NSHomeDirectory(); return p.hasPrefix(h + "/") ? "~" + p.dropFirst(h.count) : p }
    static func sortFoldersFirst(_ h: [Hit], keepFirst: Bool) -> [Hit] {
        guard h.count > 1 else { return h }
        let head = keepFirst ? [h[0]] : [], rest = keepFirst ? Array(h.dropFirst()) : h
        return head + rest.filter { $0.isDir } + rest.filter { !$0.isDir }
    }

    /// Replace the list only when the results really changed (rebuilding it every refresh made the panel flash).
    private func setHits(_ new: [Hit]) {
        if new.map({ $0.path }) != hits.map({ $0.path }) { hits = new }
    }
    private var contentFor = "", contentCache: [Hit] = []

    func schedule() {
        gen += 1
        let g = gen, t = text, m = mode
        if m == .search, Transfers.ticket(in: t) != nil {
            setHits([]); chips = []; expanded = []; contentLoading = false
            heading = "↩ Receive the files in this Rover link (they go to Downloads)"
            stats = "Direct, encrypted transfer"
            return
        }
        if m == .search, let ph = Self.pathHits(t) {
            setHits(ph.hits)
            if t != lastText { selected = 0; marked = [] }
            lastText = t
            chips = []; expanded = []; contentLoading = false
            heading = ph.hits.isEmpty ? "No such folder" : "Go to folder · ⇥ completes the path"
            stats = "\(ph.hits.count) items in \(Paths.pretty(ph.folder))"
            return
        }
        q.async {
            let e = Engine.shared
            let empty = t.trimmingCharacters(in: .whitespaces).isEmpty
            if m == .moveTo {
                let hits = empty ? Self.suggestedDestinations() : e.search(t + " folders", limit: 40).hits
                DispatchQueue.main.async {
                    guard g == self.gen else { return }
                    self.hits = hits; self.selected = 0; self.chips = []; self.expanded = []; self.contentLoading = false
                    self.heading = empty ? "Recent and common folders" : ""
                    self.stats = "↩ move here · type a path like ~/Documents/New Folder to create it"
                }
                return
            }
            let r = e.search(empty ? "recent" : t, limit: 60)
            let pins = empty && License.isPro ? Assistant.hits(for: Pins.all) : []
            // Rover Pro: text in screenshots/images, what's in photos, and files on drives that aren't plugged in
            let seen = Set(r.hits.map { $0.path })
            let imageHits = !empty && License.isPro ? ImageIndex.shared.hits(for: r.query, excluding: seen) : []
            let driveHits = !empty && License.isPro ? DriveCatalog.shared.hits(for: r.query, excluding: seen) : []
            let imageFirst = r.query.kinds.contains(.image) || (r.hits.first?.score ?? 0) < 160
            DispatchQueue.main.async {
                guard g == self.gen else { return }
                let keep = self.hits.indices.contains(self.selected) ? self.hits[self.selected].path : nil
                let sameText = t == self.lastText
                var merged = (sameText && self.contentFor == t) ? r.hits + self.contentCache.filter { c in !r.hits.contains { $0.path == c.path } } : r.hits
                if !pins.isEmpty { merged = pins + merged.filter { h in !pins.contains { $0.path == h.path } } }
                let fresh = imageHits.filter { h in !merged.contains { $0.path == h.path } }
                merged = imageFirst ? fresh + merged : merged + fresh
                merged += driveHits.filter { h in !merged.contains { $0.path == h.path } }
                self.setHits(merged)
                self.selected = keep.flatMap { k in self.hits.firstIndex { $0.path == k } } ?? 0
                if t != self.lastText { self.selected = 0; self.marked = [] }
                self.lastText = t
                self.chips = empty ? [] : r.query.chips
                self.expanded = r.expanded
                self.heading = empty ? (pins.isEmpty ? "Recently changed" : "Pinned (⌘D) · then recently changed") : (Self.isFreeUpPhrase(t) ? "↩ Open Free Up Space: find big, old files you don't need" + (License.isPro ? "" : " (Rover Pro)") : "")
                if Self.isFreeUpPhrase(t) { self.chips = [] }
                self.contentLoading = false
                if !e.isReady { self.stats = e.status }
                else if empty { self.stats = "\(e.fileCount.formatted()) files" }
                else { self.stats = "\(r.total.formatted()) matches · \(String(format: "%.0f", max(1, r.millis))) ms" }
                if !imageHits.isEmpty { self.stats += " · \(imageHits.count) in images" }
                if !driveHits.isEmpty { self.stats += " · \(driveHits.count) on drives" }
                if !empty && !(sameText && self.contentFor == t) { self.scheduleContent(g, t, r) }
                if sameText && self.contentFor == t && !self.contentCache.isEmpty { self.stats += " · \(self.contentCache.count) inside files" }
            }
        }
    }
    private var lastText = ""

    private func scheduleContent(_ g: Int, _ t: String, _ r: SearchResult) {
        let wantContent = !r.query.contentWords.isEmpty || r.hits.count < 12 || (r.hits.first?.score ?? 0) < 160
        guard wantContent else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard g == self.gen else { return }
            self.contentLoading = true
            Engine.shared.contentSearch(r.query, excluding: Set(r.hits.map { $0.path })) { content in
                DispatchQueue.main.async {
                    guard g == self.gen else { return }
                    self.contentLoading = false
                    self.contentFor = t; self.contentCache = content
                    if content.isEmpty { return }
                    let sel = self.current?.path
                    if !r.query.contentWords.isEmpty { self.hits = content + self.hits } else { self.hits += content }
                    if let sel = sel, let i = self.hits.firstIndex(where: { $0.path == sel }) { self.selected = i }
                    self.stats += " · \(content.count) inside files"
                }
            }
        }
    }

    static func suggestedDestinations() -> [Hit] {
        let home = NSHomeDirectory()
        var paths = (UserDefaults.standard.stringArray(forKey: "recentDest") ?? [])
        paths += ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"].map { home + "/" + $0 }
        if FileManager.default.fileExists(atPath: Paths.icloudRoot) { paths.append(Paths.icloudRoot) }
        var seen = Set<String>()
        return Assistant.hits(for: paths.filter { seen.insert($0).inserted })
    }

    // MARK: selection

    var listHits: [Hit] {
        if mode == .ask { return turns.last?.files ?? [] }
        return hits
    }
    var selIndex: Int { mode == .ask ? askSelected : selected }
    var current: Hit? { let l = listHits; return l.indices.contains(selIndex) ? l[selIndex] : nil }
    var targets: [Hit] {
        if mode == .search, !marked.isEmpty { return hits.filter { marked.contains($0.path) } }
        return current.map { [$0] } ?? []
    }

    func move(_ d: Int, extend: Bool = false) {
        let l = listHits
        guard !l.isEmpty else { return }
        if extend && mode == .search, let c = current { marked.insert(c.path) }
        let n = max(0, min(l.count - 1, selIndex + d))
        if mode == .ask { askSelected = n } else { selected = n }
        if let c = current { QuickLook.shared.follow(c.path) }
        if extend && mode == .search, let c = current { marked.insert(c.path) }
    }

    func select(_ i: Int) { if mode == .ask { askSelected = i } else { selected = i } }
    func toggleMark(_ i: Int) {
        guard mode == .search, hits.indices.contains(i) else { return }
        let p = hits[i].path
        if marked.contains(p) { marked.remove(p) } else { marked.insert(p) }
        selected = i
    }

    // MARK: file actions (all local, no AI)

    func open() {
        guard let h = current else { return }
        if h.source == .drive && !FileManager.default.fileExists(atPath: h.path) { flash("That file is \(h.why.replacingOccurrences(of: " · not plugged in", with: "")). Plug the drive in to open it."); return }
        Engine.shared.recordOpen(h.path, query: text)
        AppDelegate.shared.hide()
        NSWorkspace.shared.open(URL(fileURLWithPath: h.path))
    }

    func reveal() {
        let ts = targets
        guard !ts.isEmpty else { return }
        for h in ts { Engine.shared.recordOpen(h.path, query: text) }
        AppDelegate.shared.hide()
        NSWorkspace.shared.activateFileViewerSelecting(ts.map { URL(fileURLWithPath: $0.path) })
    }

    func copyPath() {
        let ts = targets
        guard !ts.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ts.map { $0.path }.joined(separator: "\n"), forType: .string)
        flash(ts.count == 1 ? "Copied path" : "Copied \(ts.count) paths")
    }

    func copyFiles() {
        let ts = targets
        guard !ts.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(ts.map { URL(fileURLWithPath: $0.path) as NSURL })
        flash(ts.count == 1 ? "Copied — paste in Finder" : "Copied \(ts.count) files — paste in Finder")
    }

    func quickLook() {
        let ts = targets
        guard !ts.isEmpty else { return }
        if QuickLook.shared.isOpen { QuickLook.shared.close(); return }
        previewing = true
        QuickLook.shared.onClose = { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.previewing = false
                if !AppDelegate.shared.panel.isKeyWindow && AppDelegate.shared.panel.isVisible { AppDelegate.shared.panel.makeKey() }
            }
        }
        QuickLook.shared.onArrow = { [weak self] d in self?.move(d) }
        QuickLook.shared.show(ts.map { $0.path }, above: AppDelegate.shared.panel)
    }

    func hover(_ i: Int, _ inside: Bool) {
        if inside { hovered = i } else if hovered == i { hovered = nil }
    }

    func togglePreview() {
        showPreview.toggle()
        UserDefaults.standard.set(showPreview, forKey: "showPreview")
        AppDelegate.shared.resizeForPreview()
    }

    /// ⌘D: pin or unpin (Rover Pro). Pins show first whenever the search box is empty.
    func togglePin() {
        guard mode == .search, let h = current else { return }
        guard License.isPro else { flash("Pinned files come with Rover Pro · opening…"); ProWindow.shared.show(); return }
        flash(Pins.toggle(h.path) ? "Pinned “\(h.name)” · shows first when the box is empty" : "Unpinned “\(h.name)”")
        if text.trimmingCharacters(in: .whitespaces).isEmpty { schedule() }
    }

    /// ⌘S: send the selected (or marked) files straight to another Mac (Rover Pro).
    func sendSelected() {
        let ts = targets.filter { $0.source != .drive || FileManager.default.fileExists(atPath: $0.path) }
        guard !ts.isEmpty else { flash("Select a file or folder to send"); return }
        guard License.isPro else { flash("Sending files comes with Rover Pro · opening…"); ProWindow.shared.show(); return }
        AppDelegate.shared.hide(keepApp: true)
        ShareWindow.shared.show(ts.map { $0.path })
    }

    func trash() {
        let ts = targets
        guard !ts.isEmpty else { return }
        let acts = ts.map { FileAction(op: .trash, path: $0.path) }
        let res = ActionRunner.shared.run(acts, title: ts.count == 1 ? "Trash \(ts[0].name)" : "Trash \(ts.count) items")
        finishActions(res, verb: "Moved to Trash")
    }

    func startMove() {
        let ts = targets
        guard !ts.isEmpty else { return }
        moveItems = ts
        savedSearch = text
        mode = .moveTo
        text = ""
        schedule()
        focusToken += 1
    }

    func startRename() {
        guard mode == .search, let h = current else { return }
        renameItem = h
        savedSearch = text
        mode = .rename
        text = h.name
        hits = [h]; selected = 0
        focusToken += 1
        renameSelectToken += 1
    }
    @Published var renameSelectToken = 0

    func commit() {
        switch mode {
        case .search:
            if text.hasSuffix("?") { startAsk(); return }
            if Transfers.ticket(in: text) != nil { Transfers.shared.receive(text); text = ""; AppDelegate.shared.hide(keepApp: true); return }
            if Self.isFreeUpPhrase(text) {
                AppDelegate.shared.hide(keepApp: true)
                JunkWindow.shared.show()
                return
            }
            open()
        case .moveTo:
            var dest: String?
            let t = text.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("~") || t.hasPrefix("/") { dest = Paths.expand(t) }
            else if let h = current, h.isDir { dest = h.path }
            guard let d = dest else { flash("Pick a folder"); return }
            let acts = moveItems.map { FileAction(op: .move, path: $0.path, to: d) }
            let res = ActionRunner.shared.run(acts, title: "Move \(moveItems.count) item\(moveItems.count == 1 ? "" : "s") to \((d as NSString).lastPathComponent)")
            var recent = UserDefaults.standard.stringArray(forKey: "recentDest") ?? []
            recent.removeAll { $0 == d }; recent.insert(d, at: 0)
            UserDefaults.standard.set(Array(recent.prefix(12)), forKey: "recentDest")
            backToSearch()
            finishActions(res, verb: "Moved to \(Paths.pretty(d))")
        case .rename:
            guard let h = renameItem else { backToSearch(); return }
            let n = text.trimmingCharacters(in: .whitespaces)
            if n.isEmpty || n == h.name { backToSearch(); return }
            let res = ActionRunner.shared.run([FileAction(op: .rename, path: h.path, name: n)], title: "Rename \(h.name)")
            backToSearch()
            finishActions(res, verb: "Renamed")
        case .ask:
            let t = text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { open() } else { ask(t) }
        }
    }

    private func finishActions(_ res: [ActionRunner.Outcome], verb: String) {
        let ok = res.filter { $0.ok }
        for o in res { Engine.shared.touched(o.action.path); if let r = o.resultPath { Engine.shared.touched(r) } }
        marked = []
        if let fail = res.first(where: { !$0.ok }) { flash("\(ok.count) done · couldn't: \(fail.message)") }
        else { flash("\(verb)\(ok.count > 1 ? " (\(ok.count))" : "") · ⌘Z to undo") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.schedule() }
    }

    func undo() {
        guard ActionRunner.shared.canUndo else { flash("Nothing to undo"); return }
        let msg = ActionRunner.shared.undoLast()
        flash(msg)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { Engine.shared.touched(NSHomeDirectory() + "/x"); self.schedule() }
    }

    func backToSearch() {
        mode = .search
        text = savedSearch
        moveItems = []; renameItem = nil
        schedule()
        focusToken += 1
    }

    func flash(_ s: String) {
        toast = s
        let t = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if self.toast == t { self.toast = nil } }
    }

    // MARK: assistant

    func startAsk() {
        let t = text.trimmingCharacters(in: .whitespaces)
        savedSearch = text
        if mode != .ask {
            mode = .ask
            if !turns.isEmpty && !assistant.hasConversation { turns = [] }
        }
        if !t.isEmpty { ask(t) }
        focusToken += 1
    }

    func ask(_ q: String) {
        let context = turns.isEmpty ? Array(hits.prefix(12)) : []
        turns.append(Turn(question: q))
        text = ""
        askSelected = 0
        let idx = turns.count - 1
        assistant.ask(q, context: context) { [weak self] ev in
            guard let self = self, self.turns.indices.contains(idx) else { return }
            switch ev {
            case .text(let s): self.turns[idx].answer += s; self.turns[idx].status = ""
            case .status(let s): self.turns[idx].status = s
            case .files(let hs, _): self.turns[idx].files = hs; self.askSelected = 0
            case .proposal(let p): self.turns[idx].proposal = p; self.turns[idx].status = ""
            case .done(let err): self.turns[idx].running = false; self.turns[idx].status = ""; self.turns[idx].error = err
            }
        }
    }

    func approve(_ ok: Bool) {
        guard let i = turns.indices.last, turns[i].proposal != nil, turns[i].proposalState == 0 else { return }
        turns[i].proposalState = ok ? 1 : 2
        assistant.respond(approved: ok)
        if ok { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.schedule() } }
    }

    func leaveAsk() {
        if turns.last?.running == true { assistant.cancel(); return }
        assistant.reset()
        turns = []
        backToSearch()
    }

    // MARK: keys

    func handleKey(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command), opt = e.modifierFlags.contains(.option), shift = e.modifierFlags.contains(.shift)
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let code = Int(e.keyCode)
        let ctrl = e.modifierFlags.contains(.control)
        // Space = Quick Look, Finder-style, when you are pointing at a result or moving with the arrows.
        // While you are typing, Space is just a space.
        let mouse = NSEvent.mouseLocation
        let mouseMoved = mouse != mouseAtKey
        mouseAtKey = mouse
        if code == kVK_Space && !cmd && !opt && !ctrl {
            if QuickLook.shared.isOpen { QuickLook.shared.close(); spaceArmed = true; return true }
            if mode == .search || mode == .ask {
                if mode == .search, mouseMoved, let h = hovered, h < listHits.count { select(h); spaceArmed = true; quickLook(); return true }
                if spaceArmed, current != nil { quickLook(); return true }
            }
            return false
        }
        if code == kVK_Escape && QuickLook.shared.isOpen { QuickLook.shared.close(); return true }
        switch code {
        case kVK_DownArrow, kVK_UpArrow, kVK_PageDown, kVK_PageUp: spaceArmed = true
        case kVK_Shift, kVK_Command, kVK_Option, kVK_Control: break
        default: spaceArmed = false; if QuickLook.shared.isOpen && !cmd { QuickLook.shared.close() }
        }
        if cmd, let i = digits.firstIndex(of: code) { if i < listHits.count { select(i); open() }; return true }
        switch code {
        case kVK_DownArrow: move(cmd ? 1000 : 1, extend: shift); return true
        case kVK_UpArrow: move(cmd ? -1000 : -1, extend: shift); return true
        case kVK_PageDown: move(8); return true
        case kVK_PageUp: move(-8); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if cmd && mode == .ask, turns.last?.proposalState == 0, turns.last?.proposal != nil { approve(true); return true }
            if cmd { reveal() } else if opt { copyPath() } else { commit() }
            return true
        case kVK_Tab:
            if mode == .search && Self.isPathQuery(text) {
                if let h = current { text = Self.tilde(h.path) + (h.isDir ? "/" : "") }
                return true
            }
            if mode == .ask { leaveAsk() } else if mode == .search { startAsk() }
            return true
        case kVK_Escape:
            switch mode {
            case .search: if text.isEmpty { AppDelegate.shared.hide() } else { text = "" }
            case .moveTo, .rename: backToSearch()
            case .ask: leaveAsk()
            }
            return true
        default: break
        }
        guard cmd else { return false }
        switch code {
        case kVK_ANSI_Y: quickLook(); return true
        case kVK_ANSI_P: togglePreview(); return true
        case kVK_ANSI_M: if mode != .rename { startMove() }; return true
        case kVK_ANSI_R: startRename(); return true
        case kVK_Delete: if mode == .search || mode == .ask { trash() }; return true
        case kVK_ANSI_Z where !shift: undo(); return true
        case kVK_ANSI_C where opt: copyPath(); return true
        case kVK_ANSI_C where shift: copyFiles(); return true
        case kVK_ANSI_O: reveal(); return true
        case kVK_ANSI_D: togglePin(); return true
        case kVK_ANSI_S: sendSelected(); return true
        default: return false
        }
    }
}
