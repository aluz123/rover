// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import Foundation
import CoreServices

/// Finds files that take up space and haven't been used in ages, and suggests the Trash or a backup drive.
/// It only suggests: nothing moves until the person approves, nothing is ever permanently deleted,
/// and iCloud files, developer toolkits and Apple's own apps are never suggested.
public enum JunkCategory: String, CaseIterable, Codable {
    case installers, duplicates, apps, videos, big, downloads

    public var title: String {
        switch self {
        case .installers: return "Old installers"
        case .duplicates: return "Duplicate copies"
        case .apps: return "Apps you haven’t opened in 6 months"
        case .videos: return "Old videos and screen recordings"
        case .big: return "Big files untouched for a year"
        case .downloads: return "Old downloads you never opened again"
        }
    }
    public var why: String {
        switch self {
        case .installers: return "Disk images and installers you already used. The app stays installed."
        case .duplicates: return "Extra copies (same name, same size) untouched for 3 months. The most recently used copy is kept."
        case .apps: return "Moving an app to the Trash doesn’t touch your documents."
        case .videos: return "Large videos nobody has opened in over 6 months. Good candidates for a backup drive."
        case .big: return "Anything over 200 MB that hasn’t been opened in a year."
        case .downloads: return "PDFs, archives and other downloads not opened in a year."
        }
    }
    public var symbol: String {
        switch self {
        case .installers: return "shippingbox"
        case .duplicates: return "square.on.square"
        case .apps: return "app.dashed"
        case .videos: return "film"
        case .big: return "externaldrive"
        case .downloads: return "arrow.down.circle"
        }
    }
}

public struct JunkItem: Identifiable, Hashable, Codable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let size: Int64
    public let lastUsed: Int64       // seconds since 1970: last opened if macOS knows it, else last modified
    public let category: JunkCategory
    public let keptCopy: String?     // for duplicates: the copy that stays
}

public struct JunkReport {
    public let items: [JunkItem]
    public let millis: Double
    public init(items: [JunkItem], millis: Double) { self.items = items; self.millis = millis }
    public var total: Int64 { items.reduce(0) { $0 + $1.size } }
    public func items(in c: JunkCategory) -> [JunkItem] { items.filter { $0.category == c } }
    public func total(in c: JunkCategory) -> Int64 { items(in: c).reduce(0) { $0 + $1.size } }
}

public enum JunkFinder {
    static let installerExts: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
    static let archiveExts: Set<String> = ["zip", "tar", "gz", "tgz", "rar", "7z", "bz2", "xz"]
    static let day: Int64 = 86400

    /// Last time the file was opened, as Spotlight recorded it, falling back to modified / added dates.
    static let demo = ProcessInfo.processInfo.environment["ROVER_DEMO_HOME"] != nil
    static func lastUsed(_ path: String, mtime: Int64) -> Int64 {
        var best = mtime
        if demo { return best }   // the demo home's files were all "added" today
        if let item = MDItemCreate(nil, path as CFString) {
            for key in [kMDItemLastUsedDate, kMDItemDateAdded] {
                if let d = MDItemCopyAttribute(item, key) as? Date { best = max(best, Int64(d.timeIntervalSince1970)) }
            }
        }
        return best
    }

    static func bundleSize(_ path: String) -> Int64 {
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
        return total
    }

