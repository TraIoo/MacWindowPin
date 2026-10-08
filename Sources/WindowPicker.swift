import AppKit
import ScreenCaptureKit

final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PickerView: NSView {
    var onMove: ((CGPoint) -> Void)?
    var onChoose: (() -> Void)?
    var onCancel: (() -> Void)?
    var outline: CGRect?
    private var down = false
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) { onMove?(NSEvent.mouseLocation) }
    override func mouseDown(with event: NSEvent) { down = true; onMove?(NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { onMove?(NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { if down { down = false; onChoose?() } }
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) { onCancel?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onCancel?() } }
    override func scrollWheel(with event: NSEvent) {}
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.08).setFill(); bounds.fill()
        if let outline {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: outline.insetBy(dx: 2, dy: 2)); path.lineWidth = 4; path.stroke()
        }
        let text = "悬停选择窗口 · 点击确认 · Esc 取消" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let box = NSRect(x: (bounds.width-size.width)/2-18, y: 48, width: size.width+36, height: 44)
        NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        text.draw(at: CGPoint(x: box.minX+18, y: box.minY+12), withAttributes: attrs)
    }
}

@MainActor
final class WindowPicker {
    private var panels: [PickerPanel] = []
    private var windows: [CGWindowID: SCWindow] = [:]
    private var chosen: SCWindow?
    var completion: ((SCWindow?) -> Void)?
    var isActive: Bool { !panels.isEmpty }

    func begin(content: SCShareableContent, completion: @escaping (SCWindow?) -> Void) {
        cancel()
        self.completion = completion
        windows = Dictionary(uniqueKeysWithValues: WindowResolver.eligible(content).map { ($0.windowID, $0) })
        for screen in NSScreen.screens {
            let panel = PickerPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.level = .screenSaver
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.hidesOnDeactivate = false; panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenNone, .ignoresCycle]
            let view = PickerView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onMove = { [weak self] point in self?.hover(point) }
            view.onChoose = { [weak self] in self?.finish() }
            view.onCancel = { [weak self] in self?.cancel() }
            panel.contentView = view; panel.makeFirstResponder(view)
            panels.append(panel); panel.orderFrontRegardless()
        }
        panels.first?.makeKey()
        hover(NSEvent.mouseLocation)
    }
    private func hover(_ point: CGPoint) {
        let height = CGDisplayBounds(CGMainDisplayID()).height
        let cgPoint = CGPoint(x: point.x, y: height-point.y)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        chosen = nil
        for item in list {
            guard let pid = item[kCGWindowOwnerPID as String] as? Int32, pid != getpid(),
                  let dict = item[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary), rect.contains(cgPoint) else { continue }
            // Do not select through a popup, system panel or unsupported foreground window.
            guard let id = item[kCGWindowNumber as String] as? UInt32,
                  let window = windows[id], WindowIdentity.sameFrame(rect, window.frame) else { break }
            chosen = window; break
        }
        for panel in panels {
            guard let view = panel.contentView as? PickerView else { continue }
            if let chosen {
                let global = WindowIdentity.appKitFrame(chosen.frame, primaryHeight: height)
                view.outline = global.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
            } else { view.outline = nil }
            view.needsDisplay = true
        }
    }
    private func finish() {
        let selection = chosen, callback = completion
        close(); callback?(selection)
    }
    func cancel() { let callback = completion; close(); callback?(nil) }
    private func close() {
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels.removeAll(); windows.removeAll(); chosen = nil; completion = nil
    }
}
