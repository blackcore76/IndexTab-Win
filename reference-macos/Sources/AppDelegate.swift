import Cocoa
import CoreText

// 번들 폰트 로더 — 시스템에 없는 Noto Sans Display Italic을 앱 실행 시 등록.
enum AppFonts {
    private static var registered = false

    static func registerBundledFonts() {
        guard !registered else { return }
        registered = true
        if let url = Bundle.main.url(forResource: "NotoSansDisplay-Italic", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    // 영문 세로 표기용 — Noto Sans Display 400 이탤릭. 없으면 시스템 이탤릭 폴백.
    static func rotatedLatin(_ size: CGFloat) -> NSFont {
        if let f = NSFont(name: "NotoSansDisplay-Italic", size: size) { return f }
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var tracker: WindowTracker!
    private var bars: [CGDirectDisplayID: IndexBar] = [:]
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppFonts.registerBundledFonts()

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "IndexTab must stay active"
        )
        ProcessInfo.processInfo.disableAutomaticTermination("IndexTab must stay active")
        ProcessInfo.processInfo.disableSuddenTermination()

        setupStatusBar()
        setupTracker()
        rebuildBars()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    // MARK: - 상태바

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.grid.3x1.below.line.grid.1x2",
                                   accessibilityDescription: "IndexTab")
        }
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    private func refreshMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        if !Accessibility.isTrusted {
            let warn = NSMenuItem(
                title: Lang.t("⚠️ 손쉬운 사용 권한 필요 — 클릭해서 복구",
                              "⚠️ Accessibility permission needed — click to fix"),
                action: #selector(fixAccessibility), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(NSMenuItem.separator())
        }

        // 모니터별 설정
        let header = NSMenuItem(title: Lang.t("모니터별 설정", "Per-Monitor Settings"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for (i, screen) in NSScreen.screens.enumerated() {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            let name = screen.localizedName.isEmpty ? "\(Lang.t("모니터", "Monitor")) \(i+1)" : screen.localizedName

            let sub = NSMenu()
            let enabled = Settings.shared.isEnabled(for: displayID)
            let onLeft = Settings.shared.onLeft(for: displayID)

            let enableItem = NSMenuItem(title: enabled ? Lang.t("✓ 활성화", "✓ Enabled") : Lang.t("비활성화됨", "Disabled"),
                                        action: #selector(toggleEnable(_:)), keyEquivalent: "")
            enableItem.target = self
            enableItem.tag = Int(displayID)
            sub.addItem(enableItem)
            sub.addItem(NSMenuItem.separator())

            let rightOpt = NSMenuItem(title: Lang.t("오른쪽 (3시)", "Right"), action: #selector(setSide(_:)), keyEquivalent: "")
            rightOpt.target = self
            rightOpt.tag = Int(displayID)
            rightOpt.state = onLeft ? .off : .on
            rightOpt.representedObject = false
            sub.addItem(rightOpt)

            let leftOpt = NSMenuItem(title: Lang.t("왼쪽 (9시)", "Left"), action: #selector(setSide(_:)), keyEquivalent: "")
            leftOpt.target = self
            leftOpt.tag = Int(displayID)
            leftOpt.state = onLeft ? .on : .off
            leftOpt.representedObject = true
            sub.addItem(leftOpt)

            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let versionItem = NSMenuItem(title: "IndexTab v\(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let restartItem = NSMenuItem(title: Lang.t("IndexTab 재시작", "Restart IndexTab"), action: #selector(restartApp), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)

        let quitItem = NSMenuItem(title: Lang.t("IndexTab 종료", "Quit IndexTab"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func toggleEnable(_ sender: NSMenuItem) {
        let displayID = CGDirectDisplayID(sender.tag)
        let now = Settings.shared.isEnabled(for: displayID)
        Settings.shared.setEnabled(!now, for: displayID)
        rebuildBars()
    }

    @objc private func setSide(_ sender: NSMenuItem) {
        let displayID = CGDirectDisplayID(sender.tag)
        let onLeft = (sender.representedObject as? Bool) ?? false
        Settings.shared.setOnLeft(onLeft, for: displayID)
        rebuildBars()
    }

    @objc private func fixAccessibility() {
        Accessibility.showLostPermissionAlert()
    }

    @objc private func restartApp() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 트래커 · 사이드바 관리

    private func setupTracker() {
        tracker = WindowTracker()
        tracker.onUpdate = { [weak self] snapshots in
            self?.apply(snapshots: snapshots)
        }
        tracker.start()
    }

    @objc private func rebuildBars() {
        // 화면 파라미터가 바뀌었을 수 있으니 기존 바 다 정리하고 다시 만듦
        for (_, bar) in bars {
            bar.orderOut(nil)
        }
        bars.removeAll()

        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            guard Settings.shared.isEnabled(for: displayID) else { continue }
            let bar = IndexBar(displayID: displayID, screen: screen, tracker: tracker)
            bars[displayID] = bar
        }
    }

    private func apply(snapshots: [MonitorSnapshot]) {
        for snap in snapshots {
            guard let bar = bars[snap.displayID] else { continue }
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == snap.displayID
            }) else { continue }
            bar.update(apps: snap.apps, screen: screen)
        }
    }

    @objc private func screensChanged() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(rebuildBars), object: nil)
        perform(#selector(rebuildBars), with: nil, afterDelay: 0.5)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenu(menu)
    }
}
