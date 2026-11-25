// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import Foundation

/// A single file operation the assistant (or a rule) wants to perform.
public struct FileAction: Codable, Identifiable, Hashable {
    public enum Op: String, Codable { case move, rename, copy, trash, mkdir, tag }
    public var id = UUID()
    public var op: Op
    public var path: String
    public var to: String?      // destination folder (move/copy)
    public var name: String?    // new name (rename) or optional new name for move/copy
    public var tag: String?     // Finder tag (tag)

    public init(op: Op, path: String, to: String? = nil, name: String? = nil, tag: String? = nil) {
        self.op = op; self.path = path; self.to = to; self.name = name; self.tag = tag
    }

    public var summary: String {
        let n = (path as NSString).lastPathComponent
        switch op {
        case .move: return "Move \(n) → \(Paths.pretty(to ?? ""))" + (name.map { " as \($0)" } ?? "")
        case .rename: return "Rename \(n) → \(name ?? "")"
        case .copy: return "Copy \(n) → \(Paths.pretty(to ?? ""))"
        case .trash: return "Move \(n) to Trash"
        case .mkdir: return "Create folder \(Paths.pretty(path))"
        case .tag: return "Tag \(n) “\(tag ?? "")”"
        }
    }
}

public enum Paths {
    public static let home = NSHomeDirectory()
    static let icloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
    public static var icloudRoot: String { icloud }

