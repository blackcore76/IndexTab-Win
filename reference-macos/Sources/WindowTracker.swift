import Cocoa
import ApplicationServices

// 한 앱의 특정 모니터 상 상태
struct AppOnScreen {
    let bundleID: String
    let name: String
    let icon: NSImage?
    let windows: [WindowRef]      // 이 모니터에 위치한 창 목록 (z-order 상단 순)
    var lastActivated: Date       // 최근 활성화 시각 (정렬용)
}

// 창 하나에 대한 참조 정보
struct WindowRef {
    let windowID: CGWindowID      // CGWindowList의 kCGWindowNumber
    let title: String             // 창 제목 (Chrome이면 활성 탭 제목)
    let pid: pid_t
    let frame: CGRect             // 전역 좌표
}

// 각 모니터의 앱 목록 스냅샷
struct MonitorSnapshot {
    let displayID: CGDirectDisplayID
    let apps: [AppOnScreen]       // 최근 활성화 순 (최대 N개)
}

// 창-모니터 매핑을 주기적으로 갱신하는 트래커
class WindowTracker {

    var onUpdate: (([MonitorSnapshot]) -> Void)?

    private var timer: Timer?
    private var lastActivatedMap: [String: Date] = [:]  // "displayID:bundleID" → 마지막 활성 시각

    func start() {
        // 즉시 1회 갱신 후 주기 폴링
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // 특정 앱이 특정 모니터에서 활성화됐다고 마킹 (사용자 클릭 직후 즉시 반영용)
    func markActivated(bundleID: String, displayID: CGDirectDisplayID) {
        let key = "\(displayID):\(bundleID)"
        lastActivatedMap[key] = Date()
    }

    private func refresh() {
        let snapshots = buildSnapshots()
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(snapshots)
        }
    }

    private func buildSnapshots() -> [MonitorSnapshot] {
        // 1. 모든 화면 창 정보 수집 (z-order 순)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let myBundleID = Bundle.main.bundleIdentifier ?? ""

        // 2. 각 창을 WindowRef로 변환하면서 화면별로 그룹핑
        // (pid → NSRunningApplication) 캐시
        var appCache: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            appCache[app.processIdentifier] = app
        }

        // displayID → bundleID → [WindowRef]
        var perDisplay: [CGDirectDisplayID: [String: [WindowRef]]] = [:]
        var appMeta: [String: (name: String, icon: NSImage?)] = [:]

        // pid별 AX 창 제목 캐시 (한 번의 스냅샷 내에서만). kCGWindowName은 화면기록
        // 권한이 없으면 비므로, 이미 가진 손쉬운 사용 권한으로 AX 제목을 우선 사용.
        var axTitleCache: [pid_t: [CGWindowID: String]] = [:]
        func axTitle(pid: pid_t, wid: CGWindowID) -> String? {
            if axTitleCache[pid] == nil { axTitleCache[pid] = fetchAXTitles(pid: pid) }
            return axTitleCache[pid]?[wid]
        }

        for info in windowInfoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPID else { continue }
            guard let app = appCache[pid] else { continue }
            guard app.activationPolicy == .regular else { continue }
            guard let bundleID = app.bundleIdentifier, bundleID != myBundleID else { continue }

            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let frame = CGRect(x: boundsDict["X"] ?? 0,
                               y: boundsDict["Y"] ?? 0,
                               width: boundsDict["Width"] ?? 0,
                               height: boundsDict["Height"] ?? 0)

            // 너무 작은 창(툴팁 등)은 무시
            if frame.width < 60 || frame.height < 40 { continue }

            // AX 제목 우선, 없으면 kCGWindowName, 그것도 없으면 cleanTitle이 "(제목없음)"으로
            let axName = axTitle(pid: pid, wid: windowID)
            let cgName = (info[kCGWindowName as String] as? String) ?? ""
            let rawTitle = (axName?.isEmpty == false) ? axName! : cgName

