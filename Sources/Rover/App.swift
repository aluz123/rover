// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement
import Quartz
import UserNotifications
import RoverCore

final class SearchPanel: NSPanel {
    static var recording = false   // demo footage: never take keyboard focus from whatever the user is doing
    override var canBecomeKey: Bool { !SearchPanel.recording }
    override var canBecomeMain: Bool { !SearchPanel.recording }
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
    let services = ServiceProvider()
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
        let recording = ProcessInfo.processInfo.environment["ROVER_DEMO_FRAMES"] != nil
        SearchPanel.recording = recording
        if !recording { setupStatusItem() }
        setupPanel()
        if !recording { registerHotKey() }
        Engine.shared.onChange = { [weak self] in DispatchQueue.main.async { self?.model.engineChanged() } }
        Engine.shared.openHandler = { path, reveal in
            let u = URL(fileURLWithPath: path)
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([u]) } else { NSWorkspace.shared.open(u) }
        }
        RuleEngine.shared.onActivity = { [weak self] msg in DispatchQueue.main.async { self?.model.flash("Automation · " + msg) } }
        Engine.shared.start()
        if recording { recordDemo(); return }   // demo footage: renders frames off-screen, never shows a window
        UNUserNotificationCenter.current().delegate = NotificationOpener.shared
        Checkup.start()
        ProJobs.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { AppDelegate.renewLicense(); self.renewTimer = self.renewTimer ?? Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { _ in AppDelegate.renewLicense() } }
        if Account.shared.signedIn { Account.shared.registerDevice(); Inbox.shared.start() }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
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

    func applicationWillTerminate(_ n: Notification) { Transfers.shared.stopAll(); Engine.shared.saveIfDirty() }

    /// rover://activate?key=ROVER-… (the button on the receipt page) and rover://pro
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls where u.scheme == "rover" {
            if u.host == "get" {   // rover://get?t=blob… (from getrover.dev/get). Any web page can open these, so ask first.
                guard Transfers.ticket(in: u.absoluteString) != nil else { continue }
                NSApp.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.messageText = "Download files from this link?"
                a.informativeText = "Only accept links from people you know. The files go to your Downloads folder, and macOS checks any apps before they open."
                a.addButton(withTitle: "Download"); a.addButton(withTitle: "Cancel")
                if a.runModal() == .alertFirstButtonReturn { Transfers.shared.receive(u.absoluteString) }
                continue
            }
            let key = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "key" }?.value
            ProWindow.shared.show(key: key)
        }
    }

    var renewTimer: Timer?
    /// Subscription keys last one paid period (+3 days); swap in a fresh one in the last week. Quiet unless it ended.
    static func renewLicense() {
        License.renewIfNeeded { r in
            if r == .renewed { AppDelegate.shared?.licenseChanged() }
        }
    }

    /// Pro turned on or off: re-register the shortcut (a chosen one only applies with Pro) and start the checkup.
    func licenseChanged() {
        renewTimer = renewTimer ?? Timer.scheduledTimer(withTimeInterval: 12 * 3600, repeats: true) { _ in AppDelegate.renewLicense() }
        registerHotKey()
        status?.button?.toolTip = "Rover — \(Shortcut.current.label)"
        if License.isPro { Checkup.runIfDue(); ProJobs.start() }
    }

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
            b.toolTip = "Rover — \(Shortcut.current.label)"
            b.target = self
            b.action = #selector(statusClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // drop files on the menu-bar icon to send them
            let drop = DropView(frame: b.bounds); drop.autoresizingMask = [.width, .height]
            b.addSubview(drop)
        }
    }

    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            let m = NSMenu()
            m.addItem(withTitle: "Search  (\(Shortcut.current.label))", action: #selector(toggle), keyEquivalent: "").target = self
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
            let found = Checkup.enabled && Checkup.foundBytes >= Checkup.threshold ? "  (\(ByteCountFormatter.string(fromByteCount: Checkup.foundBytes, countStyle: .file)) found)" : ""
            m.addItem(withTitle: "Send Files…" + (License.isPro ? "" : "  (Pro)"), action: #selector(sendFiles), keyEquivalent: "").target = self
            let waiting = Inbox.shared.offers.filter { $0.status == "new" || $0.status == "seen" }.count
            m.addItem(withTitle: "Transfers…" + (waiting > 0 ? "  (\(waiting) waiting)" : ""), action: #selector(showTransfers), keyEquivalent: "").target = self
            m.addItem(withTitle: Account.shared.email.map { "Signed in as \($0)…" } ?? "Sign In to Receive Files…", action: #selector(accountAction), keyEquivalent: "").target = self
            if Account.shared.signedIn {
                m.addItem(withTitle: People.shared.google.isEmpty ? "Import Gmail Contacts…" : "Refresh Gmail Contacts (\(People.shared.google.count))", action: #selector(importGmail), keyEquivalent: "").target = self
            }
            m.addItem(withTitle: "Free Up Space…" + found + (License.isPro ? "" : "  (Pro)"), action: #selector(freeUp), keyEquivalent: "").target = self
            m.addItem(withTitle: "Rebuild Index", action: #selector(rebuild), keyEquivalent: "").target = self
            let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            m.addItem(login)
            m.addItem(.separator())
            let pro = License.isPro
            m.addItem(withTitle: pro ? "Rover Pro ✓" : "Get Rover Pro (\(License.price) first month)…", action: #selector(showPro), keyEquivalent: "").target = self
            if License.info?.kind == "pro2" { m.addItem(withTitle: "Manage Subscription…", action: #selector(manageSubscription), keyEquivalent: "").target = self }
            let sc = NSMenuItem(title: "Shortcut: \(Shortcut.current.label)", action: nil, keyEquivalent: "")
            let scMenu = NSMenu()
            for s in Shortcut.all {
                let it = NSMenuItem(title: s.label + (pro || s == Shortcut.standard ? "" : "  (Pro)"), action: #selector(pickShortcut(_:)), keyEquivalent: "")
                it.target = self; it.representedObject = s.id; it.state = s == Shortcut.current ? .on : .off
                scMenu.addItem(it)
            }
            sc.submenu = scMenu
            m.addItem(sc)
            let chk = NSMenuItem(title: "Monthly Space Checkup" + (pro ? "" : "  (Pro)"), action: #selector(toggleCheckup), keyEquivalent: "")
            chk.target = self; chk.state = Checkup.enabled ? .on : .off
            m.addItem(chk)
            if pro {
                let img = NSMenuItem(title: ProJobs.imageStatus, action: nil, keyEquivalent: ""); img.isEnabled = false
                m.addItem(img)
            }
            let drv = NSMenuItem(title: "Drives" + (pro ? "" : "  (Pro)"), action: pro ? nil : #selector(showPro), keyEquivalent: "")
            drv.target = self
            if pro {
                let dm = NSMenu()
                let all = DriveCatalog.shared.all
                if all.isEmpty { let n = NSMenuItem(title: "Plug in a drive and Rover remembers what's on it", action: nil, keyEquivalent: ""); n.isEnabled = false; dm.addItem(n) }
                for d in all {
                    let busy = DriveCatalog.shared.isCataloging(d.uuid)
                    let it = NSMenuItem(title: "\(d.name): \(d.count.formatted()) files, \(ByteCountFormatter.string(fromByteCount: d.bytes, countStyle: .file))" + (busy ? " · reading…" : d.isConnected ? "" : " · not plugged in"), action: nil, keyEquivalent: "")
                    it.isEnabled = false; dm.addItem(it)
                    let f = NSMenuItem(title: "    Forget “\(d.name)”", action: #selector(forgetDrive(_:)), keyEquivalent: ""); f.target = self; f.representedObject = d.uuid
                    dm.addItem(f)
                }
                dm.addItem(.separator())
                dm.addItem(withTitle: "Read Plugged-In Drives Now", action: #selector(readDrives), keyEquivalent: "").target = self
                drv.submenu = dm
            }
            m.addItem(drv)
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
    @objc func showPro() { ProWindow.shared.show() }
    /// Opens Stripe's billing page for this subscription (cancel, change card, invoices). The key rides in the
    /// fragment, which browsers never send to a server; the page posts it to /api/portal.
    @objc func manageSubscription() {
        guard let k = License.storedKey, var c = URLComponents(url: License.manageURL, resolvingAgainstBaseURL: false) else { return }
        c.fragment = k
        if let u = c.url { NSWorkspace.shared.open(u) }
    }
    @objc func showTransfers() { TransfersWindow.shared.show() }
    @objc func sendFiles() {
        guard License.isPro else { ProWindow.shared.show(); return }
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true; p.prompt = "Send"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { ShareWindow.shared.show(p.urls.map { $0.path }) }
    }
    @objc func importGmail() { People.shared.load(); People.shared.refreshGoogle() }
    @objc func accountAction() {
        if Account.shared.signedIn {
            let a = NSAlert(); a.messageText = "Sign out of Rover?"; a.informativeText = "People won't be able to send files to this Mac until you sign in again."
            a.addButton(withTitle: "Sign Out"); a.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { Account.shared.signOut() }
        } else { Account.shared.signIn() }
    }
    @objc func forgetDrive(_ i: NSMenuItem) { if let id = i.representedObject as? String { DriveCatalog.shared.forget(id) } }
    @objc func readDrives() { DriveCatalog.shared.refresh(force: true) }
    @objc func pickShortcut(_ i: NSMenuItem) {
        guard let id = i.representedObject as? String, let s = Shortcut.all.first(where: { $0.id == id }) else { return }
        guard License.isPro || s == Shortcut.standard else { ProWindow.shared.show(); return }
        Shortcut.choose(s)
        if registerHotKey() { status.button?.toolTip = "Rover — \(s.label)" }
        else {
            Shortcut.choose(Shortcut.standard); registerHotKey()
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert(); a.messageText = "\(s.label) is taken"; a.informativeText = "Another app already uses that shortcut, so Rover kept \(Shortcut.standard.label)."; a.runModal()
        }
    }
    @objc func toggleCheckup() {
        guard License.isPro else { ProWindow.shared.show(); return }
        Checkup.setEnabled(!Checkup.enabled)
        if Checkup.enabled { Checkup.runIfDue() }
    }

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
        if !keepApp && !(JunkWindow.shared.isVisible || AccessWindow.shared.isVisible || ProWindow.shared.isVisible || TransfersWindow.shared.isVisible || ShareWindow.shared.isVisible) { NSApp.hide(nil) }
    }

    func windowDidResignKey(_ n: Notification) { if !model.previewing { hide() } }

    func installKeys() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, e.window === self.panel else { return e }
            return self.model.handleKey(e) ? nil : e
        }
    }

    // MARK: hotkey (⌥Space, or the Pro shortcut you picked)

    private var handlerInstalled = false
    @discardableResult
    func registerHotKey() -> Bool {
        if !handlerInstalled {
            handlerInstalled = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { AppDelegate.shared.toggle() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        if let h = hotKey { UnregisterEventHotKey(h); hotKey = nil }
        let s = Shortcut.current
        let id = EventHotKeyID(signature: OSType(0x48554E54), id: 1)
        let status = RegisterEventHotKey(UInt32(s.key), UInt32(s.mods), id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { NSLog("Rover: could not register \(s.label) (\(status))"); return false }
        return true
    }
}

/// Sits over the menu-bar icon: files dropped on it are sent with Rover. Clicks pass through to the button.
final class DropView: NSView {
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let urls = (s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        ShareWindow.shared.show(urls.map { $0.path })
        return true
    }
}
