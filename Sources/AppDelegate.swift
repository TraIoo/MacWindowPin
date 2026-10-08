import AppKit
import ScreenCaptureKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = PinController()
    let hotKey = HotKey()
    private var status: NSStatusItem!
    private var settings: SettingsController!
    private let picker = WindowPicker()
    private var menuSelection: AXSelection?
    private var request = UUID()
    private var hotKeyError: String?
    private var requestBusy = false
    private var quitting = false
    private var readyToTerminate = false
    private var pickerSpaceObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--diagnose") { runDiagnostics(); return }
        #if WINDOWPIN_TESTING
        if let i = CommandLine.arguments.firstIndex(of: "--render-settings"), i+1 < CommandLine.arguments.count {
            renderSettings(path: CommandLine.arguments[i+1]); return
        }
        if CommandLine.arguments.contains("--self-test") { runSelfTests(delegate: self); return }
        if let index = CommandLine.arguments.firstIndex(of: "--integration-test"), index+1 < CommandLine.arguments.count {
            runIntegrationTests(delegate: self, directory: URL(fileURLWithPath: CommandLine.arguments[index+1], isDirectory: true)); return
        }
        #endif
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "置顶")
        status.button?.target = self; status.button?.action = #selector(openMenu)
        controller.onChange = { [weak self] in self?.updateStatus() }
        controller.onError = { [weak self] message in self?.showError(message) }
        settings = SettingsController(shortcut: Shortcut.load())
        settings.onSave = { [weak self] shortcut in
            guard let self else { return "工具已退出。" }
            let result = self.hotKey.register(shortcut)
            guard result == noErr else { return "快捷键注册失败（\(result)）：可能被占用。原快捷键保持不变，请换一个组合。" }
            shortcut.save(); self.hotKeyError = nil; self.updateStatus(); return nil
        }
        hotKey.onPress = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.picker.isActive, self.settings.window?.isKeyWindow != true else { return }
                do { self.toggle(try AX.frontWindow()) }
                catch { self.handleSelectionError(error) }
            }
        }
        let result = hotKey.register(Shortcut.load())
        if result != noErr {
            hotKeyError = "全局快捷键注册失败（\(result)），请在设置中修改。"
            showError(hotKeyError!)
        }
        pickerSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.picker.cancel() }
        }
        updateStatus()
        NSLog("WindowPin ready: AX=%d capture=%d hotkey=%d", AXIsProcessTrusted(), CGPreflightScreenCaptureAccess(), result)
        #if WINDOWPIN_TESTING
        if let i = CommandLine.arguments.firstIndex(of: "--performance-test"), i+1 < CommandLine.arguments.count {
            runPerformanceTests(delegate: self, directory: URL(fileURLWithPath: CommandLine.arguments[i+1], isDirectory: true))
        }
        #endif
        if CommandLine.arguments.contains("--settings") { settings.show() }
    }

    @objc private func openMenu() {
        // Read before NSMenu enters tracking. A menu action must not resolve our own app.
        menuSelection = try? AX.frontWindow()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let summary: String
        if let target = controller.target { summary = "当前：\(target.name) · \(target.title.isEmpty ? "无标题窗口" : target.title)" }
        else { summary = requestBusy ? "正在识别窗口…" : "当前未置顶" }
        let header = NSMenuItem(title: String(summary.prefix(70)), action: nil, keyEquivalent: ""); header.isEnabled = false
        menu.addItem(header)
        if let hotKeyError { let item = NSMenuItem(title: hotKeyError, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
        if !controller.compatibility.isEmpty {
            let item = NSMenuItem(title: "此应用部分通知受限（最多延迟 1 秒）", action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item)
        }
        menu.addItem(.separator())
        add(menu, "切换当前窗口置顶    \(hotKey.shortcut?.label ?? "未注册")", #selector(toggleMenuWindow))
        add(menu, "选择窗口…", #selector(chooseWindow))
        add(menu, "取消置顶", #selector(unpin), enabled: controller.isPinned || requestBusy)
        menu.addItem(.separator())
        add(menu, "设置与权限…", #selector(showSettings))
        add(menu, "退出置顶", #selector(quit))
        if let button = status.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button) }
    }
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; item.isEnabled = enabled; menu.addItem(item)
    }
    private func updateStatus() {
        guard status != nil else { return }
        status.button?.image = NSImage(systemSymbolName: controller.isPinned ? "pin.fill" : "pin", accessibilityDescription: "置顶")
        status.button?.toolTip = controller.target.map { "置顶：\($0.name) · \($0.title)" } ?? "置顶 · \(hotKey.shortcut?.label ?? "快捷键未注册")"
    }
    private func permissionsReady() -> Bool {
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            settings.show(message: "首次使用需要允许两项权限。也可以稍后再试；工具不会自动重复请求。")
            return false
        }
        return true
    }
    @objc private func toggleMenuWindow() {
        guard let selection = menuSelection else {
            if !permissionsReady() { return }
            showError("菜单打开前未能识别工作窗口。请使用“选择窗口”，或回到目标窗口后按快捷键。")
            return
        }
        toggle(selection)
    }
    private func toggle(_ selection: AXSelection) {
        if let target = controller.target, target.pid == selection.pid, CFEqual(target.window, selection.window) { unpin(); return }
        guard permissionsReady() else { return }
        let id = UUID(); request = id; requestBusy = true
        Task {
            do {
                let content = try await WindowResolver.content()
                guard self.request == id, !self.quitting else { return }
                let (target, _) = try WindowResolver.resolve(selection, content: content)
                self.requestBusy = false; self.controller.pin(target)
            } catch {
                guard self.request == id else { return }
                self.requestBusy = false; self.showError(error.localizedDescription)
            }
        }
    }
    @objc private func chooseWindow() {
        guard permissionsReady() else { return }
        let id = UUID(); request = id; requestBusy = true
        Task {
            do {
                let content = try await WindowResolver.content()
                guard self.request == id, !self.quitting else { return }
                self.picker.begin(content: content) { [weak self] sc in
                    guard let self, self.request == id else { return }
                    self.requestBusy = false
                    guard let sc else { return }
                    do {
                        let target = try WindowResolver.resolve(sc)
                        self.controller.pin(target)
                    } catch { self.showError(error.localizedDescription) }
                }
            } catch {
                guard self.request == id else { return }
                self.requestBusy = false; self.showError(error.localizedDescription)
            }
        }
    }
    @objc private func unpin() { request = UUID(); requestBusy = false; picker.cancel(); controller.cancel() }
    @objc private func showSettings() { settings.show() }
    private func handleSelectionError(_ error: Error) {
        if !permissionsReady() { return }
        showError(error.localizedDescription)
    }
    private func showError(_ message: String) {
        DispatchQueue.main.async {
            guard !self.quitting else { return }
            let alert = NSAlert(); alert.messageText = "置顶未完成"; alert.informativeText = message
            alert.addButton(withTitle: "知道了")
            NSApp.activate(ignoringOtherApps: true); alert.runModal()
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToTerminate { return .terminateNow }
        if quitting { return .terminateCancel }
        quitting = true; request = UUID(); picker.cancel(); hotKey.stop(); controller.cancel(reason: "退出")
        status?.button?.isEnabled = false
        Task {
            await controller.drain()
            NSLog("WindowPin shutdown drained: %@", controller.resourceSummary)
            readyToTerminate = true
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        // terminateLater runs AppKit's nested termination loop. When invoked
        // from a MainActor task it can prevent that task's cleanup from running.
        // Cancel this attempt, drain asynchronously, then terminate normally.
        return .terminateCancel
    }
}