            // 창의 중심이 어느 모니터에 있는지 판별
            guard let screen = screen(containing: CGPoint(x: frame.midX, y: frame.midY)) else { continue }
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }

            let ref = WindowRef(windowID: windowID, title: cleanTitle(rawTitle, bundleID: bundleID), pid: pid, frame: frame)

            perDisplay[displayID, default: [:]][bundleID, default: []].append(ref)

            if appMeta[bundleID] == nil {
                appMeta[bundleID] = (app.localizedName ?? bundleID, app.icon)
            }
        }

        // 3. 각 모니터별로 AppOnScreen 배열 만들고 최근 사용순 정렬 후 최대 N개 자름
        var result: [MonitorSnapshot] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let bundleMap = perDisplay[displayID] ?? [:]

            var apps: [AppOnScreen] = []
            for (bundleID, windows) in bundleMap {
                let meta = appMeta[bundleID] ?? (bundleID, nil)
                let key = "\(displayID):\(bundleID)"
                let lastActivated = lastActivatedMap[key] ?? Date(timeIntervalSince1970: 0)
                apps.append(AppOnScreen(
                    bundleID: bundleID,
                    name: meta.name,
                    icon: meta.icon,
                    windows: windows,
                    lastActivated: lastActivated
                ))
            }

            // 최대치 초과 시 어느 앱을 잘라낼지만 최근 사용순으로 결정하고,
            // 표시될 최종 목록은 이름순으로 고정 → 클릭해도 자리 안 바뀜
            // 해상도별 최대치 다름 (1080 초과 = 12, 이하 = 10)
            let maxCount = Settings.shared.maxApps(for: screen)
            if apps.count > maxCount {
                apps.sort {
                    if $0.lastActivated != $1.lastActivated { return $0.lastActivated > $1.lastActivated }
                    return $0.name < $1.name
                }
                apps = Array(apps.prefix(maxCount))
            }
            apps.sort { $0.name < $1.name }

            result.append(MonitorSnapshot(displayID: displayID, apps: apps))
        }

        return result
    }

    // 한 앱(pid)의 AX 창들에서 windowID→제목 맵 구성.
    // _AXUIElementGetWindow로 AX창을 CGWindowID에 매칭 (WindowActivator에 선언된 심볼).
    private func fetchAXTitles(pid: pid_t) -> [CGWindowID: String] {
        var map: [CGWindowID: String] = [:]
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.1)
        var wRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &wRef) == .success,
              let axWins = wRef as? [AXUIElement] else { return map }
        for axWin in axWins {
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(axWin, &wid) == .success, wid != 0 else { continue }
            var tRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &tRef) == .success,
               let t = tRef as? String {
                map[wid] = t
            }
        }
        return map
    }

    // 특정 전역 좌표가 어느 NSScreen에 속하는지 (CGWindow는 좌상단 원점, NSScreen은 좌하단 원점)
    private func screen(containing pointTopLeft: CGPoint) -> NSScreen? {
        // CGWindow의 y는 primary top 기준으로 아래쪽 양수
        // NSScreen.frame은 primary bottom 기준으로 위쪽 양수
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let flipped = CGPoint(x: pointTopLeft.x, y: primaryHeight - pointTopLeft.y)
        return NSScreen.screens.first(where: { $0.frame.contains(flipped) })
    }

    // 앱별 창 제목 정리 — 브라우저 접미사 등 제거
    private func cleanTitle(_ raw: String, bundleID: String) -> String {
        var t = raw
        let suffixes = [
            " - Google Chrome",
            " - Brave",
            " - Microsoft Edge",
            " – Safari",
            " - Firefox"
        ]
        for s in suffixes {
            if t.hasSuffix(s) {
                t = String(t.dropLast(s.count))
                break
            }
        }
        if t.isEmpty { t = "(제목 없음)" }
        return t
    }
}
