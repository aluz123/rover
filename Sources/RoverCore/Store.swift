// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import Foundation

/// Growable buffer of trivial values with a stable raw pointer while no append happens.
/// Readers hold the index read lock, so `p` never moves under them.
final class Vec<T> {
    private(set) var p: UnsafeMutablePointer<T>
    private(set) var count = 0
    private var cap: Int

    init(capacity: Int = 1024) {
        cap = max(16, capacity)
        p = .allocate(capacity: cap)
    }
    deinit { p.deallocate() }

    @inline(__always) subscript(i: Int) -> T {
        get { p[i] }
        set { p[i] = newValue }
    }

    @inline(__always) func append(_ v: T) {
        if count == cap { grow(cap * 2) }
        (p + count).initialize(to: v)
        count += 1
    }

    func append(_ src: UnsafePointer<T>, count n: Int) {
        if count + n > cap { grow(max(cap * 2, count + n)) }
        (p + count).initialize(from: src, count: n)
        count += n
    }

    func reserve(_ n: Int) { if n > cap { grow(n) } }

    private func grow(_ n: Int) {
        let np = UnsafeMutablePointer<T>.allocate(capacity: n)
        np.moveInitialize(from: p, count: count)
        p.deallocate()
        p = np
        cap = n
    }

    var rawBytes: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: p, count: count * MemoryLayout<T>.stride) }

    func appendRaw(_ raw: UnsafeRawBufferPointer) {
        let n = raw.count / MemoryLayout<T>.stride
        reserve(count + n)
        UnsafeMutableRawPointer(p + count).copyMemory(from: raw.baseAddress!, byteCount: n * MemoryLayout<T>.stride)
        count += n
    }
}

public enum Flag {
    public static let dir: UInt8 = 1
    public static let hidden: UInt8 = 2      // this node or an ancestor starts with "."
    public static let deleted: UInt8 = 4
    public static let root: UInt8 = 8
    public static let package: UInt8 = 16    // .app and other bundles, shown as files
    public static let noise: UInt8 = 32      // inside a toolkit, SDK, cache or translation folder: ranked below your own files
}

/// Folders full of files people rarely search for by hand (installed toolkits, SDKs, caches, other-language copies).
enum Noise {
    static let names: Set<String> = ["miniforge3", "miniconda3", "anaconda3", "site-packages", "dist-packages", "pkgs",
        "include", "third_party", "third-party", "thirdparty", "vendor", "vendors", "deps", "_deps", "cmsis", "esp-idf",
        "sdk", "sdks", "cache", "caches", "deriveddata", "locale", "locales", "dist", "build", "__pycache__", "bower_components",
        "pods", "carthage", "gems", "jdk", "toolchains", "user data", "deps-tmp", "deploy-tmp", "elm-stuff", "target",
        "history", "_vendor", "vendored", "node_modules", "jspm_packages", "venv", "env", "virtualenv",
        "__macosx", "temp", "tmp", "logs", "derived", "intermediates", "obj", "runtime", "lib64", "cmakefiles", "git-data", "cjs", "esm", "umd"]
    /// "~$Report.docx" (Office lock file), "Board.~(12).PcbDoc.Zip" (Altium history copy), "file.bak", "file~".
    static func isJunkFile(_ low: UnsafePointer<UInt8>, _ len: Int) -> Bool {
        if len >= 2 && low[0] == UInt8(ascii: "~") && low[1] == UInt8(ascii: "$") { return true }
        if len >= 1 && low[len - 1] == UInt8(ascii: "~") { return true }
        var i = 0
        while i + 2 < len { if low[i] == UInt8(ascii: ".") && low[i + 1] == UInt8(ascii: "~") && low[i + 2] == UInt8(ascii: "(") { return true }; i += 1 }
        if len > 4 { let e = String(decoding: UnsafeBufferPointer(start: low + len - 4, count: 4), as: UTF8.self); if e == ".bak" || e == ".tmp" { return true } }
        return false
    }

    static func isNoise(_ low: UnsafePointer<UInt8>, _ len: Int) -> Bool {
        if len == 0 || len > 40 { return false }
        let s = String(decoding: UnsafeBufferPointer(start: low, count: len), as: UTF8.self)
        if s.hasPrefix("python2.") || s.hasPrefix("python3.") || s.hasSuffix(".dist-info") || s.hasSuffix(".egg-info") || s.hasSuffix(".git") || s.hasSuffix(".xcassets") { return true }
        if names.contains(s) || s.hasPrefix("_temp_") || s.hasSuffix(".lproj") && s != "base.lproj" && s != "en.lproj" { return true }
        // other-language copies: ko_kr, ja_jp, zh_cn, pt-br …
        let b = Array(s.utf8)
        if b.count == 5 && (b[2] == 95 || b[2] == 45) && b[0] >= 97 && b[1] >= 97 && b[3] >= 97 && b[4] >= 97 && s != "en_us" && s != "en-us" { return true }
        return false
    }
}

/// Column store of file nodes. Parents always precede children.
final class NodeStore {
    let parent = Vec<Int32>(capacity: 1 << 16)
    let mtime = Vec<Int64>(capacity: 1 << 16)
    let size = Vec<Int64>(capacity: 1 << 16)
    let nameOff = Vec<UInt32>(capacity: 1 << 16)
    let lowOff = Vec<UInt32>(capacity: 1 << 16)
    let nameLen = Vec<UInt16>(capacity: 1 << 16)
    let lowLen = Vec<UInt16>(capacity: 1 << 16)
    let flags = Vec<UInt8>(capacity: 1 << 16)
    let kind = Vec<UInt8>(capacity: 1 << 16)
    let depth = Vec<UInt8>(capacity: 1 << 16)
    let names = Vec<UInt8>(capacity: 1 << 20)
    let lows = Vec<UInt8>(capacity: 1 << 20)

