import AppKit
import ScreenCaptureKit
import AVFoundation

// One asynchronous transition at a time. A cancelled start still finishes and is
// stopped before its successor starts. This also makes termination drainable.
@MainActor
final class SerialOperations {
    private var tail: Task<Void, Never>?
    func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { await previous?.value; await work() }
    }
    func drain() async { await tail?.value }
}

final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var stream: SCStream?
    private let queue = DispatchQueue(label: "local.windowpin.frames", qos: .userInitiated)
    private let lock = NSLock()
    private var accepting = true
    private var deliveryPending = false
    var onFrame: ((CMSampleBuffer) -> Void)?
    var onFailure: ((Error) -> Void)?
    private(set) var frames = 0

    @MainActor
    func start(window: SCWindow) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(2, Int(window.frame.width * scale))
        config.height = max(2, Int(window.frame.height * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.ignoreShadowsSingleWindow = true
        if #available(macOS 14.2, *) { config.includeChildWindows = false }
        config.backgroundColor = CGColor.clear
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
    }
    func invalidate() {
        lock.lock(); accepting = false; lock.unlock()
        onFrame = nil; onFailure = nil
    }
    @MainActor
    func stop() async {
        invalidate()
        if let stream {
            do { try await stream.stopCapture() }
            catch { NSLog("WindowPin stopCapture: %@", error.localizedDescription) }
            try? stream.removeStreamOutput(self, type: .screen)
        }
        stream = nil
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let items = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = items.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        lock.lock()
        guard accepting && !deliveryPending else { lock.unlock(); return }
        deliveryPending = true; lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let active = self.accepting; self.deliveryPending = false; self.lock.unlock()
            guard active else { return }
            self.frames += 1
            self.onFrame?(sample)
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }
}

final class MirrorView: NSView {
    let videoLayer = AVSampleBufferDisplayLayer()
    var onClick: (() -> Void)?
    private var clicked = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { clicked = true }
    // Consume the complete click, including mouseUp, before activation. No event
    // is recreated or sent to another process; dragging the mirror is also eaten.
    override func mouseUp(with event: NSEvent) { if clicked { clicked = false; onClick?() } }
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    func display(_ sample: CMSampleBuffer) {
        if videoLayer.status == .failed { videoLayer.flushAndRemoveImage() }
        guard videoLayer.isReadyForMoreMediaData else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let array = attachments as NSArray
            if let first = array.firstObject as? NSMutableDictionary { first[kCMSampleAttachmentKey_DisplayImmediately] = true }
        }
        videoLayer.enqueue(sample)
    }
    func clear() { videoLayer.flushAndRemoveImage() }
}

final class MirrorPanel: NSPanel {
    let mirror = MirrorView(frame: .zero)
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        hidesOnDeactivate = false; isMovable = false; isMovableByWindowBackground = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenNone, .ignoresCycle]
        contentView = mirror
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    func place(_ rect: CGRect) {
        let height = CGDisplayBounds(CGMainDisplayID()).height
        setFrame(WindowIdentity.appKitFrame(rect, primaryHeight: height), display: true)
    }
}