    public static func scan(_ engine: Engine = .shared, now: Date = Date()) -> JunkReport {
        let t0 = Date()
        guard let idx = engine.current else { return JunkReport(items: [], millis: 0) }
        let nowS = Int64(now.timeIntervalSince1970)
        let home = ProcessInfo.processInfo.environment["ROVER_DEMO_HOME"] ?? NSHomeDirectory()
        let homes = [home, home.hasPrefix("/private/") ? String(home.dropFirst(8)) : "/private" + home]
        let downloads = homes.map { $0 + "/Downloads/" }
        let appDirs = ["/Applications/", home + "/Applications/"]

        struct Cand { let i: Int; let path: String; let name: String; let ext: String; let size: Int64; let mtime: Int64; let kind: Kind; let isApp: Bool }
        var cands: [Cand] = []
        idx.lock.read {
            let s = idx.s
            for i in 0..<s.count {
                let f = s.flags[i]
                if f & (Flag.deleted | Flag.root | Flag.hidden | Flag.noise) != 0 { continue }
                let isPkg = f & Flag.package != 0
                if f & Flag.dir != 0 && !isPkg { continue }
                let kind = Kind(rawValue: s.kind[i]) ?? .other
                let size = s.size[i]
                // cheap pre-filter before building paths
                if !(isPkg && kind == .app) && size < 1 << 20 { continue }
                let path = s.path(i)
                if path.contains("/Library/Mobile Documents/") || path.hasPrefix("/System/") { continue }   // iCloud / macOS
                // libraries other apps manage (moving files out would break them)
                if path.contains("/Music/Music/") || path.contains("/Media.localized/") || path.contains("/Movies/TV/") || path.contains(".photoslibrary/") { continue }
                let name = s.name(i)
                let ext = (name as NSString).pathExtension.lowercased()
                cands.append(Cand(i: i, path: path, name: name, ext: ext, size: size, mtime: s.mtime[i], kind: kind, isApp: isPkg && kind == .app))
            }
        }

        // never suggest files inside a code project: a .git folder anywhere above them
        var repoCache: [String: Bool] = [:]
        func inRepo(_ path: String) -> Bool {
            var dir = (path as NSString).deletingLastPathComponent
            var seen: [String] = []
            while dir.count > 1 && dir != home {
                if let v = repoCache[dir] { for d in seen { repoCache[d] = v }; return v }
                seen.append(dir)
                if FileManager.default.fileExists(atPath: dir + "/.git") { for d in seen { repoCache[d] = true }; return true }
                dir = (dir as NSString).deletingLastPathComponent
            }
            for d in seen { repoCache[d] = false }
            return false
        }
        cands = cands.filter { $0.isApp || !inRepo($0.path) }
        var items: [JunkItem] = []
        var taken = Set<String>()
        func add(_ c: Cand, _ cat: JunkCategory, size: Int64? = nil, used: Int64, kept: String? = nil) {
            guard !taken.contains(c.path) else { return }
            taken.insert(c.path)
            items.append(JunkItem(path: c.path, name: c.name, size: size ?? c.size, lastUsed: used, category: cat, keptCopy: kept))
        }
        let inDownloads = { (p: String) in downloads.contains { p.hasPrefix($0) } }

        // 1. installers: disk images and packages (anywhere), archives sitting in Downloads; unused for 30 days
        for c in cands where !c.isApp && (installerExts.contains(c.ext) || (archiveExts.contains(c.ext) && inDownloads(c.path) && c.size >= 20 << 20)) {
            let u = lastUsed(c.path, mtime: c.mtime)
            if nowS - u > 30 * day { add(c, .installers, used: u) }
        }
        // 2. duplicates: same name and size (10 MB+); keep the most recently used copy
        var groups: [String: [Cand]] = [:]
        for c in cands where !c.isApp && c.size >= 10 << 20 { groups["\(c.name.lowercased())|\(c.size)", default: []].append(c) }
        for (_, g) in groups where g.count > 1 {
            let withUse = g.map { ($0, lastUsed($0.path, mtime: $0.mtime)) }.sorted { $0.1 > $1.1 }
            let keep = withUse[0].0.path
            for (c, u) in withUse.dropFirst() where nowS - u > 90 * day { add(c, .duplicates, used: u, kept: keep) }
        }
        // 3. apps you installed and haven't opened in 6 months (never Apple's own)
        for c in cands where c.isApp && appDirs.contains(where: { c.path.hasPrefix($0) }) {
            let depth = c.path.split(separator: "/").count - (c.path.hasPrefix(home) ? home.split(separator: "/").count + 1 : 1)
            if depth > 2 { continue }
            if let b = Bundle(path: c.path)?.bundleIdentifier, b.hasPrefix("com.apple.") { continue }
            let u = lastUsed(c.path, mtime: c.mtime)
            guard nowS - u > 180 * day else { continue }
            let sz = bundleSize(c.path)
            if sz >= 50 << 20 { add(c, .apps, size: sz, used: u) }
        }
        // 4. videos (100 MB+) not opened in 6 months
        for c in cands where c.kind == .video && c.size >= 100 << 20 {
            let u = lastUsed(c.path, mtime: c.mtime)
            if nowS - u > 180 * day { add(c, .videos, used: u) }
        }
        // 5. anything 200 MB+ untouched for a year
        for c in cands where !c.isApp && c.size >= 200 << 20 {
            let u = lastUsed(c.path, mtime: c.mtime)
            if nowS - u > 365 * day { add(c, .big, used: u) }
        }
        // 6. downloads (1 MB+) not opened in a year: old PDFs, archives, documents
        let docKinds: Set<Kind> = [.pdf, .doc, .sheet, .slides, .archive, .image, .audio, .video, .text]
        let shallow = { (p: String) -> Bool in   // in Downloads itself or one folder down, not inside an extracted app
            guard let d = downloads.first(where: { p.hasPrefix($0) }) else { return false }
            return p.dropFirst(d.count).split(separator: "/").count <= 2
        }
        for c in cands where !c.isApp && inDownloads(c.path) && shallow(c.path) && docKinds.contains(c.kind) && c.size >= 1 << 20 {
            let u = lastUsed(c.path, mtime: c.mtime)
            if nowS - u > 365 * day { add(c, .downloads, used: u) }
        }
        items.sort { $0.size > $1.size }
        return JunkReport(items: items, millis: Date().timeIntervalSince(t0) * 1000)
    }

