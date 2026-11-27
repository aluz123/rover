// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
// Demo footage without touching the screen: ROVER_DEMO_FRAMES=<dir> ROVER_DEMO_SCRIPT=<file> renders the real panel
// off-screen at 30 fps into numbered PNGs. Script lines: "type <text>", "hold <seconds>", "down", "clear", "wait <seconds>".
import AppKit
import RoverCore

extension AppDelegate {
    func recordDemo() {
        let env = ProcessInfo.processInfo.environment
        let dir = env["ROVER_DEMO_FRAMES"]!
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let lines = ((try? String(contentsOfFile: env["ROVER_DEMO_SCRIPT"] ?? "")) ?? "").split(separator: "\n").map(String.init)
        if env["ROVER_DEMO_DARK"] != nil { panel.appearance = NSAppearance(named: .darkAqua) }
        panel.setFrameOrigin(NSPoint(x: -30000, y: -30000))   // ordered in so it renders, but on no display
        panel.orderFrontRegardless()
        model.limitedAccess = false
        model.panelShown()
        // expand the script into one action per frame
        var steps: [() -> Void] = []
        let rng = { (n: Int) -> Int in Int.random(in: 0..<n) }
        for l in lines {
            let parts = l.split(separator: " ", maxSplits: 1).map(String.init)
            guard let cmd = parts.first else { continue }
            let arg = parts.count > 1 ? parts[1] : ""
            switch cmd {
            case "type":
                for ch in arg { steps.append { [weak self] in self?.model.text.append(ch) }; for _ in 0..<(2 + rng(3)) { steps.append {} } }
            case "clear": steps.append { [weak self] in self?.model.text = "" }
            case "down": steps.append { [weak self] in self?.model.move(1, extend: false) }
            case "hold", "wait": for _ in 0..<Int((Double(arg) ?? 1) * 30) { steps.append {} }
            default: break
            }
        }
        let delay = Double(env["ROVER_DEMO_WARMUP"] ?? "4") ?? 4   // let the index load first
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            var i = 0
            Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { t in
                if i >= steps.count { t.invalidate(); NSLog("demo frames done: %d", i); exit(0) }
                steps[i]()
                // render on the next turn so SwiftUI has applied this frame's change
                let n = i
                DispatchQueue.main.async {
                    // typed text keeps a plain caret at the end (no select-all highlight)
                    if let ed = self.panel.firstResponder as? NSTextView { ed.setSelectedRange(NSRange(location: (ed.string as NSString).length, length: 0)) }
                    self.snapshot(to: String(format: "%@/f%05d.png", dir, n))
                }
                i += 1
            }
        }
    }
}
