import Foundation
import CoreGraphics

struct WindowDescriptor {
    let id: UInt32
    let pid: Int32
    let title: String
    let frame: CGRect
}

enum IdentityError: Error, LocalizedError {
    case unavailable, ambiguous, unsupported, permission, changed, timedOut
    var errorDescription: String? {
        switch self {
        case .unavailable: return "无法读取这个窗口。请确认窗口未关闭、未最小化，且已允许辅助功能。"
        case .ambiguous: return "存在无法区分的窗口（位置、尺寸或标题重合）。请将两个窗口分开后重试。"
        case .unsupported: return "只能置顶普通桌面窗口；此窗口不支持准确识别或已进入全屏。"
        case .permission: return "请先在设置中允许辅助功能和屏幕录制，再重试。"
        case .changed: return "选中的窗口已发生变化，请重新选择。"
        case .timedOut: return "读取窗口列表超时，已停止等待。请稍后重试。"
        }
    }
}

enum WindowIdentity {
    static func sameFrame(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX-b.minX) <= tolerance && abs(a.minY-b.minY) <= tolerance &&
        abs(a.width-b.width) <= tolerance && abs(a.height-b.height) <= tolerance
    }
    static func uniqueMatch(pid: Int32, title: String, frame: CGRect,
                            candidates: [WindowDescriptor]) throws -> WindowDescriptor {
        let geometry = candidates.filter { $0.pid == pid && sameFrame($0.frame, frame) }
        // A known mismatching title is never ignored, even when geometry is unique.
        let matches = geometry.filter { title.isEmpty || $0.title.isEmpty || $0.title == title }
        guard !matches.isEmpty else { throw IdentityError.unavailable }
        guard matches.count == 1 else { throw IdentityError.ambiguous }
        return matches[0]
    }
    static func appKitFrame(_ topLeft: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: topLeft.minX, y: primaryHeight-topLeft.maxY, width: topLeft.width, height: topLeft.height)
    }
}
