// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import Foundation
import RoverCore
import AppKit
import SwiftUI

enum CLI {
    static func run(_ args: [String]) -> Never {
        let e = Engine.shared
        if args.first == "--help" || args.first == "-h" {
            print("""
            rover — find files on your Mac
              rover <words>           search (plain English works: "pdf invoice last month in downloads")
              rover -c <words>        also search inside files
              rover --index           rebuild the index
              rover --bench           time a set of queries
            The menu bar app opens with ⌥Space.
            """)
            exit(0)
        }
        if args.first == "--index" {
            let t = Date()
            e.buildSync()
            print("indexed \(e.fileCount) items in \(String(format: "%.1f", Date().timeIntervalSince(t)))s")
            exit(0)
        }
        e.start(watch: false, rescan: false)
        if !e.isReady {
            FileHandle.standardError.write("building index (first run)…\n".data(using: .utf8)!)
            e.buildSync()
        }
        if args.first == "--bench-file", args.count == 3 {
            // input: [{"q": "...", "target": "/abs/path"}]  output: [{"q","rank","ms","total"}]
            let data = try! Data(contentsOf: URL(fileURLWithPath: args[1]))
            let items = try! JSONSerialization.jsonObject(with: data) as! [[String: String]]
            _ = e.search("warmup")
            var out: [[String: Any]] = []
            for it in items {
                let q = it["q"]!, target = it["target"]!
                var best = Double.infinity
                // timing at the app's normal list size; rank from a deep list so "found anywhere" is comparable to Spotlight
                for _ in 0..<3 { best = min(best, e.search(q, limit: 60).millis) }
                let r = e.search(q, limit: 5000)
                let rank = (r.hits.firstIndex { $0.path == target }).map { $0 + 1 } ?? 0
                out.append(["q": q, "target": target, "rank": rank, "ms": best, "total": r.total])
            }
            try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: args[2]))
            exit(0)
        }
        if args.first == "--bench" {
            let qs = ["readme", "invoice", "pdf last month", "screenshot", "big videos", "package.json", "tax 2024",
                      "photos yesterday", "recieve", "in downloads pdf", "a", "notes", "png", "zoom app", "contract", "budget xlsx"]
            for q in qs {
                _ = e.search(q)
                var best = Double.infinity, r: SearchResult? = nil
                for _ in 0..<5 { let x = e.search(q); best = min(best, x.millis); r = x }
                print(String(format: "%7.2f ms  %6d matches  %@", best, r!.total, q))
            }
            print("\(e.fileCount) items indexed")
            exit(0)
        }
        if args.first == "ask" {
            let a = Assistant()
            let q = args.dropFirst().joined(separator: " ")
            let done = DispatchSemaphore(value: 0)
            let home = NSHomeDirectory()
            func ask(_ text: String) {
                a.ask(text, context: []) { ev in
                    switch ev {
                    case .text(let t): print(t, terminator: ""); fflush(stdout)
                    case .status(let s): print("\n  · \(s)")
                    case .files(let hs, let note):
                        print("\n  ▸ files\(note.isEmpty ? "" : " (\(note))"):")
                        for h in hs { print("      " + (h.path.hasPrefix(home) ? "~" + h.path.dropFirst(home.count) : h.path)) }
                    case .proposal(let p):
                        print("\n  ▸ PROPOSAL: \(p.summary)")
                        if let r = p.rule { print("      " + r.summary) }
                        for x in p.actions { print("      " + x.summary) }
                        for x in p.problems { print("      ⚠︎ " + x) }
                        let auto = ProcessInfo.processInfo.environment["ROVER_AUTO"]
                        if auto == "no" { print("  (auto-declined)"); a.respond(approved: false); return }
                        print("  approve? [y/N] ", terminator: ""); fflush(stdout)
                        DispatchQueue.global().async {
                            let line = readLine() ?? ""
                            DispatchQueue.main.async { a.respond(approved: line.lowercased().hasPrefix("y")) }
                        }
                    case .done(let err):
                        if let e = err { print("\nerror: \(e)") }
                        print("")
                        done.signal()
                    }
                }
            }
            ask(q)
            DispatchQueue.global().async { done.wait(); exit(0) }
            RunLoop.main.run()
        }
        if args.first == "ls", args.count >= 2 {
            let p = Paths.expand(args.dropFirst().joined(separator: " "))
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: p) else { print("can't list \(p)"); exit(1) }
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            for n in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) where !n.hasPrefix(".") {
                let a = try? fm.attributesOfItem(atPath: p + "/" + n)
                let dir = (a?[.type] as? FileAttributeType) == .typeDirectory
                let d = (a?[.modificationDate] as? Date).map { df.string(from: $0) } ?? ""
                let sz = dir ? "" : ByteCountFormatter.string(fromByteCount: (a?[.size] as? NSNumber)?.int64Value ?? 0, countStyle: .file)
                print("\(d)  \(sz.padding(toLength: 9, withPad: " ", startingAt: 0))  \(n)\(dir ? "/" : "")")
            }
            exit(0)
        }
        if args.first == "info", args.count >= 2 {
            let (out, _) = Assistant.fileInfo(Paths.expand(args.dropFirst().joined(separator: " ")))
            print(out); exit(0)
        }
        if args.first == "mv", args.count >= 3 {
            let dest = Paths.expand(args.last!)
            let acts = args.dropFirst().dropLast().map { FileAction(op: .move, path: Paths.expand($0), to: dest) }
            for o in ActionRunner.shared.run(acts, title: "Move to \((dest as NSString).lastPathComponent)") {
                print(o.ok ? "moved  \(Paths.pretty(o.resultPath ?? ""))" : "failed \(o.action.path): \(o.message)")
            }
            exit(0)
        }
        if args.first == "rule", args.count >= 5, args[1] == "add" {
            // rover rule add <folder> <match> <move|copy|trash|tag> [to-folder|tag]
            guard let op = FileAction.Op(rawValue: args[4]) else { print("op must be move, copy, trash or tag"); exit(1) }
            var r = Rule(name: "\(args[4]) \(args[3])", folder: args[2], match: args[3], op: op)
            if args.count >= 6 { if op == .tag { r.tag = args[5] } else { r.to = args[5] } }
            if let e = RuleEngine.shared.validate(r) { print("invalid: \(e)"); exit(1) }
            RuleEngine.shared.add(r)
            print("added: \(r.summary)\n(runs while the Rover app is open)")
            exit(0)
        }
        if args.first == "rule", args.count == 3, args[1] == "rm", let id = UUID(uuidString: args[2]) {
            RuleEngine.shared.remove(id); print("removed"); exit(0)
        }
        if args.first == "undo" { print(ActionRunner.shared.undoLast()); exit(0) }
        if args.first == "rules" {
            for r in RuleEngine.shared.rules { print("\(r.enabled ? "●" : "○") \(r.name) — \(r.summary)  [\(r.runs) handled]  \(r.id)") }
            exit(0)
        }
        if args.first == "--path", args.count == 2 {
            // what the panel shows when this is typed (Go to Folder behaviour)
            guard let r = SearchModel.pathHits(args[1]) else { print("not a path query"); exit(0) }
            print("folder: \(Paths.pretty(r.folder)) · \(r.hits.count) items")
            for h in r.hits.prefix(6) { print("  " + (h.isDir ? "📁 " : "   ") + Paths.pretty(h.path)) }
            exit(0)
        }
        if args.first == "--render-junk", args.count == 2 {
            // draws the Free Up Space window into a PNG without opening anything on screen
            let m = JunkModel()
            let r = JunkFinder.scan()
            m.report = r; m.volumes = [JunkFinder.Volume(name: "Backup Drive", path: "/Volumes/Backup", free: 900 << 30)]
            m.selected = Set(r.items.filter { $0.category == .installers || $0.category == .duplicates }.map { $0.path })
            m.open = [.installers, .duplicates]
            let v = JunkView(m: m).frame(width: 760, height: 640).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: v); host.frame = NSRect(x: 0, y: 0, width: 760, height: 640); host.appearance = NSAppearance(named: .darkAqua)
            host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[1]))
            print("rendered \(args[1])"); exit(0)
        }
        if args.first == "junk" {
            // what could go: big, old, unused. Nothing is moved from the command line.
            let r = JunkFinder.scan()
            let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
            // test hook: only inside a demo home, never on real files
            if let i = args.firstIndex(of: "--apply"), i + 1 < args.count {
                guard ProcessInfo.processInfo.environment["ROVER_DEMO_HOME"] != nil else { print("--apply only works with ROVER_DEMO_HOME"); exit(1) }
                let how = args[i + 1]
                let res = how == "trash" ? JunkFinder.trash(r.items)
                    : JunkFinder.backup(r.items, to: JunkFinder.Volume(name: "Test Drive", path: String(how.dropFirst(7)), free: 1 << 42))
                print("moved \(res.moved), \(fmt(res.bytes)), failed \(res.failed.count) \(res.failed.map { $0.1 })")
                exit(0)
            }
            if args.contains("--json") {
                let o: [[String: Any]] = r.items.map { ["path": $0.path, "size": $0.size, "category": $0.category.rawValue, "lastUsed": $0.lastUsed, "kept": $0.keptCopy ?? ""] }
                print(String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!); exit(0)
            }
            let df = DateFormatter(); df.dateFormat = "MMM yyyy"
            print("You could free up \(fmt(r.total)) (\(r.items.count) items, scanned in \(Int(r.millis)) ms)\n")
            for c in JunkCategory.allCases {
                let its = r.items(in: c); if its.isEmpty { continue }
                print("\(c.title) — \(fmt(r.total(in: c)))")
                for it in its.prefix(args.contains("-a") ? 1000 : 6) {
                    print(String(format: "  %9@  last used %@  %@", fmt(it.size), df.string(from: Date(timeIntervalSince1970: TimeInterval(it.lastUsed))), Paths.pretty(it.path)))
                }
                if its.count > 6 && !args.contains("-a") { print("  … and \(its.count - 6) more (rover junk -a)") }
                print("")
            }
            print("Open Rover's menu → Free Up Space… to move these to the Trash or a backup drive.")
            exit(0)
        }
        if args.first == "--json" {
            // machine-readable results (used to make the demo footage from real engine output)
            let r = e.search(args.dropFirst().joined(separator: " "), limit: 12)
            let home0 = ProcessInfo.processInfo.environment["ROVER_DEMO_HOME"] ?? NSHomeDirectory()
            let homes = [home0, home0.hasPrefix("/private/") ? String(home0.dropFirst(8)) : "/private" + home0]
            func pretty(_ p: String) -> String { for h in homes where p.hasPrefix(h) { return "~" + p.dropFirst(h.count) }; return p }
            let hits: [[String: Any]] = r.hits.map { h in
                ["name": h.name, "path": pretty(h.path),
                 "mtime": h.mtime, "size": h.size, "kind": h.kind.label, "dir": h.isDir]
            }
            let o: [String: Any] = ["query": args.dropFirst().joined(separator: " "), "chips": r.query.chips, "total": r.total,
                                    "ms": r.millis, "hits": hits]
            print(String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)!)
            exit(0)
        }
        var content = false
        var words = args
        if words.first == "-c" { content = true; words.removeFirst() }
        let text = words.joined(separator: " ")
        let r = e.search(text, limit: 25)
        let home = NSHomeDirectory()
        if !r.query.chips.isEmpty { print("understood: " + r.query.chips.joined(separator: " · ")) }
        if !r.expanded.isEmpty { print("also tried: " + r.expanded.joined(separator: ", ")) }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        for h in r.hits {
            let p = h.path.hasPrefix(home) ? "~" + h.path.dropFirst(home.count) : h.path
            print(String(format: "%6.0f  %@  %@", h.score, df.string(from: Date(timeIntervalSince1970: TimeInterval(h.mtime))), p))
        }
        print(String(format: "%d matches in %.1f ms", r.total, r.millis))
        if content || r.hits.isEmpty {
            let sem = DispatchSemaphore(value: 0)
            e.contentSearch(r.query, excluding: Set(r.hits.map { $0.path })) { hits in
                if !hits.isEmpty { print("— inside files —") }
                for h in hits.prefix(15) { print("        " + (h.path.hasPrefix(home) ? "~" + h.path.dropFirst(home.count) : h.path)) }
                sem.signal()
            }
            sem.wait()
        }
        exit(0)
    }
}
