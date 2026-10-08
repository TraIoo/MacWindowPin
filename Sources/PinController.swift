import AppKit
import ScreenCaptureKit

@MainActor
final class PinController {
    enum Mode: String { case idle, starting, mirroring, handingOff, interactive }
    private(set) var mode: Mode = .idle
    private(set) var target: PinnedTarget?
    private(set) var compatibility = ""
    private(set) var cancellationReason = ""
    private(set) var capture: CaptureSession?
    private var session = UUID()
    private var captureGeneration = UUID()
    private var operations = SerialOperations()
    private var panel: MirrorPanel?
    private var watcher: AXWatch?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var focusWork: DispatchWorkItem?
    private var startupTimeout: Task<Void, Never>?
    private var initiallyFocused = false
    private var lastFrame: CGRect?
    private var unknownFocusCount = 0
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    var isPinned: Bool { target != nil }
    var resourceSummary: String {
        "mode=\(mode.rawValue) target=\(target == nil ? 0 : 1) stream=\(capture?.stream == nil ? 0 : 1) panel=\(panel == nil ? 0 : 1) timer=\(timer == nil ? 0 : 1) observers=\(observers.count) ax=\(watcher == nil ? 0 : 1)"
    }

    func pin(_ newTarget: PinnedTarget) {
        cancel(reason: "替换")
        session = UUID(); target = newTarget; cancellationReason = ""; compatibility = ""
        initiallyFocused = NSWorkspace.shared.frontmostApplication?.processIdentifier == newTarget.pid &&
            AX.element(newTarget.app, kAXFocusedWindowAttribute).map { CFEqual($0, newTarget.window) } == true
        let current = session
        watcher = AXWatch(target: newTarget) { [weak self] name in
            // AXObserver runs on the main run loop. Coalesce bursts rather than
            // doing synchronous cross-process reads inside the callback.
            MainActor.assumeIsolated {
                guard let self, self.session == current else { return }
                if name == kAXUIElementDestroyedNotification || name == kAXWindowMiniaturizedNotification {
                    self.cancel(reason: name == kAXUIElementDestroyedNotification ? "源窗口已关闭" : "源窗口已最小化")
                } else { self.scheduleEvaluation() }
            }
        }
        if let unsupported = watcher?.unsupported, !unsupported.isEmpty {
            compatibility = "此应用缺少部分辅助功能通知，已使用每秒一次的状态检查；焦点恢复可能延迟。"
            NSLog("WindowPin unsupported notifications: %@", unsupported.joined(separator: ", "))
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.workspaceChanged(note) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel(reason: "显示器布局已变化") }
        })
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        timer?.tolerance = 0.2
        RunLoop.main.add(timer!, forMode: .common)
        beginMirror()
    }

    private func scheduleEvaluation() {
        focusWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        focusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func workspaceChanged(_ note: Notification) {
        guard let target else { return }
        if [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.willSleepNotification].contains(note.name) {
            cancel(reason: "桌面、全屏或会话已切换"); return
        }
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.processIdentifier == target.pid,
           [NSWorkspace.didHideApplicationNotification, NSWorkspace.didTerminateApplicationNotification].contains(note.name) {
            cancel(reason: "源应用已隐藏或退出"); return
        }
        if note.name == NSWorkspace.didActivateApplicationNotification,
           app?.processIdentifier == target.pid, mode != .handingOff { initiallyFocused = false }
        scheduleEvaluation()
    }

    private func evaluate() {
        guard let target, mode != .idle else { return }
        guard AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: target.pid),
              !app.isTerminated, !app.isHidden, !AX.bool(target.window, kAXMinimizedAttribute),
              !AX.bool(target.window, "AXFullScreen"), let frame = AX.frame(target.window),
              AX.windows(target.app).contains(where: { CFEqual($0, target.window) }) else {
            cancel(reason: "源窗口不可用、已最小化、全屏或权限已撤销"); return
        }
        // Also inspect the exact CG window ID. No full-desktop capture is used.
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], target.id) as? [[String: Any]]
        guard let item = info?.first,
              (item[kCGWindowOwnerPID as String] as? Int32) == target.pid,
              item[kCGWindowIsOnscreen as String] as? Bool == true else {
            cancel(reason: "源窗口已离开当前桌面或不再可见"); return
        }
        guard mode != .handingOff else { return }
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        if front.processIdentifier == getpid() { return } // own menu/settings never steals the handoff
        if front.activationPolicy != .regular { return } // IME candidates and system panels

        if front.processIdentifier == target.pid {
            guard let focused = AX.element(target.app, kAXFocusedWindowAttribute) else {
                // Fail closed when focus cannot be determined: never cover an unknown dialog.
                unknownFocusCount += 1
                enterInteractive()
                if unknownFocusCount >= 3 { fail("无法确认源应用的焦点窗口，已取消置顶。") }
                return
            }
            unknownFocusCount = 0
            let role = AX.string(focused, kAXSubroleAttribute)
            let same = CFEqual(focused, target.window)
            let child = AX.element(focused, kAXParentAttribute).map { CFEqual($0, target.window) } == true
            let hasSheet = (AX.value(target.window, kAXChildrenAttribute) as? [AXUIElement] ?? [])
                .contains { AX.string($0, kAXRoleAttribute) == kAXSheetRole }
            if child || hasSheet || role != kAXStandardWindowSubrole {
                // A sheet opened by a keyboard command must win even before the
                // first mirror click. Never leave the initial mirror over it.
                initiallyFocused = false
                enterInteractive()
                return
            }
            if same {
                if !initiallyFocused || mode == .interactive { enterInteractive() }
                else { updateMirrorGeometry(frame) }
                return
            }
        }
        initiallyFocused = false
        unknownFocusCount = 0
        if mode == .interactive { beginMirror() }
        else { updateMirrorGeometry(frame) }
        onChange?()
    }

    private func updateMirrorGeometry(_ frame: CGRect) {
        guard let lastFrame, !WindowIdentity.sameFrame(frame, lastFrame, tolerance: 0.5) else { return }
        if abs(frame.width-lastFrame.width) > 0.5 || abs(frame.height-lastFrame.height) > 0.5 {
            beginMirror() // Pixel dimensions must follow a source resize.
            return
        }
        // A desktop-independent window stream does not depend on its position.
        // Keep its queue and frames alive while moving the matching panel.
        let oldScale = panel?.backingScaleFactor
        panel?.place(frame)
        if let oldScale, oldScale != panel?.backingScaleFactor {
            beginMirror() // Preserve native resolution when crossing display scales.
        } else { self.lastFrame = frame }
    }

    private func beginMirror() {
        guard target != nil else { return }
        mode = .starting
        captureGeneration = UUID()
        let generation = captureGeneration, current = session
        startupTimeout?.cancel()
        panel?.orderOut(nil); panel?.mirror.clear()
        capture?.invalidate()
        onChange?()
        operations.enqueue { [weak self] in
            guard let self else { return }
            if let old = self.capture { await old.stop(); self.capture = nil }
            guard self.session == current, self.captureGeneration == generation, let target = self.target else { return }
            do {
                let content = try await WindowResolver.content()
                guard self.session == current, self.captureGeneration == generation else { return }
                let sc = try WindowResolver.revalidate(target, content: content)
                guard let frame = AX.frame(target.window) else { throw IdentityError.unavailable }
                let panel = self.panel ?? MirrorPanel()
                self.panel = panel
                self.lastFrame = frame
                panel.place(frame)
                panel.mirror.onClick = { [weak self] in self?.handOff() }
                let capture = CaptureSession()
                self.capture = capture
                capture.onFrame = { [weak self, weak panel] sample in
                    guard let self, self.session == current, self.captureGeneration == generation,
                          self.mode == .starting || self.mode == .mirroring else { return }
                    panel?.mirror.display(sample)
                    if self.mode == .starting {
                        self.mode = .mirroring; self.startupTimeout?.cancel()
                        panel?.orderFrontRegardless(); self.onChange?()
                    }
                }
                capture.onFailure = { [weak self] error in
                    guard let self, self.session == current, self.captureGeneration == generation else { return }
                    self.fail("窗口捕捉已停止：\(error.localizedDescription)")
                }
                self.startupTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled, let self, self.session == current,
                          self.captureGeneration == generation, self.mode == .starting else { return }
                    self.fail("未收到可用画面。窗口可能受保护，或屏幕录制权限需要重启工具后生效。")
                }
                try await capture.start(window: sc)
                if self.session != current || self.captureGeneration != generation {
                    await capture.stop()
                    if self.capture === capture { self.capture = nil }
                }
            } catch {
                guard self.session == current, self.captureGeneration == generation else { return }
                self.fail("无法置顶：\(error.localizedDescription)")
            }
        }
    }

    func handOff() {
        guard let target, mode == .mirroring, let app = NSRunningApplication(processIdentifier: target.pid) else { return }
        mode = .handingOff; onChange?()
        let current = session
        Task {
            do {
                _ = try WindowResolver.revalidate(target, content: try await WindowResolver.content())
                guard self.session == current, self.mode == .handingOff else { return }
                // Public API only. Raising a window does not synthesize input.
                let raised = AXUIElementPerformAction(target.window, kAXRaiseAction as CFString)
                guard raised == .success else { throw IdentityError.unsupported }
                _ = AXUIElementSetAttributeValue(target.window, kAXMainAttribute as CFString, kCFBooleanTrue)
                let requested = app.activate(options: [])
                guard requested else { throw IdentityError.unavailable }
                for _ in 0..<25 {
                    guard self.session == current, self.mode == .handingOff else { return }
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
                       AX.element(target.app, kAXFocusedWindowAttribute).map({ CFEqual($0, target.window) }) == true {
                        self.initiallyFocused = false
                        self.enterInteractive()
                        return
                    }
                    try await Task.sleep(for: .milliseconds(40))
                }
                throw IdentityError.unavailable
            } catch {
                guard self.session == current else { return }
                self.fail("未能确认目标窗口已获得焦点，已取消置顶。\n\(error.localizedDescription)")
            }
        }
    }

    private func enterInteractive() {
        guard target != nil, mode != .interactive else { return }
        mode = .interactive; captureGeneration = UUID()
        startupTimeout?.cancel(); startupTimeout = nil
        panel?.orderOut(nil); panel?.mirror.clear()
        capture?.invalidate()
        operations.enqueue { [weak self] in
            if let capture = self?.capture { await capture.stop(); self?.capture = nil }
        }
        onChange?()
    }

    func cancel(reason: String = "已取消置顶") {
        if target != nil { NSLog("WindowPin cancel: %@", reason) }
        session = UUID(); captureGeneration = UUID()
        target = nil; mode = .idle; cancellationReason = reason
        startupTimeout?.cancel(); startupTimeout = nil
        focusWork?.cancel(); focusWork = nil
        timer?.invalidate(); timer = nil
        watcher?.stop(); watcher = nil
        for token in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()
        panel?.mirror.onClick = nil; panel?.mirror.clear(); panel?.orderOut(nil); panel?.close(); panel = nil
        capture?.invalidate()
        operations.enqueue { [weak self] in
            if let capture = self?.capture { await capture.stop(); self?.capture = nil }
        }
        lastFrame = nil; unknownFocusCount = 0
        onChange?()
    }
    private func fail(_ message: String) { cancel(reason: message); onError?(message) }
    func drain() async { await operations.drain() }
}
