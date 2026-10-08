import AppKit

// Standalone, disposable test application. IPC controls only windows created
// here; no Apple Events, injected input or real user documents are used.
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var windows: [NSWindow] = []
    var fields: [NSTextView] = []
    var timer: Timer?
    var animation: Timer?
    var sequence = 0
    var clicks = 0
    var sheet: NSWindow?
    let root: URL
    init(root: URL) { self.root = root }
    func applicationDidFinishLaunching(_ notification: Notification) {
        for index in 0..<2 {
            let window = NSWindow(contentRect: NSRect(x: 80+index*180, y: 140+index*90, width: 560, height: 340),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "置顶验收 · 同名窗口"; window.isReleasedWhenClosed = false
            let text = NSTextView(frame: NSRect(x: 20, y: 70, width: 520, height: 240))
            text.font = .systemFont(ofSize: 20); text.isRichText = false
            text.string = "测试窗口 \(index == 0 ? "A" : "B")\n这里仅有临时验收内容。\n可测试中文候选翻页、复制粘贴、滚动和拖动。\n不会保存文档。"
            let scroll = NSScrollView(frame: text.frame)
            scroll.hasVerticalScroller = true; scroll.autoresizingMask = [.width, .height]
            text.frame = NSRect(origin: .zero, size: scroll.contentSize)
            text.isVerticallyResizable = true; text.autoresizingMask = [.width]
            scroll.documentView = text; window.contentView?.addSubview(scroll)
            let button = NSButton(title: "首次点击不应触发 · 计数 0", target: self, action: #selector(clicked))
            button.frame = NSRect(x: 20, y: 20, width: 340, height: 32)
            window.contentView?.addSubview(button)
            fields.append(text); windows.append(window); window.makeKeyAndOrderFront(nil)
        }
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "退出验收窗口", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); menu.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        for (title, selector, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"),
                                        ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        NSApp.mainMenu = menu
        NSApp.activate(ignoringOtherApps: true); windows[0].makeKeyAndOrderFront(nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.readCommand() }
        report("ready")
    }
    @objc func clicked(_ button: NSButton) {
        clicks += 1; button.title = "点击计数 \(clicks)"; report("clicked")
    }
    func report(_ status: String) {
        let data: [String: Any] = ["pid": getpid(), "status": status, "sequence": sequence, "clicks": clicks,
            "windowIDs": windows.map(\.windowNumber), "visible": windows.map(\.isVisible),
            "key": windows.map(\.isKeyWindow)]
        if let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) {
            try? json.write(to: root.appendingPathComponent("fixture-status.json"), options: .atomic)
        }
    }
    func readCommand() {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("fixture-command.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let next = json["sequence"] as? Int, next != sequence, let action = json["action"] as? String else { return }
        sequence = next
        switch action {
        case "yieldTo":
            if let pid = json["pid"] as? Int32, let other = NSRunningApplication(processIdentifier: pid) {
                NSApp.yieldActivation(to: other)
            }
        case "frontA", "frontB":
            NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true)
            windows[action == "frontA" ? 0 : 1].makeKeyAndOrderFront(nil)
        case "moveA": windows[0].setFrameOrigin(NSPoint(x: windows[0].frame.minX+45, y: windows[0].frame.minY+20))
        case "resizeA":
            var rect = windows[0].frame; rect.size.width += 60; rect.size.height += 30
            windows[0].setFrame(rect, display: true)
        case "overlap": windows[1].setFrame(windows[0].frame, display: true)
        case "separate": windows[1].setFrameOrigin(NSPoint(x: 260, y: 230))
        case "minimizeA": windows[0].miniaturize(nil)
        case "restoreA": windows[0].deminiaturize(nil)
        case "closeA": windows[0].close()
        case "hide": NSApp.hide(nil)
        case "sheetA":
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 130), styleMask: [.titled], backing: .buffered, defer: false)
            sheet.title = "临时附属对话框"; self.sheet = sheet
            windows[0].beginSheet(sheet)
        case "dismissSheet":
            if let sheet { windows[0].endSheet(sheet); sheet.orderOut(nil); self.sheet = nil }
        case "dynamic":
            animation?.invalidate()
            var tick = 0
            animation = Timer.scheduledTimer(withTimeInterval: 1.0/15, repeats: true) { [weak self] _ in
                tick += 1; self?.fields[0].string = "动态测试窗口 A\n帧 \(tick)\n\(String(repeating: "●", count: tick % 24))"
            }
        case "static": animation?.invalidate(); animation = nil
        case "fullscreenA": windows[0].toggleFullScreen(nil)
        case "quit": report("quitting"); NSApp.terminate(nil)
        default: break
        }
        report(action)
    }
}

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory(), isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = FixtureDelegate(root: root)
app.delegate = delegate
app.run()
