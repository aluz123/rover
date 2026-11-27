// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import Foundation

public enum HitSource { case name, content, image, drive }

public struct Hit: Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let mtime: Int64
    public let size: Int64
    public let isDir: Bool
    public let kind: Kind
    public let score: Double
    public var source: HitSource
    public var why: String
}

public struct SearchResult {
    public var hits: [Hit]
    public var query: ParsedQuery
    public var total: Int
    public var millis: Double
    public var expanded: [String]
}

@inline(__always) private func isAlnum(_ c: UInt8) -> Bool {
    (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c >= 0x80 || (c >= 65 && c <= 90)
}
@inline(__always) private func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

/// Per-node name matcher. All inputs are folded lowercase bytes.
enum Matcher {
    /// Word boundary at position i of the low name (orig is used to detect camelCase when byte-aligned).
    @inline(__always)
    static func boundary(_ n: UnsafePointer<UInt8>, _ o: UnsafePointer<UInt8>?, _ i: Int) -> Bool {
        if i == 0 { return true }
        let a = n[i - 1], b = n[i]
        if !isAlnum(a) { return true }
        if isDigit(a) != isDigit(b) { return true }
        if let o = o { let x = o[i - 1], y = o[i]; if x >= 97 && x <= 122 && y >= 65 && y <= 90 { return true } }
        return false
    }

    /// Score of term `t` against name `n` (len), or 0. `stemLen` = length without extension.
    static func score(_ n: UnsafePointer<UInt8>, _ len: Int, _ o: UnsafePointer<UInt8>?, stemLen: Int,
                      _ t: UnsafePointer<UInt8>, _ tl: Int, typo: Bool) -> Double {
        if tl == 0 || tl > len { return typo && tl >= 4 ? typoScore(n, len, t, tl) : 0 }
        var best = 0.0
        let first = t[0]
        var i = 0
        let last = len - tl
        while i <= last {
            if n[i] == first && memcmp(n + i, t, tl) == 0 {
                var s = 100.0
                if i == 0 {
                    s += 60
                    if tl == len { s += 90 } else if tl == stemLen { s += 80 }
                } else if boundary(n, o, i) { s += 35 }
                // whole word match
                if i + tl == len || !isAlnum(n[i + tl]) || i + tl == stemLen { s += 15 }
                if s > best { best = s }
                if best >= 250 { break }
            }
            i += 1
        }
        if best > 0 { return best }
        if tl >= 3 && tl <= 16 { let f = fuzzy(n, len, o, t, tl); if f > 0 { return f } }
        if typo && tl >= 4 { return typoScore(n, len, t, tl) }
        return 0
    }

    /// Subsequence match biased to word starts ("tr24" -> "Tax_Return_2024"). Strict to avoid noise.
    static func fuzzy(_ n: UnsafePointer<UInt8>, _ len: Int, _ o: UnsafePointer<UInt8>?, _ t: UnsafePointer<UInt8>, _ tl: Int) -> Double {
        // first char must sit on a word boundary
        var i = 0
        while i < len && !(n[i] == t[0] && boundary(n, o, i)) { i += 1 }
        if i >= len { return 0 }
        var bounds = 1, gaps = 0, run = 0, maxRun = 1
        var prev = i
        var j = 1
        i += 1
        while j < tl {
            // prefer next char at a boundary, else the nearest occurrence
            var k = i, hit = -1, bhit = -1
            while k < len {
                if n[k] == t[j] {
                    if hit < 0 { hit = k }
                    if boundary(n, o, k) { bhit = k; break }
                    if k == prev + 1 { break }
                }
                k += 1
            }
            var pos = hit
            if hit == prev + 1 { pos = hit } else if bhit >= 0 { pos = bhit } else { return 0 }
            if pos < 0 { return 0 }
            if pos == prev + 1 { run += 1; maxRun = max(maxRun, run + 1) } else { run = 0; gaps += 1 }
            if boundary(n, o, pos) && pos != prev + 1 { bounds += 1 }
            prev = pos
            i = pos + 1
            j += 1
        }
        // every jump must land on a word start, otherwise it is noise
        if gaps > bounds - 1 || bounds < 2 { return 0 }
        return 38 + Double(bounds) * 6 + Double(maxRun) * 2 - Double(gaps) * 2
    }

    /// One edit (insert/delete/substitute/transpose) against any word of the name, or its prefix.
    static func typoScore(_ n: UnsafePointer<UInt8>, _ len: Int, _ t: UnsafePointer<UInt8>, _ tl: Int) -> Double {
        var i = 0
        while i < len {
            while i < len && !isAlnum(n[i]) { i += 1 }
            var e = i
            while e < len && isAlnum(n[e]) && !(e > i && isDigit(n[e]) != isDigit(n[e - 1])) { e += 1 }
            let wl = e - i
            if wl >= tl - 1 {
                // compare against the word, or the word's prefix of similar length
                for cand in [wl, tl, tl + 1, tl - 1] where cand <= wl && cand >= tl - 1 && cand > 0 {
                    if osa1(n + i, cand, t, tl) { return cand == wl ? 48 : 40 }
                }
            }
            i = max(e, i + 1)
        }
        return 0
    }

    /// Optimal string alignment distance <= 1.
    static func osa1(_ a: UnsafePointer<UInt8>, _ al: Int, _ b: UnsafePointer<UInt8>, _ bl: Int) -> Bool {
        if abs(al - bl) > 1 { return false }
        var i = 0
        while i < al && i < bl && a[i] == b[i] { i += 1 }
        if i == al && i == bl { return false } // identical handled elsewhere
        if al == bl {
            // substitution or transposition
            if memcmp(a + i + 1, b + i + 1, al - i - 1) == 0 { return true }
            if i + 1 < al && a[i] == b[i + 1] && a[i + 1] == b[i] && memcmp(a + i + 2, b + i + 2, al - i - 2) == 0 { return true }
            return false
        }
        if al > bl { return memcmp(a + i + 1, b + i, bl - i) == 0 }
        return memcmp(a + i, b + i + 1, al - i) == 0
    }
}

struct SearchOptions {
    var typo = false
    var limit = 80
    var boosts: [Int32: Double] = [:]
    /// How many required words a file may miss (closest-match fallback).
    var allowMissing = 0
}

extension FileIndex {
    func search(_ q: ParsedQuery, _ opt: SearchOptions) -> (hits: [(Double, Int32, String)], total: Int) {
        lock.read { searchLocked(q, opt) }
    }

    private func searchLocked(_ q: ParsedQuery, _ opt: SearchOptions) -> (hits: [(Double, Int32, String)], total: Int) {
        let n = s.count
        if n == 0 { return ([], 0) }
        let now = Int64(Date().timeIntervalSince1970)
        let terms = q.terms
        let T = terms.count

        // raw column pointers (stable under the read lock; no ARC in the hot loop)
        let P = s.parent.p, MT = s.mtime.p, SZ = s.size.p, FL = s.flags.p, KD = s.kind.p, DP = s.depth.p
        let LO = s.lowOff.p, LL = s.lowLen.p, NO = s.nameOff.p, NL = s.nameLen.p
        let LOWS = s.lows.p, NAMES = s.names.p

        // flatten term alternatives into one byte arena
        var arenaBytes: [UInt8] = []
        var altStart: [Int] = [], altLen: [Int] = [], altW: [Double] = [], termAltFrom: [Int] = [], termAltTo: [Int] = []
        for t in terms {
            termAltFrom.append(altStart.count)
            for al in t.alts { altStart.append(arenaBytes.count); altLen.append(al.bytes.count); altW.append(al.weight); arenaBytes += al.bytes }
            termAltTo.append(altStart.count)
        }
        let arena = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, arenaBytes.count))
        arena.initialize(from: arenaBytes, count: arenaBytes.count)
        defer { arena.deallocate() }
        let A = altStart.count
        let aS = UnsafeMutablePointer<Int>.allocate(capacity: max(1, A)); aS.initialize(from: altStart, count: A)
        let aL = UnsafeMutablePointer<Int>.allocate(capacity: max(1, A)); aL.initialize(from: altLen, count: A)
        let aW = UnsafeMutablePointer<Double>.allocate(capacity: max(1, A)); aW.initialize(from: altW, count: A)
        let tF = UnsafeMutablePointer<Int>.allocate(capacity: max(1, T)); tF.initialize(from: termAltFrom, count: T)
        let tT = UnsafeMutablePointer<Int>.allocate(capacity: max(1, T)); tT.initialize(from: termAltTo, count: T)
        let tLoc = UnsafeMutablePointer<Bool>.allocate(capacity: max(1, T)); tLoc.initialize(from: terms.map { $0.locationOnly }, count: T)
        let tSoftLo = UnsafeMutablePointer<Int64>.allocate(capacity: max(1, T)); tSoftLo.initialize(from: terms.map { $0.softTime?.lowerBound ?? Int64.max }, count: T)
        let tSoftHi = UnsafeMutablePointer<Int64>.allocate(capacity: max(1, T)); tSoftHi.initialize(from: terms.map { $0.softTime?.upperBound ?? Int64.min }, count: T)
        let tOpt = UnsafeMutablePointer<Bool>.allocate(capacity: max(1, T)); tOpt.initialize(from: terms.map { $0.optional }, count: T)
        let tKindW = UnsafeMutablePointer<Bool>.allocate(capacity: max(1, T)); tKindW.initialize(from: terms.map { $0.kindWord }, count: T)
        let hasKindTerms = terms.contains { $0.kindWord }
        let tBackup = UnsafeMutablePointer<Bool>.allocate(capacity: max(1, T)); tBackup.initialize(from: terms.map { $0.backup }, count: T)
        let required = terms.filter { !$0.optional }.count
        defer { aS.deallocate(); aL.deallocate(); aW.deallocate(); tF.deallocate(); tT.deallocate(); tLoc.deallocate(); tSoftLo.deallocate(); tSoftHi.deallocate(); tOpt.deallocate(); tKindW.deallocate(); tBackup.deallocate() }

        // installed apps (like Spotlight's top hits): .app bundles directly in an Applications folder or one folder below it
        var appParents = Set<Int32>()
        let home = ProcessInfo.processInfo.environment["ROVER_DEMO_HOME"] ?? NSHomeDirectory()
        for base in ["/Applications", "/System/Applications", home + "/Applications"] {
            guard let d = lookup(base) else { continue }
            appParents.insert(d)
            if Int(d) < children.count { for c in children[Int(d)] where FL[Int(c)] & Flag.dir != 0 && FL[Int(c)] & Flag.package == 0 { appParents.insert(c) } }
        }
        let appK = Int(Kind.app.rawValue)
        // apps only get the top-hit lift for name-like searches, not "pdfs from last week"
        let nameLike = q.after == nil && q.before == nil && q.minSize == nil && q.maxSize == nil && q.exts.isEmpty && q.sort == .relevance
        let chunks = max(1, min(64, n / 8000))
        let per = (n + chunks - 1) / chunks

        // ancestor folder matches: bit (1<<term) set when the node itself is a matching folder,
        // bit (1<<(term+16)) when any ancestor matches. Folder self-matches run in parallel; propagation is one linear pass.
        let anc = UnsafeMutablePointer<UInt32>.allocate(capacity: n)
        anc.initialize(repeating: 0, count: n)
        defer { anc.deallocate() }
        if T > 0 {
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * per, hi = min(n, lo + per)
                for i in lo..<hi {
                    let f = FL[i]
                    if f & Flag.dir == 0 || f & (Flag.package | Flag.root | Flag.deleted) != 0 { continue }
                    let np = LOWS + Int(LO[i]), nl = Int(LL[i])
                    var bits: UInt32 = 0
                    for ti in 0..<min(T, 16) {
                        var a = tF[ti]
                        while a < tT[ti] {
                            let tp = arena + aS[a], tl = aL[a]
                            a += 1
                            if tl == 0 || tl > nl { continue }
                            var k = 0
                            var found = false
                            while k <= nl - tl {
                                if np[k] == tp[0] && memcmp(np + k, tp, tl) == 0 && Matcher.boundary(np, nil, k) { found = true; break }
                                k += 1
                            }
                            if found { bits |= 1 << UInt32(ti); break }
                        }
                    }
                    anc[i] = bits
                }
            }
            for i in 0..<n {
                let p = Int(P[i])
                if p >= 0 { let pa = anc[p]; anc[i] |= ((pa & 0xFFFF) | (pa >> 16)) << 16 }
            }
        }

        let K = opt.limit * 3
        var parts = [[(Double, Int32)]](repeating: [], count: chunks)
        var totals = [Int](repeating: 0, count: chunks)
        let partsLock = NSLock()
        let kindFilter: [Bool] = (0..<16).map { q.kinds.isEmpty || q.kinds.contains(Kind(rawValue: UInt8($0)) ?? .other) }
        let extFilter = q.exts
        let sort = q.sort
        let after = q.after ?? Int64.min
        let before = q.before ?? Int64.max
        let minSize = q.minSize, maxSize = q.maxSize
        let typo = opt.typo
        let boosts = opt.boosts
        let hasBoosts = !boosts.isEmpty
        let allowMissing = opt.allowMissing
        // a file must match at least one real word (or all optional words if that is all there is)
        // most people look for documents: program code ranks a bit lower unless the search is about code
        let codeK = Int(Kind.code.rawValue)
        let pdfK = Int(Kind.pdf.rawValue), docK = Int(Kind.doc.rawValue), slidesK = Int(Kind.slides.rawValue), sheetK = Int(Kind.sheet.rawValue)
        let codeIntent = q.kinds.contains(.code) || !q.exts.isEmpty
        let needAny = required == 0 && T > 0 && !q.hasFilters

        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            var local: [(Double, Int32)] = []
            local.reserveCapacity(K * 2)
            var total = 0
            let lo = c * per, hi = min(n, lo + per)
            var i = lo - 1
            while true {
                i += 1
                if i >= hi { break }
                let f = FL[i]
                if f & (Flag.deleted | Flag.root) != 0 { continue }
                if sort != .relevance && f & Flag.hidden != 0 { continue }
                let k = Int(KD[i])
                let kindOK = kindFilter[k]
                if !kindOK && !hasKindTerms { continue }
                let mt = MT[i]
                if mt < after || mt > before { continue }
                let isDir = f & Flag.dir != 0 && f & Flag.package == 0
                if let m = minSize, isDir || SZ[i] < m { continue }
                if let m = maxSize, isDir || SZ[i] > m { continue }
                let np = LOWS + Int(LO[i]), nl = Int(LL[i])
                if !extFilter.isEmpty {
                    var d = nl - 1
                    while d > 0 && np[d] != UInt8(ascii: ".") { d -= 1 }
                    if d <= 0 { continue }
                    let e = String(decoding: UnsafeBufferPointer(start: np + d + 1, count: nl - d - 1), as: UTF8.self)
                    if !extFilter.contains(e) { continue }
                }
                var stem = nl
                if !isDir { var d = nl - 1; while d > 0 && np[d] != UInt8(ascii: ".") { d -= 1 }; if d > 0 && nl - d <= 9 { stem = d } }
                let op: UnsafePointer<UInt8>? = Int(NL[i]) == nl ? UnsafePointer(NAMES + Int(NO[i])) : nil
                let ab = anc[i]

                var score = 0.0
                var ok = true
                var missing = 0, matchedReq = 0, matchedOpt = 0
                var tier = 0.0
                var kindNameHit = false
                var prevOptHit = false
                var nameMin = 1e9, nameHits = 0
                var ti = 0
                while ti < T {
                    var best = 0.0
                    if !tLoc[ti] {
                        var a = tF[ti]
                        while a < tT[ti] {
                            let sc = Matcher.score(np, nl, op, stemLen: stem, arena + aS[a], aL[a], typo: typo) * aW[a]
                            if sc > best { best = sc }
                            a += 1
                        }
                    }
                    if best > 0 && !tOpt[ti] { nameHits += 1; nameMin = min(nameMin, best) }
                    if best == 0 && ti < 16 {
                        if ab & (1 << UInt32(ti + 16)) != 0 { best = tLoc[ti] ? 30 : 24 }
                        // "in downloads" means things inside Downloads, not the Downloads folder itself
                        else if tLoc[ti] && ab & (1 << UInt32(ti)) != 0 { ok = false; break }
                    }
                    if best == 0 && tLoc[ti] {
                        // "from john": no folder called john, so a file named for john counts too (a bit less)
                        var a = tF[ti]
                        while a < tT[ti] {
                            let sc = Matcher.score(np, nl, op, stemLen: stem, arena + aS[a], aL[a], typo: false) * aW[a] * 0.6
                            if sc > best { best = sc }
                            a += 1
                        }
                    }
                    if best == 0 && mt >= tSoftLo[ti] && mt <= tSoftHi[ti] { best = 20 }
                    if tOpt[ti] {
                        // nice-to-have: a name hit lifts the file, a miss costs nothing
                        if tBackup[ti] && prevOptHit { ti += 1; continue }
                        prevOptHit = best >= 60
                        if best >= 60 { score += best * (tBackup[ti] ? 0.3 : 0.55); matchedOpt += 1; tier += tBackup[ti] ? 0.5 : 1 }
                        if tKindW[ti] && best >= 135 { kindNameHit = true }
                        ti += 1; continue
                    }
                    if best == 0 {
                        missing += 1
                        if missing > allowMissing { ok = false; break }
                        score -= 70
                        ti += 1; continue
                    }
                    matchedReq += 1
                    // match quality decides the tier for "newest first": a clean word match beats a related word or fuzzy hit
                    tier += best >= 140 ? 2 : (best >= 60 ? 1.5 : 1)
                    score += best
                    ti += 1
                }
                if !ok { continue }
                if required > 0 && matchedReq == 0 { continue }
                if needAny && matchedOpt == 0 { continue }
                // "presentation" also finds "Presentation notes.docx": a file named with the kind word counts, a little lower
                if !kindOK { if !kindNameHit || (k == codeK && !codeIntent) || f & Flag.noise != 0 { continue }; score -= 45 }
                total += 1

                // context boosts
                let age = Double(max(0, now - mt)) / 86400
                if mt <= now + 86400 { score += 22 * exp(-age / 10) + 8 * exp(-age / 180) }
                if f & Flag.hidden != 0 { score -= 30 }
                if f & Flag.noise != 0 { score = score * 0.6 - 30; tier -= 1 }
                if k == codeK && !codeIntent { score -= 32; tier -= 0.5 }
                if k == pdfK || k == docK || k == slidesK || k == sheetK { score += 8 }
                let dpt = Int(DP[i])
                if dpt > 4 { score -= Double(dpt - 4) * 1.5 }
                score -= Double(nl) * 0.12
                if k == appK {
                    if appParents.contains(P[i]) {
                        // an installed app whose name starts with what you typed is the top hit ("term" → Terminal, "chrome" → Google Chrome)
                        let all = nameHits == required && required > 0
                        if nameLike && all && nameMin >= 135 { score += 140 }
                        else if nameLike && all { score += 70 }
                        else { score += 18 }
                    } else { score += 4 }
                }
                if isDir { score += 4; tier -= 0.75 }   // "latest invoice" wants the file, not the folder it landed in
                if hasBoosts, let b = boosts[Int32(i)] { score += b }

                switch sort {
                // newest/oldest/biggest first, but only among files that match the words equally well
                case .newest: score = tier * 1e10 + Double(min(mt, now)) + score * 1e-4
                case .oldest: score = tier * 1e10 - Double(mt) + score * 1e-4
                case .largest: score = tier * 1e13 + Double(SZ[i]) + score * 1e-4
                case .relevance: break
                }
                local.append((score, Int32(i)))
                if local.count >= K * 2 {
                    local.sort { $0.0 > $1.0 }
                    local.removeLast(local.count - K)
                }
            }
            local.sort { $0.0 > $1.0 }
            if local.count > K { local.removeLast(local.count - K) }
            partsLock.lock(); parts[c] = local; totals[c] = total; partsLock.unlock()
        }
        var all = parts.flatMap { $0 }
        all.sort { $0.0 > $1.0 }
        // keep variety: at most 6 hits per folder in relevance mode
        // variety: after 6 hits from one folder, further ones are moved down (not dropped)
        var perDir: [Int32: Int] = [:]
        var out: [(Double, Int32, String)] = []
        var overflow: [(Double, Int32)] = []
        for (sc, id) in all {
            let p = P[Int(id)]
            let c = perDir[p, default: 0]
            perDir[p] = c + 1
            if c >= 6 && sort == .relevance { overflow.append((sc, id)); continue }
            out.append((sc, id, s.path(Int(id))))
            if out.count >= opt.limit { break }
        }
        for (sc, id) in overflow where out.count < opt.limit { out.append((sc, id, s.path(Int(id)))) }
        return (out, totals.reduce(0, +))
    }

    func hit(_ id: Int32, path: String, score: Double) -> Hit {
        lock.read {
            let i = Int(id)
            let f = s.flags[i]
            return Hit(path: path, name: s.name(i), mtime: s.mtime[i], size: s.size[i],
                       isDir: f & Flag.dir != 0 && f & Flag.package == 0, kind: Kind(rawValue: s.kind[i]) ?? .other,
                       score: score, source: .name, why: "")
        }
    }
}
