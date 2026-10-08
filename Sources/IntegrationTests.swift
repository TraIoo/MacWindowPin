#if WINDOWPIN_TESTING
import AppKit
import ScreenCaptureKit

@MainActor
func runIntegrationTests(delegate: AppDelegate, directory: URL) {
    Task {
        var lines: [String] = []
        func record(_ text: String) {
            print(text); lines.append(text)
            try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("integration-results.log"), atomically: true, encoding: .utf8)
        }
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            record("BLOCKED: Accessibility=\(AXIsProcessTrusted()) ScreenCapture=\(CGPreflightScreenCaptureAccess()). Grant both to this app, then rerun.")
            exit(2)
        }
        var sequence = Int(Date().timeIntervalSince1970 * 1000)
        func waitUntil(_ check: @escaping () -> Bool, timeout: Double = 8) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if check() { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }
        func status(in folder: URL? = nil) -> [String: Any]? {
            guard let data = try? Data(contentsOf: (folder ?? directory).appendingPathComponent("fixture-status.json")) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        func command(_ action: String, in folder: URL? = nil, pid: Int32? = nil) async throws {
            sequence += 1
            var body: [String: Any] = ["sequence": sequence, "action": action]
            if let pid { body["pid"] = pid }
            let json = try JSONSerialization.data(withJSONObject: body)
            try json.write(to: (folder ?? directory).appendingPathComponent("fixture-command.json"), options: .atomic)
            let expected = sequence
            guard await waitUntil({ status(in: folder)?["sequence"] as? Int == expected }, timeout: 3) else { throw TestError("fixture command \(action) timed out") }
            try? await Task.sleep(for: .milliseconds(300))
        }
        func check(_ result: Bool, _ label: String) throws {
            guard result else { throw TestError(label) }
            record("PASS: \(label)")
        }
        let controller = delegate.controller
        var capturedError: String?
        controller.onError = { capturedError = $0 }
        do {
            guard let pid = status()?["pid"] as? Int32,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "local.jc.WindowPinFixture",
                  let ids = status()?["windowIDs"] as? [UInt32], ids.count == 2 else {
                throw TestError("Fixture is not running; run Scripts/integration-test.sh.")
            }
            record("RUN: macOS=\(ProcessInfo.processInfo.operatingSystemVersionString) fixturePID=\(pid)")
            @MainActor func target(_ index: Int) async throws -> PinnedTarget {
                let content = try await WindowResolver.content()
                guard let window = content.windows.first(where: { $0.windowID == ids[index] && $0.owningApplication?.processID == pid }) else {
                    throw TestError("fixture window not available")
                }
                return try WindowResolver.resolve(window)
            }
            let a = try await target(0), b = try await target(1)
            try check(a.id != b.id && !CFEqual(a.window, b.window), "real same-title windows resolve to different AX objects and IDs")
            try await command("overlap")
            do { _ = try await target(0); throw TestError("overlap was accepted") }
            catch IdentityError.ambiguous { record("PASS: real same-title overlapping windows rejected") }
            try await command("separate")
            try await command("frontA")
            controller.pin(a)
            try check(await waitUntil({ controller.mode == .mirroring }), "real window stream delivered first frame")
            try check((controller.capture?.frames ?? 0) > 0, "ScreenCaptureKit complete frames received")
            try await command("sheetA")
            try check(await waitUntil({ controller.mode == .interactive }), "attached sheet hides initial mirror without a prior handoff")
            try await command("dismissSheet")
            controller.cancel(); await controller.drain(); controller.pin(a)
            try check(await waitUntil({ controller.mode == .mirroring }), "mirror restored for handoff test")
            controller.handOff()
            try check(await waitUntil({ controller.mode == .interactive }), "AX handoff confirms exact focused window")
            await controller.drain()
            try check(controller.capture == nil, "stream stopped while original window is interactive")
            try check(status()?["clicks"] as? Int == 0, "programmatic handoff does not click source button")
            try await command("frontB")
            try check(await waitUntil({ controller.mode == .mirroring }), "same-application focus loss restores mirror")
            try await command("frontA")
            try check(await waitUntil({ controller.mode == .interactive }), "same-application focus regain hides mirror")
            let otherDirectory = directory.appendingPathComponent("app2", isDirectory: true)
            if let otherPID = status(in: otherDirectory)?["pid"] as? Int32,
                NSRunningApplication(processIdentifier: otherPID)?.bundleIdentifier == "local.jc.WindowPinFocusFixture" {
                try await command("yieldTo", pid: otherPID)
                try await command("frontA", in: otherDirectory)
                try check(await waitUntil({ NSWorkspace.shared.frontmostApplication?.processIdentifier == otherPID }), "second fixture actually became active")
                try check(await waitUntil({ controller.mode == .mirroring }), "cross-application focus loss restores mirror")
                try await command("yieldTo", in: otherDirectory, pid: pid)
                controller.handOff()
                try check(await waitUntil({ controller.mode == .interactive }), "cross-application AX handoff confirms focus and hides mirror")
                try await command("quit", in: otherDirectory)
            } else { record("SKIP: second isolated fixture absent; cross-application focus not checked") }
            controller.cancel(); await controller.drain()
            for i in 0..<30 {
                capturedError = nil
                controller.pin(i % 2 == 0 ? a : b)
                let ready = await waitUntil({ controller.mode == .mirroring || capturedError != nil })
                try check(ready && controller.mode == .mirroring, "pin/cancel cycle \(i+1): received frame")
                controller.cancel(); await controller.drain()
                try check(controller.resourceSummary == "mode=idle target=0 stream=0 panel=0 timer=0 observers=0 ax=0", "pin/cancel cycle \(i+1): cleaned all resources")
            }
            for i in 0..<30 {
                controller.pin(i % 2 == 0 ? a : b)
                try? await Task.sleep(for: .milliseconds(10))
            }
            controller.cancel(); await controller.drain()
            try check(controller.resourceSummary == "mode=idle target=0 stream=0 panel=0 timer=0 observers=0 ax=0", "30 rapid replacements drained without resources")
            try await command("frontA")
            controller.pin(a)
            try check(await waitUntil({ controller.mode == .mirroring }), "pre-fullscreen stream ready")
            try await command("fullscreenA")
            try check(await waitUntil({ !controller.isPinned }), "native fullscreen or Space transition cancels pin")
            await controller.drain()
            try check(await waitUntil({ AX.bool(a.window, "AXFullScreen") }), "fixture actually entered native fullscreen")
            try? await Task.sleep(for: .seconds(1.5))
            try await command("fullscreenA")
            try check(await waitUntil({ !AX.bool(a.window, "AXFullScreen") }), "fixture returned from native fullscreen")
            try? await Task.sleep(for: .seconds(1.5))
            controller.pin(a)
            try check(await waitUntil({ controller.mode == .mirroring }), "pre-minimize stream ready")
            try await command("minimizeA")
            try check(await waitUntil({ !controller.isPinned }), "minimization cancels pin")
            await controller.drain(); try await command("restoreA"); try await command("frontA")
            controller.pin(try await target(0))
            try check(await waitUntil({ controller.mode == .mirroring }), "pre-hide stream ready")
            try await command("hide")
            try check(await waitUntil({ !controller.isPinned }), "application hiding cancels pin")
            await controller.drain(); try await command("frontA")
            controller.pin(try await target(0))
            try check(await waitUntil({ controller.mode == .mirroring }), "pre-close stream ready")
            try await command("closeA")
            try check(await waitUntil({ !controller.isPinned }), "source window closing cancels pin")
            await controller.drain()
            controller.pin(try await target(1))
            try check(await waitUntil({ controller.mode == .mirroring }), "pre-quit stream ready")
            try await command("quit")
            try check(await waitUntil({ !controller.isPinned }), "source application exit cancels pin")
            await controller.drain()
            record("INTEGRATION_COMPLETE: \(controller.resourceSummary)")
            record("NOT TESTED HERE: real mouse picking/click routing, Chinese IME, third-party apps, manual desktop switching, visual alignment, static/dynamic performance.")
            exit(0)
        } catch {
            record("FAIL: \(error.localizedDescription) captureError=\(capturedError ?? "none") state=\(controller.resourceSummary) reason=\(controller.cancellationReason) frontPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
            controller.cancel(); await controller.drain()
            record("CLEANUP: \(controller.resourceSummary)")
            exit(1)
        }
    }
}

struct TestError: Error, LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

#endif
