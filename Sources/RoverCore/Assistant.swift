// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import Security

/// Claude-powered assistant: finds, reads and organizes files using local tools.
/// Anything that changes files is proposed first and runs only after the user approves it in the app.
public final class Assistant {
    public enum Event {
        case text(String)                       // streamed answer text (delta)
        case status(String)                     // "Searching “invoice”…"
        case files([Hit], String)               // files to show, with a note
        case proposal(Proposal)                 // waits for approve/decline
        case done(String?)                      // finished (optional error)
    }

    public struct Proposal: Identifiable {
        public let id = UUID()
        public let summary: String
        public let actions: [FileAction]
        public let rule: Rule?
        public let problems: [String]
    }

    public static let model = "claude-opus-5-5"
    let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private var messages: [[String: Any]] = []
    private var task: Task<Void, Never>?
    private var approval: CheckedContinuation<Bool, Never>?
    public var effort = "medium"
    private let cc = ClaudeCodeAgent()
    private var pendingPlan: (ClaudeCodeAgent.Plan, (Event) -> Void)?

    public enum Backend { case claudeCode(String), api, none }
    /// Prefer the person's Claude Code login (no key needed); an API key is optional.
    public static var backend: Backend {
        if let pref = configValue("assistant") as? String, pref == "api", apiKey != nil { return .api }
        if let cli = ClaudeCodeAgent.findCLI() { return .claudeCode(cli) }
        if apiKey != nil { return .api }
        return .none
    }
    public static var backendName: String {
        switch backend { case .claudeCode: return "Claude Code login"; case .api: return "Claude API key"; case .none: return "not set up" }
    }

    public init() {
        if let e = Self.configValue("assistantEffort") as? String { effort = e }
    }

    // MARK: API key

    static func configValue(_ k: String) -> Any? {
        let p = NSHomeDirectory() + "/.config/rover/config.json"
        guard let d = FileManager.default.contents(atPath: p), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j[k]
    }

    public static var apiKey: String? {
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
        if let k = Keychain.get(), !k.isEmpty { return k }
        if let k = configValue("anthropicApiKey") as? String, !k.isEmpty { return k }
        return nil
    }

    public static func setAPIKey(_ k: String) { Keychain.set(k.trimmingCharacters(in: .whitespacesAndNewlines)) }

    public var hasConversation: Bool { !messages.isEmpty || cc.sessionID != nil }
    public func reset() { cancel(); messages = []; cc.reset() }

    public func cancel() {
        task?.cancel(); task = nil
        cc.cancel()
        approval?.resume(returning: false); approval = nil
        pendingPlan = nil
    }

    public func respond(approved: Bool) {
        if let (plan, emit) = pendingPlan {
            pendingPlan = nil
            guard approved else { emit(.text("\n\nOK, nothing was changed.")); emit(.done(nil)); return }
            var lines: [String] = []
            if !plan.actions.isEmpty {
                let res = ActionRunner.shared.run(plan.actions, title: plan.summary)
                for d in res where d.ok { if let rp = d.resultPath { Engine.shared.touched(rp) }; Engine.shared.touched(d.action.path) }
                let ok = res.filter { $0.ok }.count
                lines.append("Done: \(ok) of \(res.count) change\(res.count == 1 ? "" : "s").")
                for f in res where !f.ok { lines.append("Couldn't: \(f.action.summary) (\(f.message))") }
            }
            if let r = plan.rule {
                RuleEngine.shared.add(r)
                lines.append("Automation “\(r.name)” is on.")
            }
            // tell Claude Code what happened so follow-ups make sense
            if cc.sessionID != nil { pendingNote = lines.joined(separator: " ") }
            emit(.text("\n\n" + lines.joined(separator: "\n")))
            emit(.done(nil))
            return
        }
        approval?.resume(returning: approved); approval = nil
    }
    private var pendingNote: String?

    // MARK: conversation

