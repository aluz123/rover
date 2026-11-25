// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import Foundation

/// A standing automation: when a new file that matches lands in `folder`, do `op`.
public struct Rule: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var name: String

    public init(name: String, folder: String, match: String, op: FileAction.Op) {
        self.name = name; self.folder = folder; self.match = match; self.op = op
    }
    public var folder: String
    public var match: String          // Rover query, e.g. "invoice pdf" or "screenshot" or ".dmg"
    public var op: FileAction.Op      // move, rename, copy, trash, tag
    public var to: String?
    public var renameTemplate: String? // e.g. "{date} {name}" ; {date}=YYYY-MM-DD {name}=original stem {ext}
    public var tag: String?
    public var olderThanDays: Int?    // only act on files untouched for this long (cleanup rules)
    public var enabled = true
    public var created = Date()
    public var runs = 0

    public var summary: String {
        var s = "In \(Paths.pretty(folder)), new “\(match.isEmpty ? "any file" : match)”"
        if let d = olderThanDays { s = "In \(Paths.pretty(folder)), “\(match.isEmpty ? "any file" : match)” older than \(d) days" }
        switch op {
        case .move: s += " → move to \(Paths.pretty(to ?? ""))"
        case .copy: s += " → copy to \(Paths.pretty(to ?? ""))"
        case .rename: s += " → rename “\(renameTemplate ?? "")”"
        case .trash: s += " → Trash"
        case .tag: s += " → tag “\(tag ?? "")”"
        case .mkdir: break
        }
        return s
    }
}

public final class RuleEngine {
    public static let shared = RuleEngine()
    public private(set) var rules: [Rule] = []
    public private(set) var log: [(Date, String)] = []
    private var seen: [UUID: Set<String>] = [:]
    private let url: URL
    private let q = DispatchQueue(label: "rover.rules")
    public var onActivity: ((String) -> Void)?

    struct Store: Codable { var rules: [Rule]; var seen: [String: [String]] }

    private var loadedStamp: Date?

