import Cocoa
import ApplicationServices

// SkyLight(구 CoreGraphics WindowServer) 비공개 API 바인딩.
//
// 왜 필요한가:
//   공개 API인 NSRunningApplication.activate()는 "앱"을 프론트로 만든다.
//   그러면 macOS가 그 앱의 "각 모니터별 최상단 창"을 전부 앞으로 노출시킨다.
//   → 같은 앱(크롬 등)이 여러 모니터에 있으면 클릭 하나에 다 튀어나오는 문제.
//
//   _SLPSSetFrontProcessWithOptions는 "창 ID"를 직접 인자로 받아서
//   그 창 하나만 프론트로 만든다. 다른 모니터의 같은 앱 창은 건드리지 않는다.
//
// 이 기법은 yabai(MIT), AltTab 등 여러 오픈소스에 공개된 공지의 기술이다.
// dlsym으로 런타임 바인딩 → 링커 플래그/브리징 헤더 불필요.
enum PrivateAPI {

    private static let skyLight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    // RTLD_DEFAULT (-2) — 이미 로드된 심볼 검색 (HIServices, Carbon 등)
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    private static func sym<T>(_ name: String, _ handle: UnsafeMutableRawPointer?) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    // pid → ProcessSerialNumber (10.9 이후 deprecated라 Swift 임포터가 숨김 → dlsym)
    private static let getProcessForPIDFn: (@convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus)? =
        sym("GetProcessForPID", rtldDefault)

    // (psn, windowID, mode) → 특정 창을 프론트로. mode 2 = userGenerated
    private static let setFrontProcFn: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, Int32) -> CGError)? =
        sym("_SLPSSetFrontProcessWithOptions", skyLight)

    // (psn, eventBytes) → 합성 이벤트로 raise 확정 (없으면 일부 창이 뒤에 묻힘)
    private static let postEventFn: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError)? =
        sym("SLPSPostEventRecordTo", skyLight)

    /// 특정 창 하나만 프론트로 raise. windowID를 직접 지목하므로
    /// 같은 앱의 다른 모니터 창은 건드리지 않는다.
    /// 두 SLPS 호출이 모두 성공하면 true.
    @discardableResult
    static func raiseWindow(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard windowID != 0 else { return false }
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        guard let getPSN = getProcessForPIDFn, getPSN(pid, &psn) == noErr else { return false }
        guard let setFront = setFrontProcFn, let postEvent = postEventFn else { return false }

        // 이 창을 프론트 프로세스의 최상단 창으로 지정
        let setErr = setFront(&psn, windowID, 2)

        // 윈도우서버가 raise를 확정하도록 합성 이벤트 전송.
        // 바이트 레이아웃은 SkyLight가 기대하는 고정 포맷 (yabai/AltTab 등과 동일).
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x08] = 0x0d
        bytes[0x3a] = 0x80
        var widLE = windowID
        withUnsafeBytes(of: &widLE) { src in
            for i in 0..<4 { bytes[0x3c + i] = src[i] }
        }
        bytes[0x20] = 0x02
        let postErr = bytes.withUnsafeMutableBufferPointer { buf -> CGError in
            postEvent(&psn, buf.baseAddress!)
        }
        return setErr == .success && postErr == .success
    }

    /// dlsym 심볼이 다 잡혔는지 시작 시 1회 진단용. 못 잡은 심볼 이름 배열 반환.
    static func selfCheck() -> [String] {
        var missing: [String] = []
        if getProcessForPIDFn == nil { missing.append("GetProcessForPID") }
        if setFrontProcFn == nil { missing.append("_SLPSSetFrontProcessWithOptions") }
        if postEventFn == nil { missing.append("SLPSPostEventRecordTo") }
        return missing
    }
}
