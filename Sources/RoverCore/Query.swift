// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import Foundation

public enum SortMode { case relevance, newest, oldest, largest }

struct Alt {
    let bytes: [UInt8]
    let weight: Double
    let label: String
}

struct Term {
    var word: String
    var alts: [Alt]
    var locationOnly = false
    /// Nice-to-have words ("short", "deck"): a name match ranks higher, but files without it still count.
    var optional = false
    /// A kind word ("photo", "presentation"): files of that kind qualify, and so does any file named with the word.
    var kindWord = false
    /// Only counts when the term just before it found nothing (other spellings of the same word).
    var backup = false
    /// Year / month words also match on modification date.
    var softTime: ClosedRange<Int64>? = nil
}

public struct ParsedQuery {
    var terms: [Term] = []
    public var kinds: Set<Kind> = []
    public var exts: Set<String> = []
    public var after: Int64? = nil
    public var before: Int64? = nil
    public var minSize: Int64? = nil
    public var maxSize: Int64? = nil
    public var contentWords: [String] = []
    public var sort: SortMode = .relevance
    public var chips: [String] = []
    public var raw = ""

    public var nameWords: [String] { terms.map { $0.word } }
    public var hasFilters: Bool { !kinds.isEmpty || !exts.isEmpty || after != nil || before != nil || minSize != nil || maxSize != nil }
    public var isEmpty: Bool { terms.isEmpty && !hasFilters && contentWords.isEmpty }

    /// Does a file's metadata pass the non-name filters?
    func passes(kind k: Kind, ext: String, mtime: Int64, size: Int64, isDir: Bool) -> Bool {
        if !kinds.isEmpty && !kinds.contains(k) { return false }
        if !exts.isEmpty && !exts.contains(ext) { return false }
        if let a = after, mtime < a { return false }
        if let b = before, mtime > b { return false }
        if let m = minSize, isDir || size < m { return false }
        if let m = maxSize, isDir || size > m { return false }
        return true
    }
}

enum QueryParser {
    static let stop: Set<String> = ["the", "a", "an", "my", "that", "this", "file", "files", "with", "called", "named",
                                    "for", "of", "i", "find", "show", "me", "where", "is", "was", "were", "and", "or",
                                    "some", "any", "all", "which", "what", "to", "it", "those", "these", "get", "open",
                                    "search", "look", "made", "created", "edited", "modified", "saved", "downloaded",
                                    "changed", "had", "have", "ive", "i've", "one", "thing", "stuff", "please", "by", "earlier", "around",
                                    "maybe", "probably", "just", "like", "can", "you", "we", "us", "our", "your", "im", "i'm",
                                    "got", "sent", "received", "need", "want", "think", "there", "somewhere", "again", "back",
                                    "version", "copy", "re", "when", "who", "how", "did", "do", "does", "be", "been", "am", "are",
                                    "its", "it's", "they", "he", "she", "them", "him", "her", "his", "their", "ago"]

