#if WINDOWPIN_TESTING
import AppKit
import ScreenCaptureKit

@MainActor
func runPerformanceTests(delegate: AppDelegate, directory: URL) {
    Task {
        let controller = delegate.controller
        var failure: String?
        controller.onError = { failure = $0 }
        var records: [String] = []
        func record(_ text: String) {
            records.append(text)
            try? records.joined(separator: "\n").write(to: directory.appendingPathComponent("performance-results.log"), atomically: true, encoding: .utf8)
        }
        @MainActor func sample(_ phase: String) async throws {
            record("BEGIN \(phase): \(controller.resourceSummary)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            let project = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            process.arguments = [project.appendingPathComponent("Scripts/sample-performance.py").path, phase, "30"]
            let result: Int32 = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
            guard result == 0 else { throw TestError("performance sampler failed") }
            if let failure { throw TestError(failure) }
            record("END \(phase): \(controller.resourceSummary) frames=\(controller.capture?.frames ?? 0)")
        }
        do {
            guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else { throw IdentityError.permission }
            let data = try Data(contentsOf: directory.appendingPathComponent("fixture-status.json"))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int32,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "local.jc.WindowPinFixture",
                  let ids = json["windowIDs"] as? [UInt32], let id = ids.first else { throw TestError("fixture missing") }
            let content = try await WindowResolver.content()
            guard let window = content.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID == pid }) else {
                throw TestError("fixture window unavailable")
            }
            let target = try WindowResolver.resolve(window)
            record("Capture geometry: \(window.frame) points; display scale \(SCContentFilter(desktopIndependentWindow: window).pointPixelScale)")
            try await sample("idle")
            controller.pin(target)
            for _ in 0..<80 {
                if controller.mode == .mirroring { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard controller.mode == .mirroring else { throw TestError("mirror failed before performance test") }
            try await sample("static")
            let sequence = Int(Date().timeIntervalSince1970 * 1000)
            func command(_ action: String, sequence: Int) throws {
                let data = try JSONSerialization.data(withJSONObject: ["sequence": sequence, "action": action])
                try data.write(to: directory.appendingPathComponent("fixture-command.json"), options: .atomic)
            }
            try command("dynamic", sequence: sequence)
            try await Task.sleep(for: .milliseconds(400))
            try await sample("dynamic")
            try command("static", sequence: sequence+1)
            controller.cancel(); await controller.drain()
            try await sample("after-cancel")
            record("PERFORMANCE_COMPLETE: \(controller.resourceSummary)")
            // Quit with an actual live stream, and leave the disposable source
            // running so the caller can verify quitting never closes its app.
            controller.pin(target)
            for _ in 0..<80 {
                if controller.mode == .mirroring { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard controller.mode == .mirroring else { throw TestError("pre-quit mirror failed") }
            record("QUIT_WITH_ACTIVE_CAPTURE: \(controller.resourceSummary); sourcePID=\(pid)")
            NSApp.terminate(nil)
        } catch {
            record("FAIL: \(error.localizedDescription)")
            controller.cancel(); await controller.drain(); NSApp.terminate(nil)
        }
    }
}

#endif
