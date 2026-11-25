// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement
import Quartz
import RoverCore

final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { (NSApp.delegate as? AppDelegate)?.hide() }
    // Quick Look asks the responder chain who controls it
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = QuickLook.shared; panel.delegate = QuickLook.shared }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate!
    var panel: SearchPanel!
    var status: NSStatusItem!
    let model = SearchModel()
    var hotKey: EventHotKeyRef?
    var keyMonitor: Any?

    /// A menu-bar app has no menu bar, and macOS routes ⌘C/⌘V/⌘X/⌘A through the Edit menu, so give it one (never shown).
    func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "Quit Rover", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        installEditMenu()
        AppDelegate.shared = self
        setupStatusItem()
        setupPanel()
        registerHotKey()
        Engine.shared.onChange = { [weak self] in DispatchQueue.main.async { self?.model.engineChanged() } }
        Engine.shared.openHandler = { path, reveal in
            let u = URL(fileURLWithPath: path)
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([u]) } else { NSWorkspace.shared.open(u) }
        }
        RuleEngine.shared.onActivity = { [weak self] msg in DispatchQueue.main.async { self?.model.flash("Automation · " + msg) } }
        Engine.shared.start()
        if let out = ProcessInfo.processInfo.environment["ROVER_DEMO_ACCESS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                AccessWindow.shared.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.snapshot(to: out, view: NSApp.keyWindow?.contentView) }
            }
        }
        if let q = ProcessInfo.processInfo.environment["ROVER_DEMO_QUERY"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.show(); self.model.text = q
                if let mode = ProcessInfo.processInfo.environment["ROVER_DEMO_MODE"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if mode == "move" { self.model.move(1, extend: true); self.model.move(1, extend: true); self.model.startMove() }
                        if mode == "ask" { self.model.startAsk() }
                        if mode == "space" { self.demoSpace() }
                    }
                }
                if let out = ProcessInfo.processInfo.environment["ROVER_SNAPSHOT"] {
                    let delay = Double(ProcessInfo.processInfo.environment["ROVER_SNAPSHOT_DELAY"] ?? "2.5") ?? 2.5
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.snapshot(to: out) }
                }
            }
        }
        if !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            try? SMAppService.mainApp.register()
        }
        if !Access.hasFullDiskAccess && !UserDefaults.standard.bool(forKey: "accessShown") && ProcessInfo.processInfo.environment["ROVER_DEMO_QUERY"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { AccessWindow.shared.show() }
        }
    }

    func applicationWillTerminate(_ n: Notification) { Engine.shared.saveIfDirty() }

    // MARK: menu bar

    func setupStatusItem() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = status.button {
            if let img = Bundle.main.image(forResource: "MenuBar") {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                b.image = img
            } else {
                b.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Rover")
            }
            b.toolTip = "Rover — ⌥Space"
            b.target = self
            b.action = #selector(statusClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            let m = NSMenu()
            m.addItem(withTitle: "Search  (⌥Space)", action: #selector(toggle), keyEquivalent: "").target = self
            m.addItem(.separator())
            let info = NSMenuItem(title: "\(Engine.shared.fileCount.formatted()) files indexed", action: nil, keyEquivalent: "")
            info.isEnabled = false
            m.addItem(info)
            if let t = ActionRunner.shared.lastTitle {
                m.addItem(withTitle: "Undo “\(t)”", action: #selector(undoLast), keyEquivalent: "").target = self
            }
            let autos = NSMenuItem(title: "Automations", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            if RuleEngine.shared.rules.isEmpty {
                let none = NSMenuItem(title: "None yet. Ask Rover (⇥) to set one up", action: nil, keyEquivalent: ""); none.isEnabled = false
                sub.addItem(none)
            }
            for r in RuleEngine.shared.rules {
                let it = NSMenuItem(title: "\(r.name): \(r.summary)", action: #selector(toggleRule(_:)), keyEquivalent: "")
                it.target = self; it.representedObject = r.id.uuidString; it.state = r.enabled ? .on : .off
                sub.addItem(it)
                let del = NSMenuItem(title: "    Remove “\(r.name)”", action: #selector(removeRule(_:)), keyEquivalent: "")
                del.target = self; del.representedObject = r.id.uuidString
                sub.addItem(del)
            }
            autos.submenu = sub
            m.addItem(autos)
            m.addItem(.separator())
            let ai = NSMenuItem(title: "Assistant: \(Assistant.backendName)", action: nil, keyEquivalent: ""); ai.isEnabled = false
            m.addItem(ai)
            m.addItem(withTitle: "Set Claude API Key (optional)…", action: #selector(setKey), keyEquivalent: "").target = self
            let acc = NSMenuItem(title: Access.hasFullDiskAccess ? "File Access: Full ✓" : "Give Rover Access…", action: #selector(showAccess), keyEquivalent: "")
            acc.target = self
            m.addItem(acc)
            m.addItem(withTitle: "Free Up Space…", action: #selector(freeUp), keyEquivalent: "").target = self
            m.addItem(withTitle: "Rebuild Index", action: #selector(rebuild), keyEquivalent: "").target = self
            let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            m.addItem(login)
            m.addItem(.separator())
            m.addItem(withTitle: "About Rover", action: #selector(about), keyEquivalent: "").target = self
            m.addItem(withTitle: "Quit Rover", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            status.menu = m
            status.button?.performClick(nil)
            status.menu = nil
        } else {
            toggle()
        }
    }

    @objc func about() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(string: "Finds anything on your Mac, instantly.\nBuilt by Alex Towfigh · MIT License",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationName: "Rover"])
    }

    @objc func showAccess() { AccessWindow.shared.show() }
    @objc func freeUp() { JunkWindow.shared.show() }

    @objc func undoLast() { model.flash(ActionRunner.shared.undoLast()); model.schedule() }
    @objc func toggleRule(_ i: NSMenuItem) {
        guard let s = i.representedObject as? String, let id = UUID(uuidString: s), let r = RuleEngine.shared.rules.first(where: { $0.id == id }) else { return }
        RuleEngine.shared.setEnabled(id, !r.enabled)
    }
    @objc func removeRule(_ i: NSMenuItem) {
        guard let s = i.representedObject as? String, let id = UUID(uuidString: s) else { return }
        RuleEngine.shared.remove(id)
    }
    @objc func setKey() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Claude API key (optional)"
        a.informativeText = "Rover's assistant uses your Claude Code login when available, so a key isn't required. A key can make answers faster. It's stored in your Keychain."
        let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty { Assistant.setAPIKey(f.stringValue) }
    }

    @objc func rebuild() { DispatchQueue.global().async { Engine.shared.rebuild() } }

    @objc func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        else { try? SMAppService.mainApp.register() }
    }

    // MARK: panel

    func setupPanel() {
        panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: model.showPreview ? 1120 : 720, height: 560),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView, .resizable],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        let host = NSHostingView(rootView: SearchView(model: model))
        let vfx = NSVisualEffectView()
        vfx.material = .popover
        vfx.blendingMode = .behindWindow
        vfx.state = .active
        vfx.wantsLayer = true
        vfx.layer?.cornerRadius = 16
        vfx.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        vfx.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: vfx.leadingAnchor), host.trailingAnchor.constraint(equalTo: vfx.trailingAnchor),
            host.topAnchor.constraint(equalTo: vfx.topAnchor), host.bottomAnchor.constraint(equalTo: vfx.bottomAnchor),
        ])
        panel.contentView = vfx
    }

    @objc func toggle() { panel.isVisible && panel.isKeyWindow ? hide() : show() }

    func snapshot(to path: String, view: NSView? = nil) {
        guard let v = view ?? panel.contentView else { return }
        let r = v.bounds
        NSLog("model text=[%@] mode=%@ hits=%d: %@", model.text, "\(model.mode)", model.listHits.count, model.listHits.prefix(6).map { $0.path + " (\($0.source == .content ? "C" : "N"))" }.joined(separator: " | "))
        let scale = panel.backingScaleFactor
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(r.width * scale), pixelsHigh: Int(r.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        rep.size = r.size
        ctx.cgContext.scaleBy(x: scale, y: scale)
        v.layer?.render(in: ctx.cgContext)
        // the blur material doesn't render offscreen; composite on a neutral backdrop
        let img = NSImage(size: r.size)
        img.lockFocus()
        NSColor.windowBackgroundColor.setFill(); r.fill()
        rep.draw(in: r)
        img.unlockFocus()
        if let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t), let png = b.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        NSLog("snapshot written \(path)")
    }

    func resizeForPreview() {
        var f = panel.frame
        let w: CGFloat = model.showPreview ? max(f.width, 1120) : min(f.width, 720)
        f.origin.x += (f.width - w) / 2
        f.size.width = w
        panel.setFrame(f, display: true, animate: true)
    }

    func show(resetFocus: Bool = true) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let f = screen.visibleFrame
        let w = panel.frame.width, h = panel.frame.height
        panel.setFrameOrigin(NSPoint(x: f.midX - w / 2, y: f.minY + f.height * 0.68 - h / 2))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        model.limitedAccess = !Access.hasFullDiskAccess
        model.panelShown()
        model.focusToken += 1
        if resetFocus { model.selectAllToken += 1 }
        installKeys()
    }

    /// Debug check for Space-to-preview: hover a row, press Space, report, press Space again.
    func demoSpace() {
        func key(_ code: UInt16, _ ch: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                             context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code)!
        }
        func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        log("rover key before: \(panel.isKeyWindow)")
        model.hover(2, true)
        let used = model.handleKey(key(49, " "))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let p = QLPreviewPanel.shared()!
            log("space handled=\(used) open=\(QuickLook.shared.isOpen) selected=\(self.model.selected) item=\((p.currentPreviewItem as? NSURL)?.path ?? "-") roverKey=\(self.panel.isKeyWindow) qlAbove=\(p.level.rawValue > self.panel.level.rawValue)")
            _ = self.model.handleKey(key(125, ""))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                log("after down: selected=\(self.model.selected) item=\((p.currentPreviewItem as? NSURL)?.path ?? "-")")
                let again = self.model.handleKey(key(49, " "))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    log("second space handled=\(again) open=\(QuickLook.shared.isOpen) roverVisible=\(self.panel.isVisible)")
                    _ = self.model.handleKey(key(35, "p"))
                    let typed = self.model.handleKey(key(49, " "))
                    log("space while typing handled=\(typed) (false = typed as a normal space)")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func hide(keepApp: Bool = false) {
        QuickLook.shared.close()
        panel.orderOut(nil)
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        // hiding the whole app would also hide Free Up Space / Access if they're open (that was the "nothing happens" bug)
        if !keepApp && !(JunkWindow.shared.isVisible || AccessWindow.shared.isVisible) { NSApp.hide(nil) }
    }

    func windowDidResignKey(_ n: Notification) { if !model.previewing { hide() } }

    func installKeys() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, e.window === self.panel else { return e }
            return self.model.handleKey(e) ? nil : e
        }
    }

    // MARK: hotkey ⌥Space

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { AppDelegate.shared.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x48554E54), id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { NSLog("Rover: could not register ⌥Space (\(status))") }
    }
}
