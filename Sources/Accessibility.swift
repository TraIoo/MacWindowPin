import AppKit
import ApplicationServices
import ScreenCaptureKit

enum AX {
    // Per-app timeouts are not inherited by AX window/child objects. Set the
    // process default so an unresponsive target cannot use the long OS default.
    private static let timeoutConfigured: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
    }()
    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        _ = timeoutConfigured
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = value(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    static func string(_ e: AXUIElement, _ name: String) -> String { value(e, name) as? String ?? "" }
    static func bool(_ e: AXUIElement, _ name: String) -> Bool { value(e, name) as? Bool ?? false }
    static func windows(_ app: AXUIElement) -> [AXUIElement] { value(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] }
    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = value(e, kAXPositionAttribute), let s = value(e, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
              size.width > 1, size.height > 1 else { return nil }
        return CGRect(origin: point, size: size)
    }
    static func app(_ pid: pid_t) -> AXUIElement {
        _ = timeoutConfigured
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        return app
    }
    static func standard(_ window: AXUIElement) -> Bool {
        string(window, kAXRoleAttribute) == kAXWindowRole &&
        string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole &&
        !bool(window, kAXMinimizedAttribute) && !bool(window, "AXFullScreen")
    }
    static func frontWindow() throws -> AXSelection {
        guard AXIsProcessTrusted() else { throw IdentityError.permission }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != getpid(), front.activationPolicy == .regular else { throw IdentityError.unsupported }
        let app = app(front.processIdentifier)
        guard let window = element(app, kAXFocusedWindowAttribute), standard(window), let frame = frame(window) else {
            throw IdentityError.unsupported
        }
        return AXSelection(pid: front.processIdentifier, window: window,
                           title: string(window, kAXTitleAttribute), frame: frame)
    }
}

struct AXSelection {
    let pid: pid_t
    let window: AXUIElement
    let title: String
    let frame: CGRect
}

struct PinnedTarget {
    let id: CGWindowID
    let pid: pid_t
    let window: AXUIElement
    let app: AXUIElement
    let name: String
    var title: String { AX.string(window, kAXTitleAttribute) }
}

@MainActor
enum WindowResolver {
    static func content() async throws -> SCShareableContent {
        try await CallbackDeadline<SCShareableContent>.run(seconds: 8) { reply in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                if let content { reply(.success(content)) }
                else { reply(.failure(error ?? IdentityError.unavailable)) }
            }
        }
    }
    static func eligible(_ content: SCShareableContent) -> [SCWindow] {
        content.windows.filter {
            guard let owner = $0.owningApplication,
                  owner.processID != getpid(), $0.windowLayer == 0, $0.isOnScreen,
                  $0.frame.width > 30, $0.frame.height > 30,
                  let app = NSRunningApplication(processIdentifier: owner.processID) else { return false }
            return app.activationPolicy == .regular && !app.isHidden
        }
    }
    static func descriptors(_ windows: [SCWindow]) -> [WindowDescriptor] {
        windows.compactMap { w in
            guard let pid = w.owningApplication?.processID else { return nil }
            return WindowDescriptor(id: w.windowID, pid: pid, title: w.title ?? "", frame: w.frame)
        }
    }
    static func resolve(_ selection: AXSelection, content: SCShareableContent) throws -> (PinnedTarget, SCWindow) {
        guard AX.standard(selection.window), let current = AX.frame(selection.window),
              WindowIdentity.sameFrame(current, selection.frame),
              AX.string(selection.window, kAXTitleAttribute) == selection.title else { throw IdentityError.changed }
        let windows = eligible(content)
        let match = try WindowIdentity.uniqueMatch(pid: selection.pid, title: selection.title,
                                                    frame: current, candidates: descriptors(windows))
        guard let sc = windows.first(where: { $0.windowID == match.id }) else { throw IdentityError.unavailable }
        let target = try resolve(sc)
        guard CFEqual(target.window, selection.window) else { throw IdentityError.ambiguous }
        return (target, sc)
    }
    static func resolve(_ sc: SCWindow) throws -> PinnedTarget {
        guard AXIsProcessTrusted(), let owner = sc.owningApplication,
              owner.processID != getpid() else { throw IdentityError.permission }
        let app = AX.app(owner.processID)
        let candidates = AX.windows(app).filter { w in
            guard AX.standard(w), let frame = AX.frame(w), WindowIdentity.sameFrame(frame, sc.frame) else { return false }
            let title = AX.string(w, kAXTitleAttribute)
            return title.isEmpty || (sc.title ?? "").isEmpty || title == sc.title
        }
        guard !candidates.isEmpty else { throw IdentityError.unsupported }
        guard candidates.count == 1 else { throw IdentityError.ambiguous }
        return PinnedTarget(id: sc.windowID, pid: owner.processID, window: candidates[0], app: app, name: owner.applicationName)
    }
    static func revalidate(_ target: PinnedTarget, content: SCShareableContent) throws -> SCWindow {
        guard let frame = AX.frame(target.window), AX.standard(target.window),
              AX.windows(target.app).contains(where: { CFEqual($0, target.window) }) else { throw IdentityError.unavailable }
        let match = try WindowIdentity.uniqueMatch(pid: target.pid, title: target.title, frame: frame,
                                                   candidates: descriptors(eligible(content)))
        guard match.id == target.id else { throw IdentityError.changed }
        let sc = eligible(content).first { $0.windowID == target.id }!
        guard CFEqual(try resolve(sc).window, target.window) else { throw IdentityError.ambiguous }
        return sc
    }
}