    init() {
        url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Rover/rules.json")
        reloadIfChanged()
        // cleanup rules (olderThanDays) are checked hourly
        DispatchQueue.main.async {
            Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.check(dirs: nil) }
        }
    }

    /// Pick up edits made by another Rover process (e.g. the `rover rule` command).
    private func reloadIfChanged() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        guard stamp != loadedStamp else { return }
        loadedStamp = stamp
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Store.self, from: d) else { return }
        rules = s.rules
        seen = [:]
        for (k, v) in s.seen { if let id = UUID(uuidString: k) { seen[id] = Set(v) } }
    }

    public func validate(_ r: Rule) -> String? {
        let f = Paths.expand(r.folder)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: f, isDirectory: &isDir), isDir.boolValue else { return "Folder \(Paths.pretty(f)) doesn't exist" }
        if r.op == .trash && r.match.trimmingCharacters(in: .whitespaces).isEmpty { return "A Trash rule needs a specific match" }
        if (r.op == .move || r.op == .copy) && (r.to ?? "").isEmpty { return "Missing destination" }
        if r.op == .rename && (r.renameTemplate ?? "").isEmpty { return "Missing rename template" }
        if r.op == .mkdir { return "Unsupported rule action" }
        if let to = r.to, Paths.expand(to) == f { return "Destination is the watched folder" }
        return nil
    }

    /// Add a rule. Files already in the folder are not touched (unless it is an age-based cleanup rule).
    public func add(_ r0: Rule) {
        var r = r0
        r.folder = Paths.expand(r.folder)
        if let t = r.to { r.to = Paths.expand(t) }
        q.sync {
            reloadIfChanged()
            rules.append(r)
            if r.olderThanDays == nil {
                let existing = (try? FileManager.default.contentsOfDirectory(atPath: r.folder)) ?? []
                seen[r.id] = Set(existing)
            }
            save()
        }
        if r.olderThanDays != nil { check(dirs: [r.folder]) }
    }

    public func remove(_ id: UUID) { q.sync { reloadIfChanged(); rules.removeAll { $0.id == id }; seen[id] = nil; save() } }
    public func setEnabled(_ id: UUID, _ on: Bool) { q.sync { reloadIfChanged(); if let i = rules.firstIndex(where: { $0.id == id }) { rules[i].enabled = on }; save() } }

    /// Called with changed directories (or nil for a periodic sweep).
    public func check(dirs: Set<String>?) {
        q.async { self.checkLocked(dirs) }
    }

    private func checkLocked(_ dirs: Set<String>?) {
        reloadIfChanged()
        let now = Date()
        var changed = false
        for ri in rules.indices where rules[ri].enabled {
            let r = rules[ri]
            if let d = dirs, !d.contains(r.folder) { continue }
            let q = QueryParser.parse(r.match)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: r.folder)) ?? []
            var acts: [FileAction] = []
            var pending = false
            for n in names {
                if n.hasPrefix(".") { continue }
                let lowN = n.folded
                if r.olderThanDays == nil && seen[r.id, default: []].contains(n) { continue }
                if [".crdownload", ".download", ".part", ".partial", ".tmp"].contains(where: { lowN.hasSuffix($0) }) { pending = true; continue }
                let p = r.folder + "/" + n
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: p) else { continue }
                let mod = (attrs[.modificationDate] as? Date) ?? now
                let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory && !Kinds.packages.contains(Kinds.ext(ofLow: lowN))
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                if let days = r.olderThanDays {
                    let used = (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? mod
                    if now.timeIntervalSince(max(mod, used)) < Double(days) * 86400 { continue }
                } else if now.timeIntervalSince(mod) < 3 { pending = true; continue } // let downloads settle
                let k: Kind = isDir ? .folder : lowN.withCString { Kinds.kind(ofLowName: UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), len: lowN.utf8.count) }
                // time filters make no sense for "new file" rules, so only kind/ext/size count
                var qq = q; qq.after = nil; qq.before = nil
                guard qq.passes(kind: k, ext: Kinds.ext(ofLow: lowN), mtime: Int64(mod.timeIntervalSince1970), size: size, isDir: isDir) else { markSeen(r.id, n); continue }
                let termsOK = q.terms.filter({ !$0.optional }).allSatisfy { t in t.alts.contains { lowN.contains(String(decoding: $0.bytes, as: UTF8.self)) } }
                if !termsOK { markSeen(r.id, n); continue }
                markSeen(r.id, n)
                var a = FileAction(op: r.op, path: p, to: r.to, name: nil, tag: r.tag)
                if r.op == .rename, let t = r.renameTemplate { a.name = Self.render(t, name: n, date: mod) }
                acts.append(a)
            }
            if !acts.isEmpty {
                let res = ActionRunner.shared.run(acts, title: "Rule “\(r.name)”")
                let ok = res.filter { $0.ok }.count
                rules[ri].runs += ok
                let msg = "\(r.name): \(ok) file\(ok == 1 ? "" : "s") " + (res.first?.action.summary.lowercased().components(separatedBy: " ").first ?? r.op.rawValue)
                log.append((now, msg))
                if log.count > 100 { log.removeFirst() }
                changed = true
                onActivity?(msg)
            }
            if pending { DispatchQueue.global().asyncAfter(deadline: .now() + 4) { self.check(dirs: [r.folder]) } }
        }
        if changed { save() } else { saveSeenLater() }
    }

    private func markSeen(_ id: UUID, _ n: String) { seen[id, default: []].insert(n) }

    private var saveScheduled = false
    private func saveSeenLater() {
        if saveScheduled { return }
        saveScheduled = true
        q.asyncAfter(deadline: .now() + 10) { self.saveScheduled = false; self.save() }
    }

    static func render(_ t: String, name: String, date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        var s = t.replacingOccurrences(of: "{date}", with: f.string(from: date))
            .replacingOccurrences(of: "{name}", with: stem).replacingOccurrences(of: "{ext}", with: ext)
            .replacingOccurrences(of: "/", with: "-")
        if !ext.isEmpty && !s.lowercased().hasSuffix("." + ext.lowercased()) { s += "." + ext }
        return s
    }

    private func save() {
        let s = Store(rules: rules, seen: Dictionary(uniqueKeysWithValues: seen.map { ($0.key.uuidString, Array($0.value.suffix(5000))) }))
        if let d = try? JSONEncoder().encode(s) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: url, options: .atomic)
            loadedStamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        }
    }
}
