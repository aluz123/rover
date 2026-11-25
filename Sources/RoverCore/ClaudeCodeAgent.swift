// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import Foundation

/// Runs the assistant through the Claude Code CLI (`claude -p`), which uses the person's existing
/// Claude login, so no API key is needed. Claude Code can only run Rover's own read-only commands and
/// read files; file changes come back as a plan the app shows for approval.
final class ClaudeCodeAgent {
    static func findCLI() -> String? {
        let home = NSHomeDirectory()
        let candidates = [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          home + "/.claude/local/claude", home + "/.npm-global/bin/claude", home + "/.bun/bin/claude"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        // last resort: ask a login shell
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty || !FileManager.default.isExecutableFile(atPath: s) ? nil : s
    }

    static var roverBinary: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    static func systemPrompt(rover: String) -> String {
        """
        You are Rover, the file assistant inside a Mac search app. You help one person find their files, understand what is in them, and organize them. Be brief: one to three short sentences unless they ask for more.

        Tools you can use:
        - `\(rover) <words>` via Bash: instant search over every file and folder name. Plain English works: kinds ("pdf", "photos", "spreadsheet", "deck"), dates ("last week", "march", "2024"), sizes ("big", ">500mb"), places ("in downloads"), extensions (".py"), "newest"/"biggest". Try two or three phrasings or synonyms before concluding something doesn't exist.
        - `\(rover) -c <words>`: also searches inside documents (Spotlight's content index).
        - `\(rover) ls <folder>` lists a folder; `\(rover) info <path>` shows metadata such as where a file was downloaded from and when it was last opened.
        - Read: read a file's text, a PDF, or look at an image. Only when you need the contents.
        You cannot change files yourself. Never try other shell commands.

        To show files as clickable results, or to propose changes, end your reply with exactly one fenced block tagged rover containing JSON, and nothing after it:
        ```rover
        {"show": ["/absolute/path", "..."],
         "changes": {"summary": "one sentence", "actions": [{"op": "move", "path": "/abs/file", "to": "/abs/folder"}]},
         "rule": {"name": "File invoices", "folder": "~/Downloads", "match": "invoice pdf", "op": "move", "to": "~/Documents/Invoices"}}
        ```
        Include only the keys you need. "show" lists the best matches first. Action ops: move (to), rename (name, keep the extension), copy (to), trash, mkdir (path), tag (tag). There is no permanent delete. "rule" sets up an automation that acts on new files arriving in one folder (or, with "older_than_days", on files untouched that long); rule ops: move, copy, rename (with "rename_template" using {date} {name} {ext}), trash, tag. The person approves changes and rules in the app before anything happens, so describe them as proposals, never as done.
        """
    }

    struct Plan {
        var show: [String] = []
        var summary = ""
        var actions: [FileAction] = []
        var rule: Rule?
    }

    private var proc: Process?
    private(set) var sessionID: String?

    func reset() { cancel(); sessionID = nil }
    func cancel() { if let p = proc, p.isRunning { p.terminate() }; proc = nil }

    /// Streams events; `finish` receives the final visible text and the parsed plan (or an error).
    func run(prompt: String, cli: String, onText: @escaping (String) -> Void, onStatus: @escaping (String) -> Void,
             finish: @escaping (String, Plan, String?) -> Void) {
        cancel()
        let rover = Self.roverBinary
        let work = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Rover/agent")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        var args = ["-p", prompt, "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--append-system-prompt", Self.systemPrompt(rover: rover),
                    "--allowedTools", "Bash(\(rover):*)", "Read", "Glob",
                    "--disallowedTools", "Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch", "Task", "Agent",
                    "--add-dir", NSHomeDirectory()]
        if let s = sessionID { args += ["--resume", s] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        p.currentDirectoryURL = work
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ((cli as NSString).deletingLastPathComponent) + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env.removeValue(forKey: "ANTHROPIC_API_KEY") // use the person's Claude login
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        proc = p

        var buffer = Data()
        var visible = ""        // text shown so far this turn
        var full = ""           // text of the current model message
        var shown = 0           // characters of `full` already shown
        var hidden = false      // stop showing text once the ```rover block begins
        var finalText: String?
        var errorText: String?
        let lock = NSLock()
        let fence = "```rover"

        func emit(_ t: String) { if !t.isEmpty { visible += t; onText(t) } }

        func handle(line: Data) {
            guard let ev = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let type = ev["type"] as? String else { return }
            switch type {
            case "system":
                if let s = ev["session_id"] as? String { sessionID = s }
            case "stream_event":
                guard let e = ev["event"] as? [String: Any], let et = e["type"] as? String else { return }
                if et == "message_start" {
                    full = ""; shown = 0; hidden = false
                    if !visible.isEmpty && !visible.hasSuffix("\n") { emit("\n\n") }
                }
                guard et == "content_block_delta", let d = e["delta"] as? [String: Any], d["type"] as? String == "text_delta",
                      let t = d["text"] as? String, !hidden else { return }
                full += t
                var upTo = full.count
                if let r = full.range(of: fence) {
                    hidden = true
                    upTo = full.distance(from: full.startIndex, to: r.lowerBound)
                } else {
                    // hold back a possible partial fence at the end
                    for k in stride(from: min(fence.count - 1, full.count), to: 0, by: -1) where full.hasSuffix(String(fence.prefix(k))) { upTo = full.count - k; break }
                }
                if upTo > shown {
                    emit(String(full.dropFirst(shown).prefix(upTo - shown)))
                    shown = upTo
                }
            case "assistant":
                guard let m = ev["message"] as? [String: Any], let content = m["content"] as? [[String: Any]] else { return }
                for b in content where b["type"] as? String == "tool_use" {
                    onStatus(Self.status(b["name"] as? String ?? "", b["input"] as? [String: Any] ?? [:], rover: rover))
                }
            case "result":
                if let s = ev["session_id"] as? String { sessionID = s }
                finalText = ev["result"] as? String
                if (ev["is_error"] as? Bool) == true { errorText = (ev["result"] as? String) ?? "Claude Code reported an error" }
            default: break
            }
        }

        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { return }
            lock.lock()
            buffer.append(d)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                if !line.isEmpty { handle(line: Data(line)) }
            }
            lock.unlock()
        }
        p.terminationHandler = { pr in
            out.fileHandleForReading.readabilityHandler = nil
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            buffer.append(rest)
            for line in buffer.split(separator: 0x0A) where !line.isEmpty { handle(line: Data(line)) }
            lock.unlock()
            let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if pr.terminationReason == .uncaughtSignal { finish(visible, Plan(), nil); return }
            if finalText == nil && pr.terminationStatus != 0 {
                var msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if msg.lowercased().contains("login") || msg.lowercased().contains("auth") { msg = "Claude Code isn't signed in. Run `claude` once in Terminal and log in." }
                finish(visible, Plan(), msg.isEmpty ? "Claude Code exited with status \(pr.terminationStatus)" : String(msg.prefix(400)))
                return
            }
            let (text, plan) = Self.parse(finalText ?? visible)
            finish(visible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : visible, plan, errorText)
        }
        do { try p.run() } catch { finish("", Plan(), "Couldn't start Claude Code: \(error.localizedDescription)") }
    }

    static func status(_ tool: String, _ input: [String: Any], rover: String) -> String {
        switch tool {
        case "Bash":
            let c = (input["command"] as? String ?? "").replacingOccurrences(of: rover, with: "rover")
            if c.hasPrefix("rover -c ") { return "Looking inside files for “\(c.dropFirst(8))”…" }
            if c.hasPrefix("rover ls ") { return "Listing \((String(c.dropFirst(8)) as NSString).lastPathComponent)…" }
            if c.hasPrefix("rover info ") { return "Checking \((String(c.dropFirst(10)) as NSString).lastPathComponent)…" }
            if c.hasPrefix("rover ") { return "Searching “\(c.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))”…" }
            return "Working…"
        case "Read": return "Reading \(((input["file_path"] as? String ?? "") as NSString).lastPathComponent)…"
        case "Glob": return "Looking through folders…"
        default: return "Working…"
        }
    }

    /// Split the visible answer from the ```rover JSON block.
    static func parse(_ s: String) -> (String, Plan) {
        var plan = Plan()
        guard let r = s.range(of: "```rover") else { return (s.trimmingCharacters(in: .whitespacesAndNewlines), plan) }
        let text = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        var body = String(s[r.upperBound...])
        if let end = body.range(of: "```") { body = String(body[..<end.lowerBound]) }
        guard let d = body.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return (text, plan) }
        plan.show = (j["show"] as? [String] ?? []).map(Paths.expand)
        if let c = j["changes"] as? [String: Any] {
            plan.summary = c["summary"] as? String ?? "Proposed changes"
            for r in c["actions"] as? [[String: Any]] ?? [] {
                guard let op = (r["op"] as? String).flatMap(FileAction.Op.init(rawValue:)), let p = r["path"] as? String else { continue }
                plan.actions.append(FileAction(op: op, path: Paths.expand(p), to: (r["to"] as? String).map(Paths.expand), name: r["name"] as? String, tag: r["tag"] as? String))
            }
        }
        if let r = j["rule"] as? [String: Any], let n = r["name"] as? String, let f = r["folder"] as? String,
           let op = (r["op"] as? String).flatMap(FileAction.Op.init(rawValue:)) {
            var rule = Rule(name: n, folder: Paths.expand(f), match: r["match"] as? String ?? "", op: op)
            rule.to = (r["to"] as? String).map(Paths.expand)
            rule.renameTemplate = r["rename_template"] as? String
            rule.tag = r["tag"] as? String
            rule.olderThanDays = r["older_than_days"] as? Int
            plan.rule = rule
        }
        return (text, plan)
    }
}