    static let kindWords: [String: Set<Kind>] = [
        "pdf": [.pdf], "pdfs": [.pdf],
        "image": [.image], "images": [.image], "photo": [.image], "photos": [.image], "picture": [.image],
        "pictures": [.image], "pic": [.image], "pics": [.image], "img": [.image], "screenshot": [.image], "screenshots": [.image],
        "video": [.video], "videos": [.video], "movie": [.video], "movies": [.video],
        "recording": [.video, .audio], "recordings": [.video, .audio], "screencast": [.video],
        "audio": [.audio], "song": [.audio], "songs": [.audio], "music": [.audio], "podcast": [.audio],
        "doc": [.doc], "docs": [.doc], "document": [.doc, .pdf, .text], "documents": [.doc, .pdf, .text],
        "spreadsheet": [.sheet], "spreadsheets": [.sheet], "excel": [.sheet], "sheet": [.sheet], "sheets": [.sheet],
        "csv": [.sheet],
        "slides": [.slides], "slide": [.slides], "deck": [.slides, .pdf], "decks": [.slides, .pdf], "presentation": [.slides, .pdf],
        "presentations": [.slides, .pdf], "powerpoint": [.slides], "keynote": [.slides],
        "code": [.code], "script": [.code], "scripts": [.code],
        "zip": [.archive], "archive": [.archive], "archives": [.archive], "dmg": [.archive], "installer": [.archive, .app],
        "folder": [.folder], "folders": [.folder], "directory": [.folder], "directories": [.folder], "dir": [.folder],
        "app": [.app], "apps": [.app], "application": [.app],
        "email": [.email], "emails": [.email],
        "txt": [.text], "markdown": [.text],
    ]
    /// Describing words people add ("the short pitch deck"). Each is optional and also matches its usual spellings in names.
    static let softWords: [String: [String]] = [
        "short": ["short", "shorter", "brief", "mini", "lite", "summary", "condensed", "teaser", "onepager", "one pager", "one-pager",
                  "1pager", "1 pager", "1min", "2min", "3min", "5min", "1 min", "2 min", "3 min", "5 min", "quick"],
        "brief": ["brief", "short", "summary", "onepager", "one pager", "one-pager", "teaser"],
        "summary": ["summary", "brief", "overview", "onepager", "one pager", "one-pager", "short"],
        "long": ["long", "full", "extended", "complete", "detailed"],
        "full": ["full", "long", "extended", "complete", "detailed"],
        "final": ["final", "fin", "approved", "signed"],
        "updated": ["updated", "update", "new", "revised", "current", "latest"],
        "current": ["current", "latest", "updated", "new"],
        "old": ["old", "previous", "prev", "archive", "archived"],
        "draft": ["draft", "wip", "rough"],
        "signed": ["signed", "executed", "final"],
    ]
    /// Kind words that are also how people name the file ("Pitch Deck.pdf"): kept as an optional name word too.
    static let kindNameAlts: [String: [String]] = [
        "deck": ["deck", "slides", "presentation"], "decks": ["deck", "slides", "presentation"],
        "slides": ["slides", "deck", "presentation"], "presentation": ["presentation", "deck", "slides"],
        "presentations": ["presentation", "deck", "slides"],
        "spreadsheet": ["spreadsheet", "sheet"], "invoice": ["invoice"],
        "photo": ["photo", "img", "image"], "photos": ["photo", "img", "image"], "video": ["video", "clip"],
        "recording": ["recording", "rec"], "document": ["doc", "document"],
    ]
    /// Kind words too short or generic to look for in names.
    static let kindNoName: Set<String> = ["doc", "docs", "txt", "csv", "zip", "dmg", "app", "apps", "dir", "pic", "pics", "img",
                                          "code", "folder", "folders", "directory", "directories", "pdf", "pdfs", "excel", "markdown"]
    /// Kind words that also commonly appear in file names (e.g. "Screenshot 2026-…").
    static let kindAlsoName: Set<String> = ["screenshot", "screenshots", "recording", "recordings"]

