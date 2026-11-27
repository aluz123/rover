// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import Foundation
import NaturalLanguage
import CoreServices

/// Remembers what you open, and for which query, so the right file floats to the top next time.
final class Learning {
    struct Entry: Codable { var c: Double; var t: Double }
    private var opens: [String: Entry] = [:]
    private var queries: [String: [String: Double]] = [:]
    private let url: URL
    private let q = DispatchQueue(label: "rover.learning")

    init(url: URL) {
        self.url = url
        if let d = try? Data(contentsOf: url),
           let j = try? JSONDecoder().decode(Store.self, from: d) { opens = j.opens; queries = j.queries }
    }
    struct Store: Codable { var opens: [String: Entry]; var queries: [String: [String: Double]] }

    static func norm(_ s: String) -> String { s.folded.split(separator: " ").joined(separator: " ") }

    func record(path: String, query: String) {
        q.sync {
            let now = Date().timeIntervalSince1970
            var e = opens[path] ?? Entry(c: 0, t: now)
            e.c = e.c * pow(0.5, (now - e.t) / (86400 * 30)) + 1
            e.t = now
            opens[path] = e
            let k = Self.norm(query)
            if !k.isEmpty { queries[k, default: [:]][path, default: 0] += 1 }
            if opens.count > 5000 { opens = Dictionary(uniqueKeysWithValues: opens.sorted { $0.value.t > $1.value.t }.prefix(4000).map { ($0.key, $0.value) }) }
            if let d = try? JSONEncoder().encode(Store(opens: opens, queries: queries)) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? d.write(to: url, options: .atomic)
            }
        }
    }

    /// path -> score boost for this query
    func boosts(for query: String) -> [String: Double] {
        q.sync {
            var out: [String: Double] = [:]
            let now = Date().timeIntervalSince1970
            for (p, e) in opens {
                let c = e.c * pow(0.5, (now - e.t) / (86400 * 30))
                if c > 0.05 { out[p] = min(35, 14 * log2(1 + c)) }
            }
            let k = Self.norm(query)
            if !k.isEmpty {
                for (qq, paths) in queries where qq == k || (qq.hasPrefix(k) && k.count >= 2) || (k.hasPrefix(qq) && qq.count >= 3) {
                    let exact = qq == k
                    for (p, c) in paths { out[p, default: 0] += (exact ? 90 : 45) * min(1.0, 0.5 + c * 0.25) }
                }
            }
            return out
        }
    }
}

/// On-device meaning expansion: "invoice" also tries "receipt", "billing"...
enum Semantic {
    static let emb = NLEmbedding.wordEmbedding(for: .english)
    static var cache: [String: [(String, Double)]] = [:]
    static let lock = NSLock()

    static func related(_ w: String) -> [(String, Double)] {
        guard w.count >= 3, w.allSatisfy({ $0.isLetter }), let e = emb else { return [] }
        lock.lock(); defer { lock.unlock() }
        if let c = cache[w] { return c }
        let ns = e.neighbors(for: w, maximumCount: 8)
            .filter { $0.1 < 1.02 && !$0.0.contains(w) && !w.contains($0.0) && $0.0.count >= 3 }
            .prefix(5)
            .map { ($0.0, max(0.45, 0.85 - $0.1 * 0.35)) }
        cache[w] = Array(ns)
        return cache[w]!
    }
}

public final class Engine {
    public static let shared = Engine()

    private var index: FileIndex?
    private let swapLock = NSLock()
    public let config = Config.load()
    let learning: Learning
    public let supportDir: URL
    var indexURL: URL { supportDir.appendingPathComponent("index.bin") }
    private var stream: FSEventStreamRef?
    private let watchQ = DispatchQueue(label: "rover.watch")
    private var pendingDirs = Set<String>()
    private var crawling = false
    private var dirty = false
    public private(set) var status = "Starting…"
    public var onChange: (() -> Void)?
    /// UI hook for opening / revealing a path (set by the app).
    public var openHandler: ((String, Bool) -> Void)?

    /// Tell the index a path changed (after the assistant moves something) without waiting for FSEvents.
    public func touched(_ path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        watchQ.async { self.current?.refresh(dir: dir); self.dirty = true }
    }

    init() {
        if let demo = ProcessInfo.processInfo.environment["ROVER_DEMO_HOME"] {
            supportDir = URL(fileURLWithPath: demo).appendingPathComponent(".rover")
        } else {
            supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Rover")
        }
        learning = Learning(url: supportDir.appendingPathComponent("learning.json"))
    }

    var current: FileIndex? { swapLock.lock(); defer { swapLock.unlock() }; return index }
    public var fileCount: Int { current?.count ?? 0 }
    public var isReady: Bool { current != nil }

    // MARK: lifecycle

