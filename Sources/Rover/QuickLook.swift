// Rover — Copyright (c) 2026 Alex Towfigh. MIT License.
import AppKit
import Quartz

/// The system Quick Look panel, shown over Rover without taking the keyboard away:
/// Space toggles it, the arrow keys keep moving through results and the preview follows.
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private var urls: [URL] = []
    var onClose: (() -> Void)?
    var onArrow: ((Int) -> Void)?

    var isOpen: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func show(_ paths: [String], above window: NSWindow?) {
        urls = paths.map { URL(fileURLWithPath: $0) }
        guard let p = QLPreviewPanel.shared() else { return }
        p.dataSource = self
        p.delegate = self
        p.reloadData()
        p.currentPreviewItemIndex = 0
        if let w = window { p.level = NSWindow.Level(rawValue: w.level.rawValue + 1) }
        if !p.isVisible { p.orderFront(nil) }
        // keep typing and arrow keys going to Rover; the preview just floats beside it
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { window?.makeKey() }
    }

    func follow(_ path: String) {
        guard isOpen, urls.first?.path != path else { return }
        urls = [URL(fileURLWithPath: path)]
        QLPreviewPanel.shared().reloadData()
    }

    func close() {
        guard isOpen else { return }
        QLPreviewPanel.shared().orderOut(nil)
        onClose?()
    }

    // data source
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls[index] as NSURL }

    // if someone clicks into the panel, Space / Esc / arrows still behave
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch Int(event.keyCode) {
        case 49, 53: close(); return true            // space, esc
        case 125: onArrow?(1); return true           // down
        case 126: onArrow?(-1); return true          // up
        default: return false
        }
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