    static let seasons = ["summer", "fall", "winter", "spring"]
    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                         "october", "november", "december"]
    static let monthShort = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// Conversational phrasing → search words. "can you find the deck I made a couple weeks ago" → "deck 2 weeks ago".
    static let fillers: [(NSRegularExpression, String)] = {
        let pairs: [(String, String)] = [
            (#"^\s*(hey|ok|okay|yo|um+|uh+)[,\s]+"#, ""),
            (#"^\s*rover[,:\s]+"#, ""),
            (#"\b(can|could|would|will) you( please)?( help me)?( (find|show|get|pull up|open|look for|search for|locate|grab|dig up))?( me)?\b"#, " "),
            (#"\b(please|pls|plz)\b"#, " "),
            (#"\bhelp me (find|locate|get)\b"#, " "),
            (#"\bi('m| am)? ?(looking|searching|hunting) for\b"#, " "),
            (#"\bi (need|want|wanna|have to find)( to (find|see|open|get))?\b"#, " "),
            (#"\bdo you know where\b"#, " "),
            (#"\bwhere('s| is| are| was| were| did i (put|save|leave|keep)| the heck is)\b"#, " "),
            (#"\bi (think|guess|believe)( it was| it's| its)?\b"#, " "),
            (#"\b(something|somethin) (like|called)\b"#, " "),
            (#"\b(kind|sort) of\b"#, " "),
            (#"\b(it's|its|it was|was|is) (called|named|titled)\b"#, " "),
            (#"\bthe (one|file|thing)( (that|which|where))?\b"#, " "),
            (#"\b(that|which)? ?i (downloaded|dl'd)\b"#, " in downloads "),
            (#"\b(that|which)? ?(i|we|they|someone|he|she)( had| have)? (made|wrote|written|saved|created|sent|got|received|edited|worked on|exported|shared|uploaded|signed|scanned|put|started|did|took)\b"#, " "),
            (#"\b(that|which) (was|were|got) (sent|shared|uploaded|exported)\b"#, " "),
            (#"\b(a couple|couple)( of)?(?= (days|weeks|months|years)\b)"#, " 2"),
            (#"\b(a few|few|several)(?= (days|weeks|months|years)\b)"#, " 3"),
            (#"\ba (day|week|month|year) ago\b"#, " 1 $1 ago "),
            (#"\b(a while|ages|long time|forever) ago\b"#, " awhileago "),
            (#"\bearlier (today|this morning)\b"#, " today "),
            (#"\b(this morning|this afternoon|this evening|tonight|just now|earlier today)\b"#, " today "),
            (#"\bearlier this\b"#, " this "),
            (#"\bover the weekend\b"#, " lastweekend "),
            (#"\b(last|this|past) weekend\b"#, " $1weekend "),
            (#"[?!.]+$"#, ""),
        ]
        return pairs.map { (try! NSRegularExpression(pattern: $0.0, options: [.caseInsensitive]), $0.1) }
    }()
    static let numberWords: [String: String] = ["one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12"]

    static func naturalize(_ text: String) -> String {
        var t = text
        // leave quoted phrases alone
        if t.contains("\"") || t.contains("“") { return t }
        for (re, rep) in fillers {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: rep)
        }
        return t
    }

    static func parse(_ text: String, now: Date = Date()) -> ParsedQuery {
        var q = ParsedQuery()
        q.raw = text
        let text = naturalize(text)
        let cal = Calendar.current
        func ts(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970) }
        func startOfDay(_ d: Date) -> Date { cal.startOfDay(for: d) }

        // tokens; quoted phrases go to content
        var tokens: [String] = []
        var cur = ""
        var inQuote = false
        for ch in text {
            if ch == "\"" || ch == "“" || ch == "”" {
                if inQuote { if !cur.isEmpty { q.contentWords.append(cur) }; cur = "" }
                else if !cur.isEmpty { tokens.append(cur); cur = "" }
                inQuote.toggle(); continue
            }
            if !inQuote && (ch == " " || ch == "," || ch == "\t") { if !cur.isEmpty { tokens.append(cur) }; cur = ""; continue }
            cur.append(ch)
        }
        if !cur.isEmpty { if inQuote { q.contentWords.append(cur) } else { tokens.append(cur) } }

        var low = tokens.map { $0.folded }
        // "two weeks ago" → "2 weeks ago" (only when a time unit follows, so "one pager" stays a word)
        for j in low.indices where j + 1 < low.count {
            if let d = numberWords[low[j]], ["day", "days", "week", "weeks", "month", "months", "year", "years"].contains(low[j + 1]) { low[j] = d; tokens[j] = d }
        }
        var i = 0
        var contentMode = false
        var pendingLocation = false
        var chips: [String] = []

        func setRange(_ a: Date, _ b: Date?, _ chip: String) {
            q.after = ts(a); q.before = b.map(ts); chips.append(chip)
        }

        while i < low.count {
            let w = low[i]
            let next = i + 1 < low.count ? low[i + 1] : ""
            let orig = tokens[i]

            // content introducers
            if ["containing", "contains", "mentions", "mentioning", "about", "says", "saying", "inside:", "content:", "with:"].contains(w) {
                contentMode = true; i += 1; continue
            }
            if contentMode && !stop.contains(w) { q.contentWords.append(orig); i += 1; continue }

            // extensions
            if w.hasPrefix("*.") || (w.hasPrefix(".") && w.count >= 2 && w.count <= 9 && !w.dropFirst().contains(".")) || w.hasPrefix("ext:") {
                let e = w.replacingOccurrences(of: "ext:", with: "").replacingOccurrences(of: "*", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if !e.isEmpty { q.exts.insert(e); chips.append("." + e) }
                i += 1; continue
            }

            // time
            if w == "today" { setRange(startOfDay(now), nil, "today"); i += 1; continue }
            if w == "awhileago" {
                q.before = ts(cal.date(byAdding: .day, value: -30, to: now)!); chips.append("over a month old"); i += 1; continue
            }
            if w == "lastweekend" || w == "thisweekend" || w == "pastweekend" {
                // the most recent Saturday–Sunday (this one if it is the weekend now)
                var d = startOfDay(now)
                let wd = cal.component(.weekday, from: d) // 1 = Sunday, 7 = Saturday
                if w == "thisweekend" && (wd == 1 || wd == 7) { d = wd == 1 ? cal.date(byAdding: .day, value: -1, to: d)! : d }
                else { while cal.component(.weekday, from: d) != 7 || d >= startOfDay(now) { d = cal.date(byAdding: .day, value: -1, to: d)! } }
                setRange(d, cal.date(byAdding: .day, value: 2, to: d)!, "last weekend"); i += 1; continue
            }
            // seasons: "last summer" filters; a bare "summer" also matches names ("Summer Camp")
            if let si = seasons.firstIndex(of: w == "autumn" ? "fall" : w) {
                let pre = i > 0 ? low[i - 1] : ""
                var y = cal.component(.year, from: now)
                let startMonth = [6, 9, 12, 3][si]
                func range(_ yy: Int) -> (Date, Date) {
                    let a = cal.date(from: DateComponents(year: yy, month: startMonth, day: 1))!
                    return (a, cal.date(byAdding: .month, value: 3, to: a)!)
                }
                if let ny = Int(next), ny >= 1990 && ny <= 2100 { y = ny; i += 1 }
                else {
                    // most recent season that has started (or finished, for "last")
                    while range(y).0 > now { y -= 1 }
                    if pre == "last" && range(y).1 > now { y -= 1 }
                }
                let (a, b) = range(y)
                if pre == "last" || pre == "this" || pre == "past" {
                    setRange(a, b, "\(w) \(y)")
                } else {
                    var t = Term(word: w, alts: alts(for: w)); t.softTime = ts(a)...ts(b); q.terms.append(t)
                    chips.append("\(w) \(y)")
                }
                i += 1; continue
            }
            // "since march", "before 2024", "after june 2025"
            if ["since", "after", "before", "until", "till"].contains(w), !next.isEmpty {
                var a: Date? = nil, b: Date? = nil, used = 2, label = next
                if let y = Int(next), y >= 1990 && y <= 2100 {
                    a = cal.date(from: DateComponents(year: y, month: 1, day: 1)); b = cal.date(from: DateComponents(year: y + 1, month: 1, day: 1))
                } else if let m = months.firstIndex(of: next) ?? (next.count == 3 ? monthShort.firstIndex(of: next) : nil) {
                    var y = cal.component(.year, from: now)
                    if i + 2 < low.count, let ny = Int(low[i + 2]), ny >= 1990 && ny <= 2100 { y = ny; used = 3; label += " \(ny)" }
                    else if m + 1 > cal.component(.month, from: now) { y -= 1 }
                    a = cal.date(from: DateComponents(year: y, month: m + 1, day: 1)); b = cal.date(byAdding: .month, value: 1, to: a!)
                }
                if let a = a, let b = b {
                    if w == "before" || w == "until" || w == "till" { q.before = ts(a); chips.append("before \(label)") }
                    else if w == "after" { q.after = ts(b); chips.append("after \(label)") }
                    else { q.after = ts(a); chips.append("since \(label)") }
                    i += used; continue
                }
                if w == "since" || w == "until" || w == "till" { i += 1; continue }
            }
            if w == "yesterday" {
                let y = cal.date(byAdding: .day, value: -1, to: startOfDay(now))!
                setRange(y, startOfDay(now), "yesterday"); i += 1; continue
            }
            if w == "recent" || w == "recently" || w == "latest" || w == "newest" || w == "new" {
                q.sort = .newest
                if q.after == nil && w.hasPrefix("recent") { q.after = ts(cal.date(byAdding: .day, value: -30, to: now)!) }
                chips.append("newest first"); i += 1; continue
            }
            if w == "oldest" { q.sort = .oldest; chips.append("oldest first"); i += 1; continue }
            if w == "biggest" || w == "largest" { q.sort = .largest; chips.append("biggest first"); i += 1; continue }
            if (w == "last" || w == "past" || w == "this" || w == "previous") && (seasons.contains(next) || next == "autumn") { i += 1; continue }
            if (w == "last" || w == "past" || w == "this" || w == "previous") && !next.isEmpty {
                let unitMap: [String: Calendar.Component] = ["day": .day, "days": .day, "week": .weekOfYear, "weeks": .weekOfYear,
                                                             "month": .month, "months": .month, "year": .year, "years": .year]
                // "last 3 days"
                if let n = Int(next), i + 2 < low.count, let u = unitMap[low[i + 2]] {
                    setRange(cal.date(byAdding: u, value: -n, to: now)!, nil, "past \(n) \(low[i + 2])"); i += 3; continue
                }
                if let u = unitMap[next] {
                    if w == "this" {
                        let iv = cal.dateInterval(of: u == .day ? .day : u, for: now)!
                        setRange(iv.start, nil, "this \(next)")
                    } else if w == "past" {
                        setRange(cal.date(byAdding: u, value: -1, to: now)!, nil, "past \(next)")
                    } else {
                        // forgiving: from the start of the previous period until now
                        let prev = cal.date(byAdding: u, value: -1, to: now)!
                        setRange(cal.dateInterval(of: u, for: prev)!.start, nil, "since last \(next)")
                    }
                    i += 2; continue
                }
            }
            // "3 weeks ago"
            if let n = Int(w), i + 2 < low.count, low[i + 2] == "ago" {
                let unitMap: [String: Calendar.Component] = ["day": .day, "days": .day, "week": .weekOfYear, "weeks": .weekOfYear,
                                                             "month": .month, "months": .month, "year": .year, "years": .year]
                if let u = unitMap[next] {
                    let center = cal.date(byAdding: u, value: -n, to: now)!
                    let lo = cal.date(byAdding: u, value: -1, to: center)!, hi = cal.date(byAdding: u, value: 1, to: center)!
                    setRange(lo, hi, "~\(n) \(next) ago"); i += 3; continue
                }
            }
            // sizes
            if ["big", "large", "huge", "massive", "giant"].contains(w) {
                q.minSize = (w == "huge" || w == "massive" || w == "giant") ? 1 << 30 : 50 << 20
                chips.append(q.minSize! >= 1 << 30 ? "> 1 GB" : "> 50 MB"); i += 1; continue
            }
            if ["small", "tiny"].contains(w) { q.maxSize = 100 << 10; chips.append("< 100 KB"); i += 1; continue }
            if let (cmp, bytes) = sizeToken(w, next: next, nextNext: i + 2 < low.count ? low[i + 2] : "") {
                if cmp.consumed > 0 { i += cmp.consumed - 1 }
                if cmp.greater { q.minSize = bytes; chips.append("> " + fmtSize(bytes)) } else { q.maxSize = bytes; chips.append("< " + fmtSize(bytes)) }
                i += 1; continue
            }

            // location
            if ["in", "from", "inside", "under", "on", "at", "within"].contains(w) {
                if next.isEmpty { i += 1; continue }
                let target = (next == "the" || next == "my" || next == "our") && i + 2 < low.count ? low[i + 2] : next
                let timeish = ["today", "yesterday", "last", "past", "this", "previous"].contains(target) || Int(target) != nil
                    || months.contains(target) || kindWords[target] != nil || stop.contains(target)
                if !timeish { pendingLocation = true }
                i += 1; continue
            }
            if stop.contains(w) { i += 1; continue }

            // kinds
            if let k = kindWords[w], !pendingLocation {
                q.kinds.formUnion(k)
                chips.append(k.count == 1 ? k.first!.label : w.capitalized)
                if kindAlsoName.contains(w) { q.terms.append(Term(word: w, alts: alts(for: w))) }
                else if !kindNoName.contains(w) {
                    // the word itself: lets a file named with it through even if it is another kind
                    var t = Term(word: w, alts: baseAlts(for: w)); t.optional = true; t.kindWord = true; q.terms.append(t)
                    // its usual spellings in names only help ranking ("deck" → "Slides.key")
                    let more = (kindNameAlts[w] ?? []).filter { $0 != w }
                    if !more.isEmpty { var t2 = Term(word: w, alts: more.flatMap { baseAlts(for: $0) }); t2.optional = true; t2.backup = true; q.terms.append(t2) }
                }
                i += 1; continue
            }
            // describing words: optional, with their usual spellings
            if let syn = softWords[w], !pendingLocation {
                var t = Term(word: w, alts: syn.enumerated().map { j, x in Alt(bytes: Array(x.utf8), weight: j == 0 ? 1 : 0.9, label: x) })
                t.optional = true
                q.terms.append(t); chips.append("prefers “\(w)”")
                i += 1; continue
            }

            // year / month (soft: name OR date)
            var term = Term(word: w, alts: alts(for: w))
            if let y = Int(w), y >= 1990 && y <= 2100 {
                let a = cal.date(from: DateComponents(year: y, month: 1, day: 1))!
                let b = cal.date(from: DateComponents(year: y + 1, month: 1, day: 1))!
                term.softTime = ts(a)...ts(b)
            } else if let m = months.firstIndex(of: w) ?? (w.count == 3 ? monthShort.firstIndex(of: w) : nil) {
                var y = cal.component(.year, from: now)
                if let ny = Int(next), ny >= 1990 && ny <= 2100 { y = ny; i += 1 }
                else if m + 1 > cal.component(.month, from: now) { y -= 1 }
                let a = cal.date(from: DateComponents(year: y, month: m + 1, day: 1))!
                let b = cal.date(byAdding: .month, value: 1, to: a)!
                term.softTime = ts(a)...ts(b)
                chips.append("\(months[m].capitalized) \(y)")
                term.alts = alts(for: months[m]) + alts(for: monthShort[m]).map { Alt(bytes: $0.bytes, weight: 0.8, label: $0.label) }
            }
            if pendingLocation {
                term.locationOnly = true
                chips.append("in “\(orig)”")
                pendingLocation = false
            }
            q.terms.append(term)
            i += 1
        }
        if q.after != nil && q.before == nil { q.before = ts(now) + 86400 }
        if !q.contentWords.isEmpty { chips.append("contains “\(q.contentWords.joined(separator: " "))”") }
        q.chips = chips
        return q
    }

    /// Hand-built: words that name the same kind of file. Matches count slightly less than the word itself.
    static let synonyms: [String: [String]] = [
        "resume": ["cv"], "cv": ["resume"],
        "contract": ["agreement", "nda", "msa", "sow"], "agreement": ["contract", "nda", "msa"],
        "nda": ["confidentiality", "nondisclosure", "non-disclosure"],
        "invoice": ["bill", "receipt"], "receipt": ["invoice", "rcpt"], "bill": ["invoice", "statement"],
        "tax": ["taxes", "w2", "w-2", "1099", "1040", "irs"], "taxes": ["tax", "w2", "w-2", "1099", "1040", "irs"],
        "w2": ["w-2"], "paystub": ["payslip", "pay stub", "earnings statement"], "payslip": ["paystub", "pay stub"],
        "notes": ["minutes", "memo", "notebook"], "minutes": ["notes", "mom"], "memo": ["notes", "memorandum"],
        "meeting": ["call", "sync", "standup"], "transcript": ["notes", "minutes"],
        "budget": ["financials", "forecast", "p&l", "pnl"], "financials": ["budget", "financial", "p&l", "pnl", "model"],
        "forecast": ["projection", "projections", "model"], "projections": ["forecast", "model"],
        "proposal": ["quote", "offer", "sow", "rfp"], "quote": ["estimate", "proposal", "quotation"], "estimate": ["quote", "quotation"],
        "report": ["summary", "analysis", "findings"], "statement": ["stmt", "bank"], "bank": ["statement", "stmt"],
        "logo": ["brand", "logomark", "wordmark"], "brand": ["logo", "branding", "brandbook"], "branding": ["logo", "brand"],
        "plan": ["roadmap", "strategy"], "roadmap": ["plan", "timeline"], "strategy": ["plan"],
        "insurance": ["policy", "coverage"], "lease": ["rental", "tenancy"], "rent": ["lease", "rental"],
        "manual": ["guide", "instructions", "handbook"], "guide": ["manual", "handbook", "howto", "how-to"],
        "diagram": ["schematic", "drawing", "chart"], "schematic": ["diagram", "circuit", "sch"], "drawing": ["dwg", "sketch"],
        "certificate": ["cert", "certification"], "license": ["licence", "permit"], "licence": ["license"],
        "headshot": ["portrait", "profile"], "portrait": ["headshot"], "id": ["passport", "license"],
        "pitch": ["pitchdeck"], "onepager": ["one pager", "one-pager", "1pager"], "brochure": ["flyer", "leaflet"],
        "flyer": ["brochure", "poster"], "email": ["mail", "eml"], "photo": ["pic", "img"],
        "application": ["form"], "form": ["application"], "letter": ["cover letter", "ltr"],
        "presentation": ["deck", "slides"], "slides": ["deck", "presentation"], "deck": ["slides", "presentation"],
        "spreadsheet": ["sheet", "xlsx"], "agenda": ["schedule", "itinerary"], "itinerary": ["agenda", "booking", "trip"],
        "ticket": ["boarding", "booking", "confirmation"], "boarding": ["ticket", "boarding pass"],
    ]

    /// Word root by suffix rules ("presented" → "present", "invoicing" → "invoic", "payments" → "payment").
    /// Names are matched by substring, so a root also finds its longer forms ("present" → "Presentation.key").
    static func lemma(_ w: String) -> String? {
        guard w.count >= 6, w.allSatisfy({ $0.isLetter }) else { return nil }
        for suf in ["ations", "ation", "ments", "ment", "ings", "ing", "ers", "ied", "ed", "er", "ly"] where w.hasSuffix(suf) {
            var r = String(w.dropLast(suf.count))
            if suf == "ied" { r += "y" }
            // "planned" → "plan", "shipping" → "ship"
            if r.count >= 4, let l = r.last, r.dropLast().last == l, !"lsz".contains(l) { r = String(r.dropLast()) }
            return r.count >= 4 ? r : nil
        }
        return nil
    }

    static func alts(for w: String) -> [Alt] {
        var out = baseAlts(for: w)
        if let l = lemma(w), !out.contains(where: { $0.bytes == Array(l.utf8) }) { out.append(Alt(bytes: Array(l.utf8), weight: 0.9, label: l)) }
        let root = out.count > 1 ? String(decoding: out[1].bytes, as: UTF8.self) : w
        for syn in synonyms[w] ?? synonyms[root] ?? [] where !out.contains(where: { $0.bytes == Array(syn.utf8) }) {
            out.append(Alt(bytes: Array(syn.utf8), weight: 0.78, label: syn))
        }
        return out
    }

    static func baseAlts(for w: String) -> [Alt] {
        var out = [Alt(bytes: Array(w.utf8), weight: 1, label: w)]
        // light stemming so "invoices" finds "Invoice.pdf"
        if w.count > 4 && w.hasSuffix("ies") { out.append(Alt(bytes: Array((w.dropLast(3) + "y").utf8), weight: 0.95, label: w)) }
        else if w.count > 3 && w.hasSuffix("es") && (w.hasSuffix("ses") || w.hasSuffix("xes") || w.hasSuffix("ches") || w.hasSuffix("shes")) {
            out.append(Alt(bytes: Array(w.dropLast(2).utf8), weight: 0.95, label: w))
        } else if w.count > 3 && w.hasSuffix("s") && !w.hasSuffix("ss") { out.append(Alt(bytes: Array(w.dropLast().utf8), weight: 0.95, label: w)) }
        return out
    }

    struct Cmp { let greater: Bool; let consumed: Int }

    /// ">10mb", "<1gb", "over 5mb", "bigger than 2 gb"
    static func sizeToken(_ w: String, next: String, nextNext: String) -> (Cmp, Int64)? {
        func bytes(_ s: String) -> Int64? {
            let units: [(String, Int64)] = [("tb", 1 << 40), ("gb", 1 << 30), ("mb", 1 << 20), ("kb", 1 << 10), ("t", 1 << 40), ("g", 1 << 30), ("m", 1 << 20), ("k", 1 << 10)]
            for (u, m) in units where s.hasSuffix(u) {
                if let v = Double(s.dropLast(u.count)) { return Int64(v * Double(m)) }
            }
            return nil
        }
        if w.hasPrefix(">") || w.hasPrefix("<") {
            let g = w.hasPrefix(">")
            var rest = String(w.drop(while: { $0 == ">" || $0 == "<" || $0 == "=" }))
            var used = 1
            if rest.isEmpty { rest = next; used = 2 }
            if let b = bytes(rest) { return (Cmp(greater: g, consumed: used), b) }
            if Double(rest) != nil, let b = bytes(rest + next) { return (Cmp(greater: g, consumed: used + 1), b) }
        }
        if ["over", "above", "bigger", "larger", "under", "below", "smaller"].contains(w) {
            let g = ["over", "above", "bigger", "larger"].contains(w)
            var tok = next, used = 2
            if tok == "than" { tok = nextNext; used = 3 }
            if let b = bytes(tok) { return (Cmp(greater: g, consumed: used), b) }
        }
        return nil
    }

    static func fmtSize(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
}