    var count: Int { parent.count }

    @discardableResult
    func add(name: UnsafeBufferPointer<UInt8>, parent par: Int32, mtime mt: Int64, size sz: Int64, flags fl: UInt8) -> Int32 {
        let id = Int32(count)
        var f = fl
        var d: UInt8 = 0
        if par >= 0 {
            if flags[Int(par)] & Flag.hidden != 0 { f |= Flag.hidden }
            if flags[Int(par)] & Flag.noise != 0 { f |= Flag.noise }
            d = depth[Int(par)] &+ 1
        }
        if name.count > 0 && name[0] == UInt8(ascii: ".") && f & Flag.root == 0 { f |= Flag.hidden }
        parent.append(par)
        mtime.append(mt)
        size.append(sz)
        flags.append(f)
        depth.append(d)
        nameOff.append(UInt32(names.count))
        nameLen.append(UInt16(min(name.count, 65535)))
        names.append(name.baseAddress!, count: min(name.count, 65535))
        // folded lowercase copy for matching
        let lowStart = lows.count
        var ascii = true
        for b in name where b >= 0x80 { ascii = false; break }
        if ascii {
            for b in name { lows.append((b >= 65 && b <= 90) ? b + 32 : b) }
        } else {
            let s = String(decoding: name, as: UTF8.self).folded
            var u = Array(s.utf8)
            u.withUnsafeMutableBufferPointer { lows.append($0.baseAddress!, count: $0.count) }
        }
        lowOff.append(UInt32(lowStart))
        lowLen.append(UInt16(min(lows.count - lowStart, 65535)))
        let isDir = f & Flag.dir != 0 && f & Flag.package == 0
        if f & Flag.noise == 0 {
            let lp = lows.p + lowStart, ll = lows.count - lowStart
            if isDir ? Noise.isNoise(lp, ll) : Noise.isJunkFile(lp, ll) { flags[Int(id)] = f | Flag.noise }
        }
        kind.append(isDir ? Kind.folder.rawValue : Kinds.kind(ofLowName: lows.p + lowStart, len: lows.count - lowStart).rawValue)
        return id
    }

    func add(name: String, parent par: Int32, mtime mt: Int64, size sz: Int64, flags fl: UInt8) -> Int32 {
        var u = Array(name.utf8)
        return u.withUnsafeMutableBufferPointer { add(name: UnsafeBufferPointer($0), parent: par, mtime: mt, size: sz, flags: fl) }
    }

    /// Append every node of `b`. Nodes of `b` with parent -1 are attached under `under`.
    func absorb(_ b: NodeStore, under: Int32) {
        let base = Int32(count)
        let nBase = UInt32(names.count), lBase = UInt32(lows.count)
        let pd: UInt8 = under >= 0 ? depth[Int(under)] &+ 1 : 0
        let hid = under >= 0 && flags[Int(under)] & Flag.hidden != 0
        let noi: UInt8 = under >= 0 && flags[Int(under)] & Flag.noise != 0 ? Flag.noise : 0
        for i in 0..<b.count {
            let bp = b.parent[i]
            parent.append(bp < 0 ? under : bp + base)
            nameOff.append(b.nameOff[i] + nBase)
            lowOff.append(b.lowOff[i] + lBase)
            depth.append(b.depth[i] &+ pd)
            flags.append((hid ? b.flags[i] | Flag.hidden : b.flags[i]) | noi)
        }
        mtime.append(b.mtime.p, count: b.count)
        size.append(b.size.p, count: b.count)
        nameLen.append(b.nameLen.p, count: b.count)
        lowLen.append(b.lowLen.p, count: b.count)
        kind.append(b.kind.p, count: b.count)
        names.append(b.names.p, count: b.names.count)
        lows.append(b.lows.p, count: b.lows.count)
    }

    @inline(__always) func name(_ i: Int) -> String {
        String(decoding: UnsafeBufferPointer(start: names.p + Int(nameOff[i]), count: Int(nameLen[i])), as: UTF8.self)
    }

    func path(_ i: Int) -> String {
        var chain: [Int] = []
        var c = i
        while c >= 0 { chain.append(c); c = Int(parent[c]) }
        var s = ""
        for (k, n) in chain.reversed().enumerated() {
            if k > 0 { s += "/" }
            s += name(n)
        }
        return s
    }
}

extension String {
    /// Case and accent folded form used for matching.
    var folded: String { folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased() }
}

/// Simple pthread read-write lock.
final class RWLock {
    private var l = pthread_rwlock_t()
    init() { pthread_rwlock_init(&l, nil) }
    deinit { pthread_rwlock_destroy(&l) }
    func read<R>(_ f: () throws -> R) rethrows -> R { pthread_rwlock_rdlock(&l); defer { pthread_rwlock_unlock(&l) }; return try f() }
    func write<R>(_ f: () throws -> R) rethrows -> R { pthread_rwlock_wrlock(&l); defer { pthread_rwlock_unlock(&l) }; return try f() }
}
