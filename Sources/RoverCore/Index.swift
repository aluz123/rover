// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import Foundation

public struct Config {
    public var roots: [String]
    public var skipNames: Set<String>
    public var skipPaths: Set<String>
    public var hiddenAllowed: Set<String>

    public static func load() -> Config {
        let home = NSHomeDirectory()
        var roots = [home, "/Applications", "/System/Applications"]
        let icloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: icloud) { roots.append(icloud) }
        var c = Config(
            roots: roots,
            skipNames: ["node_modules", ".git", ".hg", ".svn", "__pycache__", ".venv", "venv", "DerivedData", ".build",
                        "Pods", ".gradle", "site-packages", ".next", ".nuxt", ".tox", ".mypy_cache", ".pytest_cache",
                        "bower_components", ".Trash", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
                        ".TemporaryItems", ".cache", ".npm", ".cargo", ".rustup", ".pnpm-store", ".yarn"],
            skipPaths: [home + "/Library", home + "/.Trash"],
            hiddenAllowed: [".config"])
        // ROVER_DEMO_HOME: index only that folder, as if it were the home folder (demo footage, tests)
        if let demo = ProcessInfo.processInfo.environment["ROVER_DEMO_HOME"] {
            c.roots = [demo]; c.skipPaths = [demo + "/Library/Caches"]
            return c
        }
        let cfg = home + "/.config/rover/config.json"
        if let d = FileManager.default.contents(atPath: cfg),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let expand = { (s: String) in (s as NSString).expandingTildeInPath }
            if let r = j["extraRoots"] as? [String] { c.roots += r.map(expand) }
            if let r = j["roots"] as? [String] { c.roots = r.map(expand) }
            if let r = j["skipNames"] as? [String] { c.skipNames.formUnion(r) }
            if let r = j["skipPaths"] as? [String] { c.skipPaths.formUnion(r.map(expand)) }
            if let r = j["includeHidden"] as? [String] { c.hiddenAllowed.formUnion(r) }
        }
        return c
    }
}

public final class FileIndex {
    let s = NodeStore()
    let lock = RWLock()
    var children: [[Int32]] = []
    var dirIndex: [String: Int32] = [:]
    let config: Config
    public private(set) var liveCount = 0

    init(config: Config) { self.config = config }

    public var count: Int { lock.read { liveCount } }

    // MARK: crawl

    static func build(config: Config) -> FileIndex {
        let idx = FileIndex(config: config)
        var jobs: [(String, Int32)] = []
        var seen = Set<String>()
        for root in config.roots {
            let r = (root as NSString).standardizingPath
            guard !seen.contains(r), FileManager.default.fileExists(atPath: r) else { continue }
            seen.insert(r)
            var st = stat()
            lstat(r, &st)
            let rid = idx.s.add(name: r, parent: -1, mtime: Int64(st.st_mtimespec.tv_sec), size: 0, flags: Flag.dir | Flag.root)
            // split two levels deep so big folders crawl in parallel
            for (name, isDir, mt, sz) in Self.list(r) {
                let p = r + "/" + name
                if isDir {
                    let (skip, pkg) = idx.classifyDir(name: name, path: p)
                    if skip { continue }
                    let id = idx.s.add(name: name, parent: rid, mtime: mt, size: sz, flags: Flag.dir | (pkg ? Flag.package : 0))
                    if pkg || !idx.mayDescend(name: name) { continue }
                    for (n2, d2, m2, s2) in Self.list(p) {
                        let p2 = p + "/" + n2
                        if d2 {
                            let (sk2, pk2) = idx.classifyDir(name: n2, path: p2)
                            if sk2 { continue }
                            let id2 = idx.s.add(name: n2, parent: id, mtime: m2, size: s2, flags: Flag.dir | (pk2 ? Flag.package : 0))
                            if !pk2 && idx.mayDescend(name: n2) { jobs.append((p2, id2)) }
                        } else {
                            idx.s.add(name: n2, parent: id, mtime: m2, size: s2, flags: 0)
                        }
                    }
                } else {
                    idx.s.add(name: name, parent: rid, mtime: mt, size: sz, flags: 0)
                }
            }
        }
        var batches = [NodeStore?](repeating: nil, count: jobs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let b = idx.crawl(jobs[i].0)
            lock.lock(); batches[i] = b; lock.unlock()
        }
        for (i, b) in batches.enumerated() { if let b = b { idx.s.absorb(b, under: jobs[i].1) } }
        idx.rebuildAux()
        return idx
    }

    func mayDescend(name: String) -> Bool {
        !name.hasPrefix(".") || config.hiddenAllowed.contains(name)
    }

