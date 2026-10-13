import Foundation
import ApplicationServices
import CoreGraphics

/// Private symbols, resolved at runtime with dlsym. Every one is optional so a
/// missing symbol disables a feature instead of failing to launch.
enum PrivateAPI {
    private static let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let hiservices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)

    private static func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
        guard let h = handle ?? dlopen(nil, RTLD_LAZY), let p = dlsym(h, name) else {
            Log.info("private symbol missing: \(name)")
            return nil
        }
        return unsafeBitCast(p, to: type)
    }

    // MARK: Accessibility

    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let axGetWindow = sym(hiservices, "_AXUIElementGetWindow", as: AXGetWindowFn.self)

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let fn = axGetWindow else { return nil }
        var wid: CGWindowID = 0
        return fn(element, &wid) == .success && wid != 0 ? wid : nil
    }

    // MARK: Spaces (CGS / SkyLight)

    typealias CGSConnectionID = Int32
    private typealias MainConnFn = @convention(c) () -> CGSConnectionID
    private static let mainConnection = sym(skylight, "CGSMainConnectionID", as: MainConnFn.self)
    static let connection: CGSConnectionID? = mainConnection?()

    private typealias SpacesForWindowsFn = @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
    private static let spacesForWindows = sym(skylight, "CGSCopySpacesForWindows", as: SpacesForWindowsFn.self)

    static func spaces(for windowID: CGWindowID) -> [UInt64] {
        guard let cid = connection, let fn = spacesForWindows else { return [] }
        let arr = [NSNumber(value: windowID)] as CFArray
        guard let out = fn(cid, 0x7, arr)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return out.map { $0.uint64Value }
    }

    private typealias ActiveSpaceFn = @convention(c) (CGSConnectionID) -> UInt64
    private static let getActiveSpace = sym(skylight, "CGSGetActiveSpace", as: ActiveSpaceFn.self)

    static var activeSpace: UInt64? {
        guard let cid = connection, let fn = getActiveSpace else { return nil }
        return fn(cid)
    }

    private typealias ManagedDisplaySpacesFn = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
    private static let managedDisplaySpaces = sym(skylight, "CGSCopyManagedDisplaySpaces", as: ManagedDisplaySpacesFn.self)

    /// The current Space on every display.
    static var currentSpacesOnAllDisplays: Set<UInt64> {
        guard let cid = connection, let fn = managedDisplaySpaces,
              let displays = fn(cid)?.takeRetainedValue() as? [[String: Any]] else {
            return activeSpace.map { [$0] } ?? []
        }
        var out = Set<UInt64>()
        for d in displays {
            if let cur = d["Current Space"] as? [String: Any],
               let id = (cur["ManagedSpaceID"] as? NSNumber) ?? (cur["id64"] as? NSNumber) {
                out.insert(id.uint64Value)
            }
        }
        if let a = activeSpace { out.insert(a) }
        return out
    }

    // MARK: Symbolic hot keys (native ⌘-Tab)

    enum SymbolicHotKey: Int32 {
        case commandTab = 1, commandShiftTab = 2, commandGrave = 6, commandShiftGrave = 7
    }
    private typealias SetHotKeyFn = @convention(c) (Int32, Bool) -> CGError
    private static let setSymbolicHotKey = sym(skylight, "CGSSetSymbolicHotKeyEnabled", as: SetHotKeyFn.self)

    @discardableResult
    static func setNativeSwitcher(enabled: Bool) -> Bool {
        guard let fn = setSymbolicHotKey else { return false }
        var ok = true
        for k in [SymbolicHotKey.commandTab, .commandShiftTab] {
            ok = fn(k.rawValue, enabled) == .success && ok
        }
        return ok
    }

    // MARK: Front process / key window (focus without a Space-switch flicker)

    private typealias SetFrontFn = @convention(c) (UnsafeRawPointer, CGWindowID, UInt32) -> CGError
    private static let setFrontProcess = sym(skylight, "_SLPSSetFrontProcessWithOptions", as: SetFrontFn.self)
    private typealias PostEventFn = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt8>) -> CGError
    private static let postEventRecord = sym(skylight, "SLPSPostEventRecordTo", as: PostEventFn.self)
    private typealias GetPSNFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> OSStatus
    private static let getProcessForPID = sym(nil, "GetProcessForPID", as: GetPSNFn.self)

    /// AltTab's trick: tell the window server which window should become key
    /// before activating the app, so the right window comes forward.
    static func makeKeyWindow(pid: pid_t, windowID: CGWindowID) {
        guard let setFront = setFrontProcess, let post = postEventRecord, let getPSN = getProcessForPID else { return }
        var psn = (UInt32(0), UInt32(0))
        guard getPSN(pid, &psn) == noErr else { return }
        _ = withUnsafePointer(to: &psn) { setFront(UnsafeRawPointer($0), windowID, 0x200) }
        for kind: UInt8 in [0x01, 0x02] {
            var bytes = [UInt8](repeating: 0, count: 0xf8)
            bytes[0x04] = 0xf8
            bytes[0x08] = kind
            bytes[0x3a] = 0x10
            bytes.replaceSubrange(0x20..<0x30, with: [UInt8](repeating: 0xFF, count: 0x10))
            withUnsafeBytes(of: windowID.littleEndian) { w in
                bytes.replaceSubrange(0x3c..<0x40, with: w)
            }
            withUnsafePointer(to: &psn) { p in
                bytes.withUnsafeBufferPointer { b in _ = post(UnsafeRawPointer(p), b.baseAddress!) }
            }
        }
    }
}

enum Log {
    static func info(_ s: @autoclosure () -> String) {
        #if DEBUG
        print("[flit] \(s())")
        #else
        if ProcessInfo.processInfo.environment["FLIT_VERBOSE"] != nil { print("[flit] \(s())") }
        #endif
    }
}
