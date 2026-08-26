import Cocoa

enum Lang {
    static let isKorean = (Locale.preferredLanguages.first ?? "en").hasPrefix("ko")
    static func t(_ ko: String, _ en: String) -> String { isKorean ? ko : en }
}

class Settings {
    static let shared = Settings()

    // 모니터별 사이드 탭 위치 — displayID → onLeft(true=왼쪽, false=오른쪽)
    // 저장 안 된 모니터는 오른쪽 기본
    private let sideKey = "sidePerDisplay"

    var sidePerDisplay: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: sideKey) as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: sideKey) }
    }

    func onLeft(for displayID: CGDirectDisplayID) -> Bool {
        sidePerDisplay[String(displayID)] ?? false
    }

    func setOnLeft(_ onLeft: Bool, for displayID: CGDirectDisplayID) {
        var d = sidePerDisplay
        d[String(displayID)] = onLeft
        sidePerDisplay = d
    }

    // 모니터별 활성화 여부 — 저장 안 된 모니터는 기본 켜짐
    private let enabledKey = "enabledPerDisplay"

    var enabledPerDisplay: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: enabledKey) as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    func isEnabled(for displayID: CGDirectDisplayID) -> Bool {
        enabledPerDisplay[String(displayID)] ?? true
    }

    func setEnabled(_ enabled: Bool, for displayID: CGDirectDisplayID) {
        var d = enabledPerDisplay
        d[String(displayID)] = enabled
        enabledPerDisplay = d
    }

    // 앱별 색상 인덱스 (팔레트 자동 할당 결과 캐시) — bundleID → palette index
    private let colorKey = "appColorIndex"

    var appColorIndex: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: colorKey) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: colorKey) }
    }

    func colorIndex(for bundleID: String) -> Int {
        if let idx = appColorIndex[bundleID] { return idx }
        // 첫 등장 앱은 현재까지 저장된 앱 수 기준으로 다음 팔레트 색 할당
        let next = appColorIndex.count % ColorPalette.count
        var d = appColorIndex
        d[bundleID] = next
        appColorIndex = d
        return next
    }

    // 해상도별 최대 표시 앱 갯수 — 논리 세로 1080 초과면 12개, 이하면 10개
    func maxApps(for screen: NSScreen) -> Int {
        screen.frame.height > 1080 ? 12 : 10
    }
}

// 앱 배경색 팔레트 — 12색 HSL 균등 분포 (S=65%, L=45%, alpha=0.9)
// 순차 할당 시 인접 hue가 겹치지 않도록 순서를 대비 크게 재배치
enum ColorPalette {
    static let colors: [NSColor] = [
        // 순서: 0° → 120° → 240° → 30° → 150° → 270° → 60° → 180° → 300° → 90° → 210° → 330°
        // 첫 등장 앱들끼리 hue 차이 120° 이상 유지 → 뭉침 방지
        rgb(190,  40,  50),  // 0°   빨강
        rgb( 40, 190,  70),  // 120° 초록
        rgb( 55,  55, 190),  // 240° 파랑
        rgb(190, 105,  40),  // 30°  주황
        rgb( 40, 190, 145),  // 150° 틸
        rgb(140,  50, 190),  // 270° 보라
        rgb(180, 165,  30),  // 60°  황금
        rgb( 40, 165, 190),  // 180° 시안
        rgb(190,  55, 175),  // 300° 마젠타
        rgb(105, 180,  40),  // 90°  라임
        rgb( 50, 130, 200),  // 210° 스카이블루
        rgb(200,  70, 130)   // 330° 핫핑크
    ]

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(calibratedRed: CGFloat(r)/255,
                green: CGFloat(g)/255,
                blue: CGFloat(b)/255,
                alpha: 0.90)
    }

    static var count: Int { colors.count }

    static func color(at index: Int) -> NSColor {
        colors[index % count]
    }
}