// The framework request itself has no cancellation API. Bound only our wait,
// release its continuation once, and ignore any result arriving afterwards.
// A task-group race would still wait for an uncooperative child on group exit.
final class CallbackDeadline<Value> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var deadline: DispatchWorkItem?
    private init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    static func run(seconds: Double, start: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let request = CallbackDeadline(continuation)
            let timeout = DispatchWorkItem { request.finish(.failure(IdentityError.timedOut)) }
            request.deadline = timeout
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now()+seconds, execute: timeout)
            start { request.finish($0) }
        }
    }
    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let continuation = self.continuation, deadline = self.deadline
        self.continuation = nil; self.deadline = nil
        lock.unlock()
        deadline?.cancel()
        continuation?.resume(with: result)
    }
}

final class AXWatch {
    private var observer: AXObserver?
    private var registrations: [(AXUIElement, String)] = []
    var onChange: ((String) -> Void)?
    private(set) var unsupported: [String] = []

    init(target: PinnedTarget, onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        var obs: AXObserver?
        let result = AXObserverCreate(target.pid, { _, _, name, context in
            guard let context else { return }
            let watch = Unmanaged<AXWatch>.fromOpaque(context).takeUnretainedValue()
            watch.onChange?(name as String)
        }, &obs)
        guard result == .success, let obs else { unsupported = ["AXObserverCreate: \(result.rawValue)"]; return }
        observer = obs
        let pairs: [(AXUIElement, String)] = [
            (target.app, kAXFocusedWindowChangedNotification), (target.app, kAXFocusedUIElementChangedNotification),
            (target.app, kAXWindowCreatedNotification), (target.window, kAXUIElementDestroyedNotification),
            (target.window, kAXWindowMiniaturizedNotification), (target.window, kAXMovedNotification),
            (target.window, kAXResizedNotification), (target.window, kAXTitleChangedNotification)
        ]
        for (element, name) in pairs {
            let error = AXObserverAddNotification(obs, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
            if error == .success { registrations.append((element, name)) }
            else { unsupported.append("\(name): \(error.rawValue)") }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
    }
    func stop() {
        onChange = nil
        if let observer {
            for (element, name) in registrations { AXObserverRemoveNotification(observer, element, name as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil; registrations.removeAll()
    }
    deinit { stop() }
}