    public static func expand(_ p: String) -> String {
        var s = p.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("iCloud Drive") { s = icloud + s.dropFirst("iCloud Drive".count) }
        return ((s as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    public static func pretty(_ p: String) -> String {
        if let demo = ProcessInfo.processInfo.environment["ROVER_DEMO_HOME"] {   // demo footage: the fake home reads as ~
            for h in [demo, demo.hasPrefix("/private/") ? String(demo.dropFirst(8)) : "/private" + demo] where p == h || p.hasPrefix(h + "/") { return "~" + p.dropFirst(h.count) }
        }
        if p.hasPrefix(icloud) { return "iCloud Drive" + p.dropFirst(icloud.count) }
        if p.hasPrefix(home) { return "~" + p.dropFirst(home.count) }
        return p
    }

    static let protectedRoots: Set<String> = ["", "/Desktop", "/Documents", "/Downloads", "/Pictures", "/Movies", "/Music",
                                              "/Library", "/Applications", "/Public", "/Sites"]

    /// Writable = inside home (or iCloud Drive), not Library, not inside an app bundle or a .git folder.
    public static func checkWritable(_ p: String) -> String? {
        let inICloud = p == icloud || p.hasPrefix(icloud + "/")
        guard inICloud || p.hasPrefix(home + "/") else { return "outside your home folder" }
        if !inICloud && (p.hasPrefix(home + "/Library/") || p == home + "/Library") { return "inside ~/Library" }
        if protectedRoots.contains(String(p.dropFirst(home.count))) || p == icloud { return "a top-level system folder" }
        let comps = p.split(separator: "/")
        if comps.contains(where: { $0 == ".git" || $0.hasSuffix(".app") || $0 == "node_modules" }) { return "inside an app bundle or repository internals" }
        return nil
    }

    /// Free name in folder: "Report.pdf" -> "Report 2.pdf" if taken.
    static func freeName(_ name: String, in dir: String) -> String {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir + "/" + name) { return name }
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        for i in 2..<10000 {
            let n = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            if !fm.fileExists(atPath: dir + "/" + n) { return n }
        }
        return UUID().uuidString + "-" + name
    }
}

/// Executes actions safely and remembers how to undo them.
public final class ActionRunner {
    public static let shared = ActionRunner()

    struct UndoStep: Codable { var op: String; var from: String; var to: String; var tag: String? }
    struct Batch: Codable { var title: String; var date: Date; var steps: [UndoStep] }

    public struct Outcome { public let action: FileAction; public let ok: Bool; public let message: String; public let resultPath: String? }

    private var history: [Batch] = []
    private let lock = NSLock()
    private let url: URL

    init() {
        url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Rover/undo.json")
        if let d = try? Data(contentsOf: url), let h = try? JSONDecoder().decode([Batch].self, from: d) { history = h }
    }

    public var canUndo: Bool { lock.lock(); defer { lock.unlock() }; return !history.isEmpty }
    public var lastTitle: String? { lock.lock(); defer { lock.unlock() }; return history.last?.title }

    /// Validate without touching anything. Returns an error message or nil.
    public func validate(_ a: FileAction) -> String? {
        let p = Paths.expand(a.path)
        let fm = FileManager.default
        if a.op == .mkdir {
            if let e = Paths.checkWritable(p) { return "Can't create a folder \(e)" }
            return nil
        }
        guard fm.fileExists(atPath: p) else { return "\(Paths.pretty(p)) doesn't exist" }
        if let e = Paths.checkWritable(p) { return "Won't change \(Paths.pretty(p)): \(e)" }
        switch a.op {
        case .move, .copy:
            guard let to = a.to else { return "Missing destination" }
            let d = Paths.expand(to)
            let inICloud = d.hasPrefix(Paths.icloud)
            if !(inICloud || d.hasPrefix(Paths.home)) { return "Destination is outside your home folder" }
            if d == p || d.hasPrefix(p + "/") { return "Can't move a folder into itself" }
        case .rename:
            guard let n = a.name, !n.isEmpty, !n.contains("/"), n != ".", n != ".." else { return "Invalid new name" }
        case .tag:
            guard let t = a.tag, !t.isEmpty else { return "Missing tag" }
        default: break
        }
        return nil
    }

    @discardableResult
    public func run(_ actions: [FileAction], title: String) -> [Outcome] {
        var steps: [UndoStep] = []
        var out: [Outcome] = []
        let fm = FileManager.default
        // mkdirs first so moves into new folders work
        let ordered = actions.filter { $0.op == .mkdir } + actions.filter { $0.op != .mkdir }
        for a in ordered {
            if let err = validate(a) { out.append(Outcome(action: a, ok: false, message: err, resultPath: nil)); continue }
            let p = Paths.expand(a.path)
            do {
                switch a.op {
                case .mkdir:
                    if !fm.fileExists(atPath: p) {
                        try fm.createDirectory(atPath: p, withIntermediateDirectories: true)
                        steps.append(UndoStep(op: "rmdir", from: p, to: ""))
                    }
                    out.append(Outcome(action: a, ok: true, message: "created", resultPath: p))
                case .move, .copy:
                    let d = Paths.expand(a.to!)
                    if !fm.fileExists(atPath: d) {
                        try fm.createDirectory(atPath: d, withIntermediateDirectories: true)
                        steps.append(UndoStep(op: "rmdir", from: d, to: ""))
                    }
                    let name = Paths.freeName(a.name ?? (p as NSString).lastPathComponent, in: d)
                    let dest = d + "/" + name
                    if a.op == .move { try fm.moveItem(atPath: p, toPath: dest); steps.append(UndoStep(op: "move", from: dest, to: p)) }
                    else { try fm.copyItem(atPath: p, toPath: dest); steps.append(UndoStep(op: "trash", from: dest, to: "")) }
                    out.append(Outcome(action: a, ok: true, message: a.op == .move ? "moved" : "copied", resultPath: dest))
                case .rename:
                    let dir = (p as NSString).deletingLastPathComponent
                    let name = Paths.freeName(a.name!, in: dir)
                    let dest = dir + "/" + name
                    try fm.moveItem(atPath: p, toPath: dest)
                    steps.append(UndoStep(op: "move", from: dest, to: p))
                    out.append(Outcome(action: a, ok: true, message: "renamed", resultPath: dest))
                case .trash:
                    var res: NSURL?
                    try fm.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: &res)
                    if let r = res?.path { steps.append(UndoStep(op: "move", from: r, to: p)) }
                    out.append(Outcome(action: a, ok: true, message: "moved to Trash", resultPath: res?.path))
                case .tag:
                    let u = NSURL(fileURLWithPath: p)
                    var cur: AnyObject?
                    try? u.getResourceValue(&cur, forKey: .tagNamesKey)
                    var tags = (cur as? [String]) ?? []
                    if !tags.contains(a.tag!) {
                        tags.append(a.tag!)
                        try u.setResourceValue(tags, forKey: .tagNamesKey)
                        steps.append(UndoStep(op: "untag", from: p, to: "", tag: a.tag))
                    }
                    out.append(Outcome(action: a, ok: true, message: "tagged", resultPath: p))
                }
            } catch {
                out.append(Outcome(action: a, ok: false, message: error.localizedDescription, resultPath: nil))
            }
        }
        if !steps.isEmpty {
            lock.lock()
            history.append(Batch(title: title, date: Date(), steps: steps))
            if history.count > 50 { history.removeFirst(history.count - 50) }
            lock.unlock()
            save()
        }
        return out
    }

    /// Log moves made elsewhere (the junk finder) so ⌘Z can put them back.
    public func recordMoves(_ title: String, _ moves: [(from: String, to: String)]) {
        guard !moves.isEmpty else { return }
        lock.lock()
        history.append(Batch(title: title, date: Date(), steps: moves.map { UndoStep(op: "move", from: $0.to, to: $0.from) }))
        if history.count > 50 { history.removeFirst(history.count - 50) }
        lock.unlock()
        save()
    }

    /// Undo the most recent batch. Returns a description.
    @discardableResult
    public func undoLast() -> String {
        lock.lock()
        guard let b = history.popLast() else { lock.unlock(); return "Nothing to undo" }
        lock.unlock()
        let fm = FileManager.default
        var failed = 0
        for s in b.steps.reversed() {
            do {
                switch s.op {
                case "move":
                    let dir = (s.to as NSString).deletingLastPathComponent
                    if !fm.fileExists(atPath: dir) { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
                    try fm.moveItem(atPath: s.from, toPath: fm.fileExists(atPath: s.to) ? dir + "/" + Paths.freeName((s.to as NSString).lastPathComponent, in: dir) : s.to)
                case "trash":
                    var r: NSURL?
                    try fm.trashItem(at: URL(fileURLWithPath: s.from), resultingItemURL: &r)
                case "rmdir":
                    if (try? fm.contentsOfDirectory(atPath: s.from).filter { $0 != ".DS_Store" }.isEmpty) == true { try fm.removeItem(atPath: s.from) }
                case "untag":
                    let u = NSURL(fileURLWithPath: s.from)
                    var cur: AnyObject?
                    try? u.getResourceValue(&cur, forKey: .tagNamesKey)
                    try u.setResourceValue(((cur as? [String]) ?? []).filter { $0 != s.tag }, forKey: .tagNamesKey)
                default: break
                }
            } catch { failed += 1 }
        }
        save()
        return failed == 0 ? "Undid: \(b.title)" : "Undid \(b.title) (\(failed) step(s) could not be reversed)"
    }

    private func save() {
        lock.lock(); let h = history; lock.unlock()
        if let d = try? JSONEncoder().encode(h) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: url, options: .atomic)
        }
    }
}