    /// (skip entirely, treat as package)
    func classifyDir(name: String, path: String) -> (Bool, Bool) {
        if config.skipNames.contains(name) || config.skipPaths.contains(path) { return (true, false) }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let ext = name[name.index(after: dot)...].lowercased()
            if Kinds.packages.contains(ext) { return (false, true) }
        }
        return (false, false)
    }

    static func list(_ path: String) -> [(String, Bool, Int64, Int64)] {
        guard let d = opendir(path) else { return [] }
        defer { closedir(d) }
        var out: [(String, Bool, Int64, Int64)] = []
        let fd = dirfd(d)
        while let e = readdir(d) {
            let name = withUnsafePointer(to: &e.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var st = stat()
            if fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) != 0 { continue }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            out.append((name, isDir, Int64(st.st_mtimespec.tv_sec), isDir ? 0 : Int64(st.st_size)))
        }
        return out
    }

    /// Crawl below `start` (exclusive). Returned nodes with parent -1 belong directly under `start`.
    func crawl(_ start: String) -> NodeStore {
        let b = NodeStore()
        var stack: [(String, Int32, Int)] = [(start, -1, 0)]
        while let (dir, pid, depth) = stack.popLast() {
            if depth > 64 { continue }
            for (name, isDir, mt, sz) in Self.list(dir) {
                if isDir {
                    let path = dir + "/" + name
                    let (skip, pkg) = classifyDir(name: name, path: path)
                    if skip { continue }
                    let id = b.add(name: name, parent: pid, mtime: mt, size: 0, flags: Flag.dir | (pkg ? Flag.package : 0))
                    if !pkg && mayDescend(name: name) { stack.append((path, id, depth + 1)) }
                } else {
                    b.add(name: name, parent: pid, mtime: mt, size: sz, flags: 0)
                }
            }
        }
        return b
    }

    func rebuildAux() {
        children = Array(repeating: [], count: s.count)
        dirIndex = [:]
        liveCount = 0
        indexAux(from: 0)
    }

    /// Register children / dir paths for nodes [from, count).
    func indexAux(from: Int) {
        if children.count < s.count { children.append(contentsOf: repeatElement([], count: s.count - children.count)) }
        var dirPath: [Int32: String] = [:]
        for i in from..<s.count {
            let f = s.flags[i]
            if f & Flag.deleted != 0 { continue }
            if f & Flag.root == 0 { liveCount += 1 }
            let p = s.parent[i]
            if p >= 0 { children[Int(p)].append(Int32(i)) }
            if f & Flag.dir != 0 && f & Flag.package == 0 {
                let path: String
                if p < 0 { path = s.name(i) }
                else if let pp = dirPath[p] { path = pp + "/" + s.name(i) }
                else { path = s.path(i) }
                dirPath[Int32(i)] = path
                dirIndex[path] = Int32(i)
            }
        }
    }

    // MARK: live updates

    func isInsideRoots(_ path: String) -> Bool {
        config.roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Re-list one directory and reconcile its children. Returns false if the dir is unknown.
    @discardableResult
    func refresh(dir path: String) -> Bool {
        lock.write {
            var p = path
            // find the nearest known ancestor; refreshing it will pick up new subfolders
            while dirIndex[p] == nil {
                guard isInsideRoots(p), let r = p.range(of: "/", options: .backwards), r.lowerBound != p.startIndex else { return false }
                p = String(p[..<r.lowerBound])
            }
            guard let d = dirIndex[p] else { return false }
            reconcile(dir: d, path: p)
            return true
        }
    }

    private func reconcile(dir d: Int32, path: String) {
        var existing: [String: Int32] = [:]
        for c in children[Int(d)] where s.flags[Int(c)] & Flag.deleted == 0 { existing[s.name(Int(c))] = c }
        guard FileManager.default.fileExists(atPath: path) else {
            tombstone(d); return
        }
        let start = s.count
        for (name, isDir, mt, sz) in Self.list(path) {
            if let c = existing.removeValue(forKey: name) {
                let ci = Int(c)
                let wasDir = s.flags[ci] & Flag.dir != 0
                if wasDir == isDir { s.mtime[ci] = mt; if !isDir { s.size[ci] = sz }; continue }
                tombstone(c)
            }
            let full = path + "/" + name
            if isDir {
                let (skip, pkg) = classifyDir(name: name, path: full)
                if skip { continue }
                let id = s.add(name: name, parent: d, mtime: mt, size: 0, flags: Flag.dir | (pkg ? Flag.package : 0))
                if !pkg && mayDescend(name: name) { s.absorb(crawl(full), under: id) }
            } else {
                s.add(name: name, parent: d, mtime: mt, size: sz, flags: 0)
            }
        }
        for (_, c) in existing { tombstone(c) }
        if s.count > start { indexAux(from: start) }
    }

    private func tombstone(_ i: Int32) {
        var stack = [i]
        while let n = stack.popLast() {
            let ni = Int(n)
            if s.flags[ni] & Flag.deleted != 0 { continue }
            s.flags[ni] |= Flag.deleted
            if s.flags[ni] & Flag.root == 0 { liveCount -= 1 }
            if s.flags[ni] & Flag.dir != 0 && s.flags[ni] & Flag.package == 0 { dirIndex.removeValue(forKey: s.path(ni)) }
            stack.append(contentsOf: children[ni])
            children[ni] = []
        }
    }

    /// Node id for an absolute path, if indexed.
    func lookup(_ path: String) -> Int32? {
        if let d = dirIndex[path] { return d }
        guard let r = path.range(of: "/", options: .backwards) else { return nil }
        let dir = String(path[..<r.lowerBound]), name = String(path[r.upperBound...])
        guard let d = dirIndex[dir] else { return nil }
        for c in children[Int(d)] where s.flags[Int(c)] & Flag.deleted == 0 && s.name(Int(c)) == name { return c }
        return nil
    }

    // MARK: persistence

    static let magic: UInt32 = 0x48554E54 // HUNT
    static let version: UInt32 = 5

    func save(to url: URL) throws {
        let data: Data = lock.read {
            // compact: drop tombstones, remap parents
            let out = NodeStore()
            var map = [Int32](repeating: -1, count: s.count)
            for i in 0..<s.count where s.flags[i] & Flag.deleted == 0 {
                let p = s.parent[i]
                if p >= 0 && map[Int(p)] < 0 { continue }
                let buf = UnsafeBufferPointer(start: s.names.p + Int(s.nameOff[i]), count: Int(s.nameLen[i]))
                map[i] = out.add(name: buf, parent: p >= 0 ? map[Int(p)] : -1, mtime: s.mtime[i], size: s.size[i], flags: s.flags[i] & ~Flag.hidden)
            }
            var d = Data()
            var hdr: [UInt32] = [Self.magic, Self.version, UInt32(out.count), UInt32(out.names.count), UInt32(out.lows.count), 0]
            hdr.withUnsafeBytes { d.append(contentsOf: $0) }
            d.append(contentsOf: out.mtime.rawBytes); d.append(contentsOf: out.size.rawBytes)
            d.append(contentsOf: out.parent.rawBytes); d.append(contentsOf: out.nameOff.rawBytes); d.append(contentsOf: out.lowOff.rawBytes)
            d.append(contentsOf: out.nameLen.rawBytes); d.append(contentsOf: out.lowLen.rawBytes)
            d.append(contentsOf: out.flags.rawBytes); d.append(contentsOf: out.kind.rawBytes); d.append(contentsOf: out.depth.rawBytes)
            d.append(contentsOf: out.names.rawBytes); d.append(contentsOf: out.lows.rawBytes)
            return d
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL, config: Config) -> FileIndex? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= 24 else { return nil }
        let idx = FileIndex(config: config)
        let ok: Bool = data.withUnsafeBytes { raw -> Bool in
            let h = (0..<6).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self) }
            guard h[0] == magic, h[1] == version else { return false }
            let n = Int(h[2]), nn = Int(h[3]), nl = Int(h[4])
            var off = 24
            func take<T>(_ v: Vec<T>, _ count: Int) -> Bool {
                let len = count * MemoryLayout<T>.stride
                guard off + len <= raw.count else { return false }
                v.appendRaw(UnsafeRawBufferPointer(rebasing: raw[off..<off + len]))
                off += len
                return true
            }
            let s = idx.s
            return take(s.mtime, n) && take(s.size, n) && take(s.parent, n) && take(s.nameOff, n) && take(s.lowOff, n)
                && take(s.nameLen, n) && take(s.lowLen, n) && take(s.flags, n) && take(s.kind, n) && take(s.depth, n)
                && take(s.names, nn) && take(s.lows, nl)
        }
        guard ok else { return nil }
        // hidden flag is derived; recompute from names
        for i in 0..<idx.s.count {
            let p = idx.s.parent[i]
            var f = idx.s.flags[i]
            if p >= 0 && idx.s.flags[Int(p)] & Flag.hidden != 0 { f |= Flag.hidden }
            if idx.s.nameLen[i] > 0 && idx.s.names[Int(idx.s.nameOff[i])] == UInt8(ascii: ".") && f & Flag.root == 0 { f |= Flag.hidden }
            idx.s.flags[i] = f
        }
        idx.rebuildAux()
        return idx
    }
}
