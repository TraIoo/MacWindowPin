import AppKit
import ApplicationServices
import ScreenCaptureKit
import Carbon

@MainActor
func runDiagnostics() {
    let data: [String: Any] = [
        "system": ProcessInfo.processInfo.operatingSystemVersionString,
        "pid": getpid(), "bundle": Bundle.main.bundleIdentifier ?? "none",
        "frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
        "accessibility": AXIsProcessTrusted(), "screenCapture": CGPreflightScreenCaptureAccess(),
        "displays": NSScreen.screens.count, "activationPolicy": NSApp.activationPolicy().rawValue
    ]
    if let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .prettyPrinted]),
       let text = String(data: json, encoding: .utf8) {
        print(text)
        if let i = CommandLine.arguments.firstIndex(of: "--report"), i+1 < CommandLine.arguments.count {
            try? text.write(toFile: CommandLine.arguments[i+1], atomically: true, encoding: .utf8)
        }
    }
    exit(0)
}

#if WINDOWPIN_TESTING
@MainActor
func renderSettings(path: String) {
    let controller = SettingsController(shortcut: .default)
    guard let view = controller.window?.contentView else { exit(1) }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    do { try data.write(to: URL(fileURLWithPath: path)); print("Rendered settings: \(path)"); exit(0) }
    catch { print(error); exit(1) }
}

@MainActor
func runSelfTests(delegate: AppDelegate) {
    Task {
        var passed = 0
        func check(_ condition: Bool, _ description: String) {
            guard condition else { print("FAIL: \(description)"); exit(1) }
            passed += 1; print("PASS: \(description)")
        }
        let one = HotKey(), two = HotKey()
        let testShortcut = Shortcut(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | cmdKey), keyName: "F19")
        check(one.register(testShortcut) == noErr, "exclusive hotkey registered")
        check(two.register(testShortcut) != noErr, "second exclusive hotkey reports collision")
        one.stop()
        check(two.register(testShortcut) == noErr, "released hotkey can be registered again")
        two.stop()

        let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        var clicks = 0; view.onClick = { clicks += 1 }
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 1,
                                    windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        view.mouseDown(with: down)
        check(clicks == 0, "mirror consumes mouseDown without handoff")
        view.mouseUp(with: up)
        check(clicks == 1, "handoff occurs only after mouseUp")
        view.mouseUp(with: up)
        check(clicks == 1, "orphan mouseUp cannot activate")
        view.rightMouseDown(with: down); view.rightMouseUp(with: up)
        check(clicks == 1, "right click cannot fall through or activate")

        let serial = SerialOperations()
        var order: [Int] = []
        for i in 0..<30 {
            serial.enqueue {
                order.append(i * 2)
                try? await Task.sleep(for: .milliseconds(i % 3))
                order.append(i * 2 + 1)
            }
        }
        await serial.drain()
        check(order == Array(0..<60), "30 asynchronous transitions remain strictly serialized")
        let timeoutStart = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await CallbackDeadline<Int>.run(seconds: 0.04) { _ in }
            check(false, "missing callback must time out")
        } catch IdentityError.timedOut {
            check(ProcessInfo.processInfo.systemUptime-timeoutStart < 0.5, "never-calling framework request stops waiting at deadline")
        } catch { check(false, "expected timeout error") }
        var lateReply: ((Result<Int, Error>) -> Void)?
        do {
            _ = try await CallbackDeadline<Int>.run(seconds: 0.04) { lateReply = $0 }
        } catch {}
        lateReply?(.success(7)); lateReply?(.failure(IdentityError.unavailable)); lateReply = nil
        check(true, "late and duplicate replies cannot resume a completed wait")
        do {
            let value = try await CallbackDeadline<Int>.run(seconds: 0.04) { $0(.success(42)) }
            try? await Task.sleep(for: .milliseconds(70))
            check(value == 42, "successful callback wins and its later deadline is harmless")
        } catch { check(false, "successful callback unexpectedly failed") }
        var selectionGeneration = 0, applied = 0, cleanupRan = false
        let draining = SerialOperations()
        draining.enqueue {
            let generation = selectionGeneration
            _ = try? await CallbackDeadline<Int>.run(seconds: 0.06) { _ in }
            if selectionGeneration == generation { applied += 1 }
        }
        try? await Task.sleep(for: .milliseconds(10))
        selectionGeneration += 1
        draining.enqueue { cleanupRan = true }
        await draining.drain()
        check(cleanupRan && applied == 0, "cancelled selection cannot apply and cleanup drains after missing callback")
        let controller = delegate.controller
        for _ in 0..<30 { controller.cancel() }
        await controller.drain()
        check(controller.resourceSummary == "mode=idle target=0 stream=0 panel=0 timer=0 observers=0 ax=0", "idle cancellation is idempotent and resource-free")
        print("SELF_TEST_COMPLETE \(passed) checks")
        print("GUI cross-application input and real capture are NOT covered by these checks.")
        exit(0)
    }
}

#endif
