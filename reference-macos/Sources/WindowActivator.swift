import Cocoa
import ApplicationServices

// 특정 창을 앞으로 꺼내는 담당 — 다른 모니터의 같은 앱 창은 최대한 안 건드림
enum WindowActivator {

    // 창 하나만 지정해서 앞으로.
    // targetWindowID: CGWindowList의 windowID
    //
    // v0.1.3 (A안 — activate() 완전 제거, SLPS 단독):
    // - NSRunningApplication.activate()는 앱을 프론트로 만들면서 macOS가
    //   "각 모니터별 최상단 창"을 z-order상 앞으로 올린다. 모니터마다 z-스택이
    //   따로 놀기 때문에, 우리가 클릭한 모니터의 창만 raise해도 옆 모니터의
    //   같은 앱 창은 이미 앞으로 나와버린다(신호등 회색 = 포커스 없이 z-order만).
    // - _SLPSSetFrontProcessWithOptions는 이름대로 "프론트 프로세스 설정"을
    //   하면서 windowID를 지목한다 → activate() 없이도 앱이 앞으로 오고,
    //   지목한 그 창 하나만 올라온다. activate의 모니터별 노출 부작용이 사라진다.
    static func raise(pid: pid_t, windowID: CGWindowID) {
        guard Accessibility.isTrusted else {
            Accessibility.showLostPermissionAlert()
            return
        }

        let axApp = AXUIElementCreateApplication(pid)

        // AX 창 목록에서 CGWindowID와 매칭되는 창 찾기
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return }

        var target: AXUIElement?
        for axWin in axWindows {
            if axWindowID(axWin) == windowID {
                target = axWin
                break
            }
        }
        // 매칭 실패 시 조용히 종료 (엉뚱한 창 raise 방지)
        guard let win = target else { return }

        // 최소화 상태면 복원
        if isMinimized(win) {
            AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        // 1) ★ SLPS 단독 — 프론트 프로세스 설정 + 이 창 하나만 raise.
        //    activate()를 안 부르므로 옆 모니터 같은 앱 창은 그대로 뒤에 있음.
        PrivateAPI.raiseWindow(pid: pid, windowID: windowID)
        // 2) AX 레벨 raise (앱 내부 z-order 확정) + 키보드 포커스 지정
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    // 특정 앱의 특정 모니터 창 중 최상단(최근 사용) 창 하나를 앞으로
    static func raiseTopWindow(pid: pid_t, in windows: [WindowRef]) {
        guard let top = windows.first else { return }
        raise(pid: pid, windowID: top.windowID)
    }

    // MARK: - AX 헬퍼

    // AX 창의 _AXUIElementGetWindow로 CGWindowID를 얻는다
    // 이 함수는 공식 헤더엔 없지만 프레임워크에 export돼 있어 오래전부터 사용 가능
    private static func axWindowID(_ axWindow: AXUIElement) -> CGWindowID {
        var wid: CGWindowID = 0
        _ = _AXUIElementGetWindow(axWindow, &wid)
        return wid
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &ref) == .success,
              let value = ref as? Bool else { return false }
        return value
    }
}

// 프라이빗 AX API — 창 CGWindowID 조회
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

// 손쉬운 사용 권한 상태 확인 + 사용자 안내 (SubDock에서 이식)
enum Accessibility {

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func showLostPermissionAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = Lang.t("손쉬운 사용 권한이 필요해요",
                                       "Accessibility permission needed")
            alert.informativeText = Lang.t(
                "창을 앞으로 꺼내려면 ‘손쉬운 사용’ 권한이 필요합니다.\n목록에 켜져 있어 보여도 재부팅·업데이트·절전 같은 시스템 이벤트로 무효화됐을 수 있어요.\n\n복구법:\n1) 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 에서\n   IndexTab을 ‘–’로 제거한 뒤 ‘+’로 다시 추가하고 켜기\n2) 그다음 메뉴에서 ‘IndexTab 재시작’",
                "IndexTab needs Accessibility permission to raise windows.\nEven if it appears enabled, it may have been invalidated by a system event.\n\nReliable fix:\n1) System Settings → Privacy & Security → Accessibility —\n   remove IndexTab with ‘–’, then add it again with ‘+’ and turn it on\n2) Then choose ‘Restart IndexTab’ from the menu"
            )
            alert.addButton(withTitle: Lang.t("손쉬운 사용 열기", "Open Accessibility Settings"))
            alert.addButton(withTitle: Lang.t("닫기", "Close"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                openSettings()
            }
        }
    }
}