    public func ask(_ text: String, context: [Hit], onEvent: @escaping (Event) -> Void) {
        cancel()
        let emit: (Event) -> Void = { e in DispatchQueue.main.async { onEvent(e) } }
        let key: String
        switch Self.backend {
        case .none:
            emit(.done("The assistant needs Claude Code (signed in) or a Claude API key. Search works without either."))
            return
        case .claudeCode(let cli):
            askClaudeCode(text, context: context, cli: cli, emit: emit)
            return
        case .api:
            key = Self.apiKey!
        }
        var content = text
        if messages.isEmpty {
            let df = DateFormatter(); df.dateFormat = "EEEE yyyy-MM-dd HH:mm"
            var ctx = "Now: \(df.string(from: Date())). Home: \(Paths.home)."
            if !context.isEmpty {
                ctx += "\nFiles currently shown in the search list for “\(text)” (top \(min(context.count, 12))):\n"
                ctx += context.prefix(12).map { "- \($0.path)" }.joined(separator: "\n")
            }
            content = "<context>\n\(ctx)\n</context>\n\n\(text)"
        }
        messages.append(["role": "user", "content": content])
        task = Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.loop(key: key, emit: emit)
                emit(.done(nil))
            } catch is CancellationError {
                emit(.done(nil))
            } catch {
                emit(.done(error.localizedDescription))
            }
        }
    }

    private func askClaudeCode(_ text: String, context: [Hit], cli: String, emit: @escaping (Event) -> Void) {
        var prompt = text
        if cc.sessionID == nil {
            let df = DateFormatter(); df.dateFormat = "EEEE yyyy-MM-dd HH:mm"
            var ctx = "Now: \(df.string(from: Date())). Home: \(Paths.home)."
            if !context.isEmpty {
                ctx += "\nFiles currently shown in the search list:\n" + context.prefix(12).map { "- \($0.path)" }.joined(separator: "\n")
            }
            prompt = "<context>\n\(ctx)\n</context>\n\n\(text)"
        } else if let n = pendingNote {
            prompt = "(Result of your last proposal: \(n))\n\n\(text)"
            pendingNote = nil
        }
        cc.run(prompt: prompt, cli: cli,
               onText: { emit(.text($0)) },
               onStatus: { emit(.status($0)) },
               finish: { [weak self] _, plan, err in
                   guard let self = self else { return }
                   if let e = err { emit(.done(e)); return }
                   if !plan.show.isEmpty { emit(.files(Self.hits(for: plan.show), "")) }
                   if !plan.actions.isEmpty || plan.rule != nil {
                       var problems = plan.actions.compactMap { a in ActionRunner.shared.validate(a).map { "\(a.summary): \($0)" } }
                       if let r = plan.rule, let e = RuleEngine.shared.validate(r) { problems.append(e) }
                       let prop = Proposal(summary: plan.rule.map { "New automation: \($0.name)" } ?? plan.summary,
                                           actions: plan.actions, rule: plan.rule, problems: problems)
                       DispatchQueue.main.async { self.pendingPlan = (plan, emit); emit(.proposal(prop)) }
                       return
                   }
                   emit(.done(nil))
               })
    }

    public static func hits(for paths: [String]) -> [Hit] {
        paths.compactMap { p in
            var st = stat()
            guard lstat(p, &st) == 0 else { return nil }
            let n = (p as NSString).lastPathComponent, low = n.folded
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR && !Kinds.packages.contains(Kinds.ext(ofLow: low))
            let k: Kind = isDir ? .folder : low.withCString { Kinds.kind(ofLowName: UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), len: low.utf8.count) }
            return Hit(path: p, name: n, mtime: Int64(st.st_mtimespec.tv_sec), size: isDir ? 0 : Int64(st.st_size), isDir: isDir, kind: k, score: 0, source: .name, why: "")
        }
    }

    private func loop(key: String, emit: @escaping (Event) -> Void) async throws {
        for _ in 0..<20 {
            try Task.checkCancellation()
            let (blocks, stop, bad) = try await stream(key: key, emit: emit)
            messages.append(["role": "assistant", "content": blocks])
            if stop == "refusal" { emit(.text("\n\n_(Claude declined this request.)_")); return }
            if stop == "max_tokens" { emit(.text("\n\n_(Answer was cut off.)_")); return }
            let uses = blocks.filter { ($0["type"] as? String) == "tool_use" }
            if stop != "tool_use" || uses.isEmpty { return }
            var results: [[String: Any]] = []
            for u in uses {
                let id = u["id"] as? String ?? ""
                let name = u["name"] as? String ?? ""
                guard !bad.contains(id), let input = u["input"] as? [String: Any] else {
                    results.append(["type": "tool_result", "tool_use_id": id, "is_error": true, "content": "INVALID_JSON: tool input could not be parsed; send it again"])
                    continue
                }
                let (out, isErr) = await runTool(name, input, emit: emit)
                var r: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": out]
                if isErr { r["is_error"] = true }
                results.append(r)
            }
            messages.append(["role": "user", "content": results])
        }
        emit(.text("\n\n_(Stopped after many steps.)_"))
    }

    // MARK: streaming request

    private func stream(key: String, emit: @escaping (Event) -> Void) async throws -> ([[String: Any]], String, Set<String>) {
        var body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "stream": true,
            "system": [["type": "text", "text": Self.systemPrompt, "cache_control": ["type": "ephemeral"]]],
            "tools": Self.tools,
            "messages": messages,
            "output_config": ["effort": effort],
            "fallbacks": "default",
        ]
        body["cache_control"] = ["type": "ephemeral"]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            var data = Data()
            for try await b in bytes { data.append(b) }
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? String(decoding: data, as: UTF8.self)
            switch h.statusCode {
            case 401: throw AssistantError("Claude API key was rejected (401). Set a valid key from the menu bar icon.")
            case 429: throw AssistantError("Rate limited by the Claude API. Try again in a moment.")
            case 529, 500...599: throw AssistantError("Claude is temporarily unavailable (\(h.statusCode)). Try again.")
            default: throw AssistantError("Claude API error \(h.statusCode): \(msg)")
            }
        }
        var blocks: [Int: [String: Any]] = [:]
        var json: [Int: String] = [:]
        var stop = "end_turn"
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let d = payload.data(using: .utf8), let ev = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let type = ev["type"] as? String else { continue }
            let idx = ev["index"] as? Int ?? 0
            switch type {
            case "content_block_start":
                if let b = ev["content_block"] as? [String: Any] {
                    blocks[idx] = b
                    if b["type"] as? String == "tool_use" {
                        json[idx] = ""
                        emit(.status(Self.statusLine(b["name"] as? String ?? "", [:])))
                    }
                }
            case "content_block_delta":
                guard let delta = ev["delta"] as? [String: Any], var b = blocks[idx] else { continue }
                switch delta["type"] as? String {
                case "text_delta":
                    let t = delta["text"] as? String ?? ""
                    b["text"] = (b["text"] as? String ?? "") + t
                    emit(.text(t))
                case "input_json_delta": json[idx, default: ""] += delta["partial_json"] as? String ?? ""
                case "thinking_delta": b["thinking"] = (b["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                case "signature_delta": b["signature"] = delta["signature"] as? String ?? ""
                case "citations_delta":
                    if let c = delta["citation"] { b["citations"] = (b["citations"] as? [Any] ?? []) + [c] }
                default: break
                }
                blocks[idx] = b
            case "content_block_stop":
                if var b = blocks[idx], b["type"] as? String == "tool_use" {
                    let raw = json[idx] ?? ""
                    if raw.isEmpty { b["input"] = [String: Any]() }
                    else if let d = raw.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { b["input"] = obj }
                    else { b["input"] = NSNull() }
                    blocks[idx] = b
                    if let inp = b["input"] as? [String: Any] { emit(.status(Self.statusLine(b["name"] as? String ?? "", inp))) }
                }
            case "message_delta":
                if let d = ev["delta"] as? [String: Any], let s = d["stop_reason"] as? String { stop = s }
            case "error":
                let m = (ev["error"] as? [String: Any])?["message"] as? String ?? "stream error"
                throw AssistantError("Claude API: \(m)")
            default: break
            }
        }
        var bad = Set<String>()
        let ordered = blocks.keys.sorted().compactMap { blocks[$0] }.map { b0 -> [String: Any] in
            var b = b0
            if b["type"] as? String == "tool_use", !(b["input"] is [String: Any]) {
                b["input"] = [String: Any]()
                bad.insert(b["id"] as? String ?? "")
            }
            return b
        }
        return (ordered, stop, bad)
    }

    static func statusLine(_ tool: String, _ input: [String: Any]) -> String {
        let q = (input["query"] as? String) ?? (input["words"] as? [String])?.joined(separator: " ") ?? ""
        let p = (input["path"] as? String).map { ($0 as NSString).lastPathComponent } ?? ""
        switch tool {
        case "search_files": return q.isEmpty ? "Searching…" : "Searching “\(q)”…"
        case "search_contents": return q.isEmpty ? "Looking inside files…" : "Looking inside files for “\(q)”…"
        case "list_folder": return p.isEmpty ? "Listing folder…" : "Listing \(p)…"
        case "read_file": return p.isEmpty ? "Reading…" : "Reading \(p)…"
        case "file_info": return p.isEmpty ? "Checking file…" : "Checking \(p)…"
        case "show_files": return "Preparing results…"
        case "propose_changes": return "Planning changes…"
        case "create_rule": return "Setting up automation…"
        case "list_rules", "delete_rule": return "Checking automations…"
        case "open_file": return p.isEmpty ? "Opening…" : "Opening \(p)…"
        default: return "Working…"
        }
    }

    // MARK: tools

    static let systemPrompt = """
    You are Rover, a file assistant built into a Mac search app. You help one person find their files, understand what is in them, and keep them organized. You run on their Mac with read access to their indexed files (home folder, iCloud Drive, Applications).

    How to work:
    - Find files with search_files first. It is instant and understands plain English: kinds ("pdf", "photos", "spreadsheet", "deck"), dates ("last week", "march", "2024", "yesterday"), sizes ("big", ">500mb"), places ("in downloads"), extensions (".py"), and sort words ("newest", "biggest"). Try two or three phrasings or synonyms before concluding something doesn't exist. Use search_contents when the words are likely inside the file rather than in its name.
    - Open files with read_file only when you need their contents to answer or to decide where they belong. Images come back as pictures you can look at.
    - When your answer points at files, call show_files with the best matches (most likely first) so they appear as clickable rows. Then reply in one to three short sentences. Don't paste long path lists into the text.
    - Changes to files (move, rename, copy, Trash, new folder, Finder tag) go through propose_changes. The person reviews the plan and clicks to approve, and the tool result tells you what happened. Never claim a change happened before that result arrives. Prefer Trash over anything permanent; there is no permanent delete. Keep plans focused: only the files the person asked about. When organizing, propose a small number of clear folders rather than many.
    - Ongoing automations ("from now on…", "whenever…", "keep my Downloads clean") go through create_rule, which also needs approval. Rules act on new files arriving in one folder, or on files older than N days for cleanup rules. To also handle files already there, propose those changes separately with propose_changes.
    - Use open_file only when the person asks to open something.
    - Paths can be written with ~ for the home folder.
    - Be brief and concrete. If you could not find something, say what you tried and suggest one next step.
    """

    static let tools: [[String: Any]] = {
        func obj(_ props: [String: Any], _ req: [String]) -> [String: Any] {
            ["type": "object", "properties": props, "required": req, "additionalProperties": false]
        }
        let str: [String: Any] = ["type": "string"]
        let action: [String: Any] = obj([
            "op": ["type": "string", "enum": ["move", "rename", "copy", "trash", "mkdir", "tag"]],
            "path": ["type": "string", "description": "File or folder to act on (for mkdir: the folder to create)"],
            "to": ["type": "string", "description": "Destination folder for move/copy"],
            "name": ["type": "string", "description": "New file name for rename (keep the extension), optional new name for move/copy"],
            "tag": ["type": "string", "description": "Finder tag for tag"],
        ], ["op", "path"])
        var t: [[String: Any]] = [
            ["name": "search_files",
             "description": "Instant search over every indexed file and folder name. Accepts plain English with kinds, dates, sizes, places and extensions. Returns paths with kind, modified date and size, best first.",
             "input_schema": obj(["query": ["type": "string", "description": "e.g. \"invoice pdf last month\", \"screenshots in desktop\", \"tax 2024\""],
                                  "limit": ["type": "integer", "description": "max results, default 25, up to 100"]], ["query"])],
            ["name": "search_contents",
             "description": "Full-text search inside documents using the Mac's content index (PDFs, docs, text, mail exports). Slower than search_files.",
             "input_schema": obj(["words": ["type": "array", "items": str, "description": "words or short phrases that appear in the file"],
                                  "kinds_or_filters": ["type": "string", "description": "optional Rover filters, e.g. \"pdf last year in documents\""]], ["words"])],
            ["name": "list_folder",
             "description": "List a folder's contents (names, kinds, dates, sizes).",
             "input_schema": obj(["path": str, "sort": ["type": "string", "enum": ["name", "newest", "largest"]],
                                  "limit": ["type": "integer", "description": "default 100, up to 500"]], ["path"])],
            ["name": "read_file",
             "description": "Read a file's text (text, code, PDF, Word, RTF, HTML and more) or look at an image.",
             "input_schema": obj(["path": str, "max_chars": ["type": "integer", "description": "default 8000, up to 40000"]], ["path"])],
            ["name": "file_info",
             "description": "Detailed metadata: where it was downloaded from, created/modified/last opened dates, size, page count, dimensions, duration, tags.",
             "input_schema": obj(["path": str], ["path"])],
            ["name": "show_files",
             "description": "Show files to the person as clickable results in the app, best first.",
             "input_schema": obj(["paths": ["type": "array", "items": str], "note": ["type": "string", "description": "optional one-line caption"]], ["paths"])],
            ["name": "propose_changes",
             "description": "Propose file changes. The person sees the plan and approves or declines; the result reports what happened per item.",
             "input_schema": obj(["summary": ["type": "string", "description": "one short sentence describing the plan"],
                                  "actions": ["type": "array", "items": action]], ["summary", "actions"])],
            ["name": "create_rule",
             "description": "Propose an automation that runs by itself: when a new file matching `match` appears in `folder` (or, with older_than_days, when a matching file has not been touched for that many days), apply the action. Needs approval.",
             "input_schema": obj(["name": ["type": "string", "description": "short name, e.g. \"File invoices\""],
                                  "folder": ["type": "string", "description": "watched folder, e.g. ~/Downloads"],
                                  "match": ["type": "string", "description": "Rover query the file name must match, e.g. \"invoice pdf\", \"screenshot\", \".dmg\"; empty matches everything"],
                                  "op": ["type": "string", "enum": ["move", "copy", "rename", "trash", "tag"]],
                                  "to": ["type": "string", "description": "destination folder for move/copy"],
                                  "rename_template": ["type": "string", "description": "for rename: uses {date} {name} {ext}, e.g. \"{date} {name}\""],
                                  "tag": ["type": "string"],
                                  "older_than_days": ["type": "integer", "description": "cleanup rules only"]], ["name", "folder", "match", "op"])],
            ["name": "list_rules", "description": "List existing automations.", "input_schema": obj([:], [])],
            ["name": "delete_rule", "description": "Remove an automation by id.", "input_schema": obj(["id": str], ["id"])],
            ["name": "open_file", "description": "Open a file in its default app, or reveal it in Finder.",
             "input_schema": obj(["path": str, "reveal": ["type": "boolean"]], ["path"])],
        ]
        for i in t.indices { t[i]["eager_input_streaming"] = true }
        return t
    }()

    private func runTool(_ name: String, _ input: [String: Any], emit: @escaping (Event) -> Void) async -> (Any, Bool) {
        let e = Engine.shared
        func j(_ o: Any) -> String {
            (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        }
        func row(_ h: Hit) -> [String: Any] {
            var r: [String: Any] = ["path": Paths.pretty(h.path), "kind": h.kind.label, "modified": Self.iso(h.mtime)]
            if !h.isDir && h.size > 0 { r["size"] = ByteCountFormatter.string(fromByteCount: h.size, countStyle: .file) }
            if h.source == .content { r["match"] = "contents" }
            return r
        }
        switch name {
        case "search_files":
            guard let q = input["query"] as? String else { return ("query is required", true) }
            let lim = min(100, max(1, input["limit"] as? Int ?? 25))
            let r = e.search(q, limit: lim)
            var out: [String: Any] = ["total_matches": r.total, "results": r.hits.map(row)]
            if !r.query.chips.isEmpty { out["understood_as"] = r.query.chips.joined(separator: ", ") }
            if !r.expanded.isEmpty { out["also_tried"] = r.expanded }
            return (j(out), false)

        case "search_contents":
            guard let words = input["words"] as? [String], !words.isEmpty else { return ("words is required", true) }
            var q = QueryParser.parse(input["kinds_or_filters"] as? String ?? "")
            q.contentWords = words
            let hits: [Hit] = await withCheckedContinuation { c in e.contentSearch(q, excluding: [], limit: 30) { c.resume(returning: $0) } }
            return (j(["results": hits.map(row)]), false)

        case "list_folder":
            guard let p0 = input["path"] as? String else { return ("path is required", true) }
            let p = Paths.expand(p0)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: p) else { return ("Can't list \(Paths.pretty(p))", true) }
            var rows: [(String, Bool, Date, Int64)] = []
            for n in names where !n.hasPrefix(".") {
                let a = try? FileManager.default.attributesOfItem(atPath: p + "/" + n)
                let dir = (a?[.type] as? FileAttributeType) == .typeDirectory
                rows.append((n, dir, a?[.modificationDate] as? Date ?? .distantPast, (a?[.size] as? NSNumber)?.int64Value ?? 0))
            }
            switch input["sort"] as? String {
            case "newest": rows.sort { $0.2 > $1.2 }
            case "largest": rows.sort { $0.3 > $1.3 }
            default: rows.sort { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
            }
            let lim = min(500, max(1, input["limit"] as? Int ?? 100))
            let out: [[String: Any]] = rows.prefix(lim).map { r in
                var d: [String: Any] = ["name": r.0 + (r.1 ? "/" : ""), "modified": Self.iso(Int64(r.2.timeIntervalSince1970))]
                if !r.1 { d["size"] = ByteCountFormatter.string(fromByteCount: r.3, countStyle: .file) }
                return d
            }
            return (j(["folder": Paths.pretty(p), "count": rows.count, "items": out]), false)

        case "read_file":
            guard let p0 = input["path"] as? String else { return ("path is required", true) }
            return Self.read(Paths.expand(p0), maxChars: min(40000, max(500, input["max_chars"] as? Int ?? 8000)))

        case "file_info":
            guard let p0 = input["path"] as? String else { return ("path is required", true) }
            return Self.info(Paths.expand(p0))

        case "show_files":
            let paths = (input["paths"] as? [String] ?? []).map(Paths.expand)
            var hits: [Hit] = []
            for p in paths {
                var st = stat()
                guard lstat(p, &st) == 0 else { continue }
                let isDir = (st.st_mode & S_IFMT) == S_IFDIR && !Kinds.packages.contains(Kinds.ext(ofLow: p.folded))
                let n = (p as NSString).lastPathComponent, low = n.folded
                let k: Kind = isDir ? .folder : low.withCString { Kinds.kind(ofLowName: UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), len: low.utf8.count) }
                hits.append(Hit(path: p, name: n, mtime: Int64(st.st_mtimespec.tv_sec), size: Int64(st.st_size), isDir: isDir, kind: k, score: 0, source: .name, why: ""))
            }
            emit(.files(hits, input["note"] as? String ?? ""))
            let missing = paths.count - hits.count
            return (missing > 0 ? "Shown \(hits.count); \(missing) path(s) did not exist" : "Shown \(hits.count) file(s)", false)

        case "propose_changes":
            guard let raw = input["actions"] as? [[String: Any]], !raw.isEmpty else { return ("actions is required", true) }
            var acts: [FileAction] = []
            for r in raw {
                guard let op = (r["op"] as? String).flatMap(FileAction.Op.init(rawValue:)), let p = r["path"] as? String else { continue }
                acts.append(FileAction(op: op, path: Paths.expand(p), to: (r["to"] as? String).map(Paths.expand), name: r["name"] as? String, tag: r["tag"] as? String))
            }
            // a folder about to be created makes moves into it valid
            let problems = acts.compactMap { a -> String? in
                guard let e = ActionRunner.shared.validate(a) else { return nil }
                return "\(a.summary): \(e)"
            }
            let prop = Proposal(summary: input["summary"] as? String ?? "Proposed changes", actions: acts, rule: nil, problems: problems)
            let ok = await waitForApproval(prop, emit: emit)
            if !ok { return ("The person declined these changes. Nothing was changed.", false) }
            let res = ActionRunner.shared.run(acts, title: prop.summary)
            let done = res.filter { $0.ok }
            for d in done { if let rp = d.resultPath { e.touched(rp) }; e.touched(d.action.path) }
            let lines = res.map { "\($0.ok ? "OK" : "FAILED"): \($0.action.summary)\($0.ok ? "" : " — " + $0.message)" }
            return ("Approved. \(done.count) of \(res.count) done (undo is available in the app).\n" + lines.joined(separator: "\n"), false)

        case "create_rule":
            guard let n = input["name"] as? String, let f = input["folder"] as? String,
                  let op = (input["op"] as? String).flatMap(FileAction.Op.init(rawValue:)) else { return ("name, folder and op are required", true) }
            var r = Rule(name: n, folder: Paths.expand(f), match: input["match"] as? String ?? "", op: op)
            r.to = (input["to"] as? String).map(Paths.expand)
            r.renameTemplate = input["rename_template"] as? String
            r.tag = input["tag"] as? String
            r.olderThanDays = input["older_than_days"] as? Int
            var problems: [String] = []
            if let err = RuleEngine.shared.validate(r) { problems.append(err) }
            let prop = Proposal(summary: "New automation: \(r.name)", actions: [], rule: r, problems: problems)
            if !problems.isEmpty { return ("Rule is invalid: " + problems.joined(separator: "; "), true) }
            let ok = await waitForApproval(prop, emit: emit)
            if !ok { return ("The person declined this automation.", false) }
            RuleEngine.shared.add(r)
            return ("Automation created (id \(r.id.uuidString)): \(r.summary). It is active now.", false)

        case "list_rules":
            let rs = RuleEngine.shared.rules.map { ["id": $0.id.uuidString, "name": $0.name, "summary": $0.summary, "enabled": $0.enabled, "files_handled": $0.runs] as [String: Any] }
            return (j(["rules": rs]), false)

        case "delete_rule":
            guard let s = input["id"] as? String, let id = UUID(uuidString: s), RuleEngine.shared.rules.contains(where: { $0.id == id }) else { return ("No rule with that id", true) }
            RuleEngine.shared.remove(id)
            return ("Removed.", false)

        case "open_file":
            guard let p0 = input["path"] as? String else { return ("path is required", true) }
            let p = Paths.expand(p0)
            guard FileManager.default.fileExists(atPath: p) else { return ("Not found", true) }
            let reveal = input["reveal"] as? Bool ?? false
            let low = p.folded
            let risky = ["app", "command", "sh", "pkg", "dmg", "terminal", "workflow", "scpt", "tool"].contains(Kinds.ext(ofLow: low))
            if risky && !reveal {
                return ("For safety Rover only reveals apps, installers and scripts in Finder; ask the person to open it themselves.", true)
            }
            DispatchQueue.main.async { e.openHandler?(p, reveal) }
            return (reveal ? "Revealed in Finder" : "Opened", false)

        default:
            return ("Unknown tool \(name)", true)
        }
    }

    private func waitForApproval(_ p: Proposal, emit: @escaping (Event) -> Void) async -> Bool {
        await withCheckedContinuation { c in
            DispatchQueue.main.async {
                self.approval?.resume(returning: false)
                self.approval = c
                emit(.proposal(p))
            }
        }
    }

    static func iso(_ t: Int64) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }

    // MARK: reading

    static func read(_ p: String, maxChars: Int) -> (Any, Bool) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { return ("Not found: \(Paths.pretty(p))", true) }
        if isDir.boolValue && !Kinds.packages.contains(Kinds.ext(ofLow: p.folded)) { return ("That is a folder; use list_folder", true) }
        let ext = Kinds.ext(ofLow: p.folded)
        let low = (p as NSString).lastPathComponent.folded
        let kind = low.withCString { Kinds.kind(ofLowName: UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), len: low.utf8.count) }
        func clip(_ s: String) -> String {
            s.count > maxChars ? String(s.prefix(maxChars)) + "\n…[truncated, \(s.count) chars total]" : s
        }
        if kind == .image, let img = imageBlock(p) {
            return ([["type": "text", "text": "Image \(Paths.pretty(p))"], img], false)
        }
        if ext == "pdf" {
            guard let doc = PDFDocument(url: URL(fileURLWithPath: p)) else { return ("Could not open PDF", true) }
            var s = ""
            for i in 0..<doc.pageCount {
                s += "\n--- page \(i + 1) ---\n" + (doc.page(at: i)?.string ?? "")
                if s.count > maxChars { break }
            }
            if s.trimmingCharacters(in: .whitespacesAndNewlines).count < 40, let pg = doc.page(at: 0) {
                // scanned PDF: send the first page as an image
                let im = pg.thumbnail(of: CGSize(width: 1400, height: 1400), for: .mediaBox)
                if let tiff = im.tiffRepresentation, let src = CGImageSourceCreateWithData(tiff as CFData, nil), let b = jpegBlock(src) {
                    return ([["type": "text", "text": "Scanned PDF, \(doc.pageCount) pages; first page:"], b], false)
                }
            }
            return ("PDF, \(doc.pageCount) pages\n" + clip(s), false)
        }
        if ["doc", "docx", "rtf", "rtfd", "odt", "html", "htm", "webarchive", "wordml"].contains(ext) {
            let pr = Process()
            pr.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            pr.arguments = ["-convert", "txt", "-stdout", p]
            let pipe = Pipe(); pr.standardOutput = pipe; pr.standardError = FileHandle.nullDevice
            if (try? pr.run()) != nil {
                let d = pipe.fileHandleForReading.readDataToEndOfFile(); pr.waitUntilExit()
                return (clip(String(decoding: d, as: UTF8.self)), false)
            }
        }
        if ["pages", "numbers", "key", "xlsx", "pptx"].contains(ext) {
            // iWork and Office packages: fall back to the Spotlight text, which mdls can't print; use Quick Look's preview text instead
            return ("Rover can't extract text from .\(ext) files directly. Use file_info, or search_contents with likely words.", true)
        }
        guard let h = FileHandle(forReadingAtPath: p) else { return ("Can't read (permission?)", true) }
        let d = h.readData(ofLength: maxChars * 4)
        try? h.close()
        if d.prefix(4096).contains(0) { return ("Binary file (\(kind.label)); use file_info instead", true) }
        return (clip(String(decoding: d, as: UTF8.self)), false)
    }

    static func imageBlock(_ p: String) -> [String: Any]? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return nil }
        return jpegBlock(src)
    }

    static func jpegBlock(_ src: CGImageSource) -> [String: Any]? {
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1280,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": (data as Data).base64EncodedString()]]
    }

    public static func fileInfo(_ p: String) -> (String, Bool) { let (o, e) = info(p); return ("\(o)", e) }

    static func info(_ p: String) -> (Any, Bool) {
        guard FileManager.default.fileExists(atPath: p) else { return ("Not found", true) }
        var out: [String: Any] = ["path": Paths.pretty(p)]
        if let item = MDItemCreate(nil, p as CFString) {
            let keys: [(CFString, String)] = [
                (kMDItemWhereFroms, "downloaded_from"), (kMDItemKind, "kind"), (kMDItemContentCreationDate, "created"),
                (kMDItemContentModificationDate, "modified"), (kMDItemLastUsedDate, "last_opened"), (kMDItemFSSize, "bytes"),
                (kMDItemNumberOfPages, "pages"), (kMDItemPixelWidth, "width"), (kMDItemPixelHeight, "height"),
                (kMDItemDurationSeconds, "duration_seconds"), (kMDItemAuthors, "authors"), (kMDItemTitle, "title"),
                ("kMDItemUserTags" as CFString, "tags"), ("kMDItemUseCount" as CFString, "times_opened"), ("kMDItemCreator" as CFString, "made_with"),
            ]
            for (k, name) in keys {
                guard let v = MDItemCopyAttribute(item, k) else { continue }
                if let d = v as? Date { out[name] = ISO8601DateFormatter().string(from: d) }
                else if let a = v as? [Any] { out[name] = a.map { "\($0)" } }
                else { out[name] = "\(v)" }
            }
        }
        let j = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return (j, false)
    }
}

struct AssistantError: LocalizedError {
    let m: String
    init(_ m: String) { self.m = m }
    var errorDescription: String? { m }
}

enum Keychain {
    static let service = "Rover Claude API key"
    static func get() -> String? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var r: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ v: String) {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData] = Data(v.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
