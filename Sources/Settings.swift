import AppKit
import ApplicationServices

final class SettingsContentView: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
}

@MainActor
final class SettingsController: NSWindowController {
    private let accessibilityLabel = NSTextField(labelWithString: "")
    private let captureLabel = NSTextField(labelWithString: "")
    private let resultLabel = NSTextField(wrappingLabelWithString: "")
    private let recorder = ShortcutRecorder()
    var onSave: ((Shortcut) -> String?)?
    var onClose: (() -> Void)?
    private var activeObserver: NSObjectProtocol?

    init(shortcut: Shortcut) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "置顶 · 设置"; window.isReleasedWhenClosed = false
        window.contentView = SettingsContentView(frame: NSRect(x: 0, y: 0, width: 520, height: 560))
        super.init(window: window)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        let title = NSTextField(labelWithString: "把一个窗口留在上面")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        stack.addArrangedSubview(title)
        let intro = NSTextField(wrappingLabelWithString: "实时显示所选窗口的画面。第一次点击只负责进入原窗口，之后正常输入；切换到其他窗口时恢复悬浮画面。")
        stack.addArrangedSubview(intro)
        let privacy = NSTextField(wrappingLabelWithString: "辅助功能：准确识别和激活所选窗口。\n屏幕录制：仅捕捉所选窗口，最高 15 帧/秒，无音频、不保存画面、不上传。取消置顶后停止捕捉。\n系统“正在共享”表示本机实时窗口捕捉，不代表网络共享。")
        privacy.textColor = .secondaryLabelColor
        stack.addArrangedSubview(privacy)
        stack.addArrangedSubview(permissionRow(label: accessibilityLabel, title: "允许辅助功能…", action: #selector(requestAccessibility)))
        stack.addArrangedSubview(permissionRow(label: captureLabel, title: "允许屏幕录制…", action: #selector(requestCapture)))
        let refresh = NSButton(title: "重新检查权限", target: self, action: #selector(refreshPermissions))
        stack.addArrangedSubview(refresh)
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
        row.addArrangedSubview(NSTextField(labelWithString: "置顶快捷键"))
        recorder.isEditable = false; recorder.isSelectable = false; recorder.isBezeled = true
        recorder.alignment = .center; recorder.value = shortcut
        recorder.widthAnchor.constraint(equalToConstant: 170).isActive = true
        row.addArrangedSubview(recorder)
        row.addArrangedSubview(NSButton(title: "保存", target: self, action: #selector(save)))
        row.addArrangedSubview(NSButton(title: "默认", target: self, action: #selector(reset)))
        stack.addArrangedSubview(row)
        let hint = NSTextField(wrappingLabelWithString: "点击快捷键框后按新组合，至少含 Control、Option 或 Command。全局注册冲突会提示；无法检测各应用内部自行处理的所有快捷键。")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        resultLabel.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(resultLabel)
        for item in [intro, privacy, hint, resultLabel] { item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        refreshPermissions()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    private func permissionRow(label: NSTextField, title: String, action: Selector) -> NSView {
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
        label.widthAnchor.constraint(equalToConstant: 230).isActive = true
        row.addArrangedSubview(label); row.addArrangedSubview(NSButton(title: title, target: self, action: action))
        return row
    }
    func show(message: String? = nil) {
        refreshPermissions()
        if let message { resultLabel.stringValue = message; resultLabel.textColor = .secondaryLabelColor }
        window?.center(); showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    @objc func refreshPermissions() {
        accessibilityLabel.stringValue = "辅助功能：" + (AXIsProcessTrusted() ? "已允许" : "未允许")
        captureLabel.stringValue = "屏幕录制：" + (CGPreflightScreenCaptureAccess() ? "已允许" : "未允许")
    }
    @objc private func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        openPrivacy("Privacy_Accessibility")
    }
    @objc private func requestCapture() {
        _ = CGRequestScreenCaptureAccess()
        openPrivacy("Privacy_ScreenCapture")
        resultLabel.stringValue = "允许后点击“重新检查权限”；如系统要求，请退出并重新打开“置顶”。"
    }
    private func openPrivacy(_ page: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(page)") { NSWorkspace.shared.open(url) }
    }
    @objc private func save() {
        if let error = onSave?(recorder.value) { resultLabel.stringValue = error; resultLabel.textColor = .systemRed }
        else { resultLabel.stringValue = "已保存：\(recorder.value.label)"; resultLabel.textColor = .secondaryLabelColor }
    }
    @objc private func reset() { recorder.value = .default; save() }
}