    /// Load the cached index instantly, then re-crawl in the background and watch for changes.
    public func start(watch: Bool = true, rescan: Bool = true) {
        // load the on-device word-meaning model early (the app only), so the first "nothing found" search isn't slow
        if watch { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { _ = Semantic.emb } }
        if let cached = FileIndex.load(from: indexURL, config: config) {
            swapLock.lock(); index = cached; swapLock.unlock()
            status = "Ready"
            onChange?()
        }
        if watch { startWatching() }
        if rescan || current == nil {
            DispatchQueue.global(qos: current == nil ? .userInitiated : .utility).async { self.rebuild() }
        }
        // periodic save of live changes
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.saveIfDirty() }
    }

    public func rebuild() {
        watchQ.sync { crawling = true }
        status = current == nil ? "Indexing your Mac…" : status
        onChange?()
        let t0 = Date()
        let fresh = FileIndex.build(config: config)
        let replay: Set<String> = watchQ.sync { let p = pendingDirs; pendingDirs = []; crawling = false; return p }
        for d in replay { fresh.refresh(dir: d) }
        swapLock.lock(); index = fresh; swapLock.unlock()
        status = "Ready"
        log("indexed \(fresh.count) items in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        try? fresh.save(to: indexURL)
        onChange?()
    }

    public func buildSync() {
        let fresh = FileIndex.build(config: config)
        swapLock.lock(); index = fresh; swapLock.unlock()
        try? fresh.save(to: indexURL)
    }

    public func saveIfDirty() {
        guard dirty, let idx = current else { return }
        dirty = false
        DispatchQueue.global(qos: .utility).async { [indexURL] in try? idx.save(to: indexURL) }
    }

    private func startWatching() {
        let cb: FSEventStreamCallback = { _, info, n, paths, flags, _ in
            let me = Unmanaged<Engine>.fromOpaque(info!).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self)
            var dirs = Set<String>()
            for k in 0..<n {
                guard let p = arr[k] as? String else { continue }
                let fl = Int(flags[k])
                if fl & kFSEventStreamEventFlagItemIsDir != 0 && fl & kFSEventStreamEventFlagMustScanSubDirs != 0 { dirs.insert(p) }
                dirs.insert((p as NSString).deletingLastPathComponent)
            }
            me.changed(dirs)
        }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, config.roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(s, watchQ)
        FSEventStreamStart(s)
        stream = s
    }

    private func changed(_ dirs: Set<String>) {
        // runs on watchQ
        if !RuleEngine.shared.rules.isEmpty { RuleEngine.shared.check(dirs: dirs) }
        let skip = config.skipPaths
        let ic = Paths.icloudRoot
        let relevant = dirs.filter { d in d == ic || d.hasPrefix(ic + "/") || !skip.contains { d == $0 || d.hasPrefix($0 + "/") } && !d.contains("/node_modules") && !d.contains("/.git/") }
        if relevant.isEmpty { return }
        if crawling { pendingDirs.formUnion(relevant); return }
        guard let idx = current else { return }
        for d in relevant { idx.refresh(dir: d) }
        dirty = true
        DispatchQueue.main.async { self.onChange?() }
    }

    // MARK: search

    public func parse(_ text: String) -> ParsedQuery { QueryParser.parse(text) }

    /// Fast name search (typically a few ms). Widens itself with typo tolerance and related words when results are thin.
    public func search(_ text: String, limit: Int = 60) -> SearchResult {
        let t0 = DispatchTime.now()
        var q = QueryParser.parse(text)
        guard let idx = current, !(q.terms.isEmpty && !q.hasFilters) else {
            return SearchResult(hits: [], query: q, total: 0, millis: 0, expanded: [])
        }
        var opt = SearchOptions()
        opt.limit = limit
        for (p, b) in learning.boosts(for: text) { if let id = idx.lock.read({ idx.lookup(p) }) { opt.boosts[id] = b } }

        var (raw, total) = idx.search(q, opt)
        var expanded: [String] = []
        let strong = raw.filter { $0.0 > 150 }.count
        if strong < 3 && !q.terms.isEmpty {
            // second pass: tolerate typos; if still nothing, try words with the same meaning
            var q2 = q
            opt.typo = true
            if idx.search(q2, opt).total == 0 {
              for ti in q2.terms.indices where !q2.terms[ti].locationOnly && !q2.terms[ti].optional && q2.terms[ti].softTime == nil {
                for (w, wt) in Semantic.related(q2.terms[ti].word) {
                    q2.terms[ti].alts.append(Alt(bytes: Array(w.utf8), weight: wt, label: w))
                    expanded.append(w)
                }
              }
            }
            let (r2, t2) = idx.search(q2, opt)
            if t2 > total || r2.count > raw.count {
                var seen = Set(raw.map { $0.1 })
                for r in r2 where !seen.contains(r.1) { raw.append((r.0 * 0.92, r.1, r.2)); seen.insert(r.1) }
                raw.sort { $0.0 > $1.0 }
                total = max(total, t2)
                q = q2
            } else { expanded = [] }
        }
        // closest matches: nothing has every word, so show files that have most of them
        let required = q.terms.filter { !$0.optional }.count
        if total == 0 && required >= 2 {
            // one pass: files may miss words, and each missing word costs rank, so the closest come first
            var o2 = opt
            o2.typo = false
            o2.allowMissing = required - 1
            let (r3, t3) = idx.search(q, o2)
            if t3 > 0 { raw = r3; total = t3; q.chips.append("closest matches") }
        }
        let hits = raw.prefix(limit).map { idx.hit($0.1, path: $0.2, score: $0.0) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        return SearchResult(hits: Array(hits), query: q, total: total, millis: ms, expanded: Array(Set(expanded)).sorted())
    }

    /// Indexed folders whose path ends with a fragment like "projects/acme/reports" (case-insensitive),
    /// shortest paths first. Lets a search like "acme/reports/" jump straight to that folder.
    public func folders(endingWith frag: String, limit: Int = 20) -> [String] {
        guard let idx = current else { return [] }
        let f = "/" + frag.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard f.count > 1 else { return [] }
        let keys: [String] = idx.lock.read { Array(idx.dirIndex.keys) }
        return keys.filter { $0.lowercased().hasSuffix(f) }.sorted { $0.count < $1.count }.prefix(limit).map { $0 }
    }

    /// Full-text search through Spotlight's content index, filtered by the same query rules.
    public func contentSearch(_ q: ParsedQuery, excluding: Set<String>, limit: Int = 40, completion: @escaping ([Hit]) -> Void) {
        var words = q.contentWords.flatMap { $0.split(separator: " ").map(String.init) }
        let phrase = q.contentWords
        if words.isEmpty { words = q.terms.filter { !$0.locationOnly && !$0.optional }.map { $0.word } }
        words = words.filter { $0.count >= 2 }
        guard !words.isEmpty else { completion([]); return }
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        var parts = words.map { "(kMDItemTextContent == \"\(esc($0))*\"cdw)" }
        for p in phrase where p.contains(" ") { parts.append("(kMDItemTextContent == \"*\(esc(p))*\"cd)") }
        let mdq = parts.joined(separator: " && ")
        let roots = config.roots.filter { !$0.hasPrefix("/System") && $0 != "/Applications" }
        DispatchQueue.global(qos: .userInitiated).async {
            var paths: [String] = []
            for r in roots {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                p.arguments = ["-onlyin", r, mdq]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { continue }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit(); killer.cancel()
                paths += String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            }
            var hits: [Hit] = []
            var seen = excluding
            let now = Int64(Date().timeIntervalSince1970)
            for path in paths where !seen.contains(path) {
                seen.insert(path)
                if path.contains("/Library/") && !path.contains("/Mobile Documents/") { continue }
                if path.contains("/node_modules/") || path.contains("/.git/") || path.contains("/.Trash/") { continue }
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                let isDir = (st.st_mode & S_IFMT) == S_IFDIR
                let name = (path as NSString).lastPathComponent
                let low = name.folded
                let k: Kind = isDir ? .folder : (low.withCString { p in Kinds.kind(ofLowName: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), len: low.utf8.count) })
                let mt = Int64(st.st_mtimespec.tv_sec), sz = Int64(st.st_size)
                guard q.passes(kind: k, ext: Kinds.ext(ofLow: low), mtime: mt, size: sz, isDir: isDir) else { continue }
                // location words must appear in the folder path
                let lowPath = path.folded
                if !q.terms.filter({ $0.locationOnly }).allSatisfy({ t in t.alts.contains { lowPath.contains(String(decoding: $0.bytes, as: UTF8.self)) } }) { continue }
                let age = Double(max(0, now - mt)) / 86400
                var score = 60 + 20 * exp(-age / 30)
                for w in words where low.contains(w.folded) { score += 25 }
                if path.contains("/.") { score -= 30 }
                hits.append(Hit(path: path, name: name, mtime: mt, size: isDir ? 0 : sz, isDir: isDir, kind: k, score: score, source: .content, why: "contains “\(words.joined(separator: " "))”"))
            }
            hits.sort { $0.score > $1.score }
            completion(Array(hits.prefix(limit)))
        }
    }

    public func recordOpen(_ path: String, query: String) { learning.record(path: path, query: query) }

    func log(_ s: String) { FileHandle.standardError.write(("rover: " + s + "\n").data(using: .utf8)!) }
}
