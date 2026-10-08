import Foundation
import CoreGraphics

@main
struct IdentityTests {
    static func main() throws {
        var checks = 0
        func expect(_ test: @autoclosure () -> Bool, _ name: String) {
            guard test() else { fatalError("FAIL: \(name)") }
            checks += 1; print("PASS: \(name)")
        }
        let a = WindowDescriptor(id: 10, pid: 42, title: "相同标题", frame: CGRect(x: 10, y: 20, width: 640, height: 480))
        let b = WindowDescriptor(id: 11, pid: 42, title: "相同标题", frame: CGRect(x: 700, y: 20, width: 640, height: 480))
        let foreign = WindowDescriptor(id: 12, pid: 99, title: a.title, frame: a.frame)
        let matched = try WindowIdentity.uniqueMatch(pid: 42, title: a.title, frame: a.frame, candidates: [foreign, b, a])
        expect(matched.id == 10, "same-title windows distinguished by geometry and PID")
        let overlap = WindowDescriptor(id: 13, pid: 42, title: a.title, frame: a.frame)
        do {
            _ = try WindowIdentity.uniqueMatch(pid: 42, title: a.title, frame: a.frame, candidates: [a, overlap])
            fatalError("ambiguous windows accepted")
        } catch IdentityError.ambiguous { checks += 1; print("PASS: identical overlapping windows rejected") }
        do {
            _ = try WindowIdentity.uniqueMatch(pid: 42, title: "different", frame: a.frame, candidates: [a])
            fatalError("mismatched title accepted")
        } catch IdentityError.unavailable { checks += 1; print("PASS: mismatched title rejected") }
        let missing = WindowDescriptor(id: 15, pid: 42, title: "", frame: a.frame)
        do {
            _ = try WindowIdentity.uniqueMatch(pid: 42, title: a.title, frame: a.frame, candidates: [a, missing])
            fatalError("unknown duplicate accepted")
        } catch IdentityError.ambiguous { checks += 1; print("PASS: missing-title duplicate rejected") }
        expect(WindowIdentity.sameFrame(a.frame, a.frame.offsetBy(dx: 1, dy: 1)), "rounding tolerance")
        expect(!WindowIdentity.sameFrame(a.frame, a.frame.offsetBy(dx: 3, dy: 0)), "moved window fails matching")
        let transformed = WindowIdentity.appKitFrame(CGRect(x: -500, y: -300, width: 400, height: 200), primaryHeight: 900)
        expect(transformed == CGRect(x: -500, y: 1000, width: 400, height: 200), "multi-display negative origin conversion")
        print("IDENTITY_TEST_COMPLETE \(checks) checks")
    }
}