    // MARK: actions

    public struct Volume: Hashable {
        public let name: String; public let path: String; public let free: Int64
        public init(name: String, path: String, free: Int64) { self.name = name; self.path = path; self.free = free }
    }

    /// External drives that can take a backup (not the startup disk, not read-only).
    public static func backupVolumes() -> [Volume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsReadOnlyKey, .volumeAvailableCapacityKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            if v.volumeIsRootFileSystem == true || v.volumeIsReadOnly == true { return nil }
            if v.volumeIsInternal == true && v.volumeIsRemovable != true { return nil }
            guard u.path.hasPrefix("/Volumes/") else { return nil }
            return Volume(name: v.volumeName ?? u.lastPathComponent, path: u.path, free: Int64(v.volumeAvailableCapacity ?? 0))
        }
    }

    public struct Result { public let moved: Int; public let bytes: Int64; public let failed: [(String, String)] }

    /// The Trash, or in demo mode a private folder inside the demo home (tests never touch the real Trash).
    static func toTrash(_ path: String) throws -> String? {
        if let demo = ProcessInfo.processInfo.environment["ROVER_DEMO_HOME"] {
            let t = demo + "/.rover-trash"; try FileManager.default.createDirectory(atPath: t, withIntermediateDirectories: true)
            let dest = t + "/" + Paths.freeName((path as NSString).lastPathComponent, in: t)
            try FileManager.default.moveItem(atPath: path, toPath: dest); return dest
        }
        var res: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &res)
        return res?.path
    }

    /// Moves items to the Trash (recoverable; ⌘Z puts them back).
    public static func trash(_ items: [JunkItem]) -> Result {
        let fm = FileManager.default
        var moves: [(from: String, to: String)] = [], failed: [(String, String)] = [], bytes: Int64 = 0
        for it in items {
            do {
                if let r = try toTrash(it.path) { moves.append((it.path, r)) }
                bytes += it.size
                Engine.shared.touched(it.path)
            } catch { failed.append((it.name, error.localizedDescription)) }
        }
        ActionRunner.shared.recordMoves("Free up space: \(moves.count) item(s) to Trash", moves)
        return Result(moved: moves.count, bytes: bytes, failed: failed)
    }

    /// Copies items to "<drive>/Rover Backup/<same folders as on your Mac>", checks each copy's size,
    /// then puts the original in the Trash (so nothing is lost if the drive fails later).
    public static func backup(_ items: [JunkItem], to vol: Volume) -> Result {
        let fm = FileManager.default
        let home = ProcessInfo.processInfo.environment["ROVER_DEMO_HOME"] ?? NSHomeDirectory()
        var moved = 0, bytes: Int64 = 0, failed: [(String, String)] = [], trashed: [(from: String, to: String)] = []
        let homes = [home, home.hasPrefix("/private/") ? String(home.dropFirst(8)) : "/private" + home]
        let need = items.reduce(Int64(0)) { $0 + $1.size }
        if need > vol.free { return Result(moved: 0, bytes: 0, failed: [("", "\(vol.name) has \(ByteCountFormatter.string(fromByteCount: vol.free, countStyle: .file)) free; these need \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file)).")]) }
        for it in items {
            let rel = homes.first(where: { it.path.hasPrefix($0 + "/") }).map { String(it.path.dropFirst($0.count)) } ?? it.path
            var dest = vol.path + "/Rover Backup" + (rel.hasPrefix("/") ? rel : "/" + rel)
            do {
                try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest) { dest = (dest as NSString).deletingLastPathComponent + "/" + Paths.freeName(it.name, in: (dest as NSString).deletingLastPathComponent) }
                try fm.copyItem(atPath: it.path, toPath: dest)
                let src = it.category == .apps ? bundleSize(it.path) : ((try? fm.attributesOfItem(atPath: it.path)[.size] as? Int64) ?? -1)
                let dst = it.category == .apps ? bundleSize(dest) : ((try? fm.attributesOfItem(atPath: dest)[.size] as? Int64) ?? -2)
                guard src == dst else { try? fm.removeItem(atPath: dest); failed.append((it.name, "the copy didn’t match, so the original was left in place")); continue }
                if let r = try toTrash(it.path) { trashed.append((it.path, r)) }
                moved += 1; bytes += it.size
                Engine.shared.touched(it.path)
            } catch { failed.append((it.name, error.localizedDescription)) }
        }
        // ⌘Z brings the originals back from the Trash (the backup copies stay on the drive)
        ActionRunner.shared.recordMoves("Free up space: \(trashed.count) item(s) backed up to \(vol.name)", trashed)
        return Result(moved: moved, bytes: bytes, failed: failed)
    }
}
