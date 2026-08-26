import Cocoa

// 한 모니터에 붙는 세로 인덱스 탭 스택 (창)
//
// 상호작용 모델:
//   평소 창 폭 28px, 탭들이 엣지에 세로로 쌓임. 탭 호버 시 창을 105px로 넓히고
//   그 탭만 제자리에서 28→105로 확장(아이콘+이름). 나머지 탭은 엣지 그대로.
//   하나의 창 = 연속 마우스 추적 → 유기적. 창 벗어나면 28px로 축소.
//
//   v0.1.8: WindowTracker 1.5초 주기 갱신이 호버를 깨지 않도록, 앱 목록(순서·구성)이
//   바뀌지 않았으면 탭을 재생성하지 않고 데이터만 갱신. 확장/축소 콘텐츠는 미리
//   만들어두고 표시 전환만 → 호버 시 재렌더 지연 제거.
class IndexBar: NSWindow {

    let displayID: CGDirectDisplayID
    private var apps: [AppOnScreen] = []
    private var appSignature: [String] = []   // 재생성 필요 판단용 (bundleID 순서)
    private var onLeft: Bool
    private weak var tracker: WindowTracker?

    private let collapsedW: CGFloat = 28
    private let expandedW: CGFloat = 105
    private let tabHeight: CGFloat = 105
    private let tabOverlap: CGFloat = 8

    private var tabs: [TabView] = []
    private var hoveredIndex: Int?
    private var container: BarContainerView!

    init(displayID: CGDirectDisplayID, screen: NSScreen, tracker: WindowTracker) {
        self.displayID = displayID
        self.tracker = tracker
        self.onLeft = Settings.shared.onLeft(for: displayID)

        super.init(contentRect: NSRect(x: 0, y: 0, width: 28, height: 400),
                   styleMask: .borderless, backing: .buffered, defer: false)

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true

        let cv = BarContainerView(frame: NSRect(x: 0, y: 0, width: 28, height: 400))
        cv.wantsLayer = true
        cv.onExitBar = { [weak self] in self?.setHovered(nil) }
        container = cv
        contentView = cv

        reposition(to: screen)
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(apps: [AppOnScreen], screen: NSScreen) {
        self.onLeft = Settings.shared.onLeft(for: displayID)
        let newSig = apps.map { $0.bundleID }

        if newSig == appSignature && tabs.count == apps.count {
            // 구성 동일 → 재생성 안 함(호버 유지). 창 데이터만 갱신.
            self.apps = apps
            for (i, tab) in tabs.enumerated() { tab.updateApp(apps[i]) }
            // 호버 중이 아닐 때만 위치 재조정 (호버 중 리사이즈 방지)
            if hoveredIndex == nil { reposition(to: screen) }
            return
        }

        self.apps = apps
        self.appSignature = newSig
        rebuildTabs()
        reposition(to: screen)
    }

    private func totalHeight() -> CGFloat {
        let count = CGFloat(max(apps.count, 1))
        return count * tabHeight - max(0, count - 1) * tabOverlap
    }

    func reposition(to screen: NSScreen) {
        let w = (hoveredIndex == nil) ? collapsedW : expandedW
        let totalH = totalHeight()
        let x: CGFloat = onLeft ? screen.frame.minX : screen.frame.maxX - w
        let y = screen.frame.origin.y + (screen.frame.height - totalH) / 2
        setFrame(NSRect(x: x, y: y, width: w, height: totalH), display: true)
        container.setFrameSize(NSSize(width: w, height: totalH))
    }

    private func rebuildTabs() {
        hoveredIndex = nil
        tabs.forEach { $0.removeFromSuperview() }
        tabs.removeAll()

        let totalH = totalHeight()
        container.setFrameSize(NSSize(width: collapsedW, height: totalH))
        guard !apps.isEmpty else { return }

        for (i, app) in apps.enumerated() {
            let tab = TabView(app: app, onLeft: onLeft,
                              displayID: displayID, tracker: tracker,
                              collapsedW: collapsedW, expandedW: expandedW, height: tabHeight)
            tab.frame = tabFrame(index: i, expanded: false, windowWidth: collapsedW)
            tab.setExpanded(false)
            tab.onHoverEnter = { [weak self] in self?.setHovered(i) }
            tab.onDidActivate = { [weak self] in self?.setHovered(nil) }
            container.addSubview(tab)
            tabs.append(tab)
        }
    }

    private func tabFrame(index: Int, expanded: Bool, windowWidth: CGFloat) -> NSRect {
        let tw = expanded ? expandedW : collapsedW
        let tx = onLeft ? 0 : (windowWidth - tw)
        let ty = CGFloat(index) * (tabHeight - tabOverlap)
        return NSRect(x: tx, y: ty, width: tw, height: tabHeight)
    }

    // MARK: - 호버 확장/축소

    private func setHovered(_ index: Int?) {
        guard index != hoveredIndex else { return }
        let old = hoveredIndex
        hoveredIndex = index

        if old == nil, let i = index {
            expandFromCollapsed(i)
        } else if index == nil, let o = old {
            collapseToIdle(o)
        } else if let o = old, let i = index {
            switchHover(from: o, to: i)
        }
    }

    private func expandFromCollapsed(_ i: Int) {
        guard i < tabs.count else { return }
        setWindowWidth(expandedW)
        for (j, tab) in tabs.enumerated() where j != i {
            tab.frame = tabFrame(index: j, expanded: false, windowWidth: expandedW)
        }
        let start = tabFrame(index: i, expanded: false, windowWidth: expandedW)
        let end = tabFrame(index: i, expanded: true, windowWidth: expandedW)
        let tab = tabs[i]
        tab.frame = start
        tab.setExpanded(true)
        // 자연 순서 유지 (아래 index가 앞) → 확장 탭 상단은 위 이웃을 덮고,
        // 확장 탭 하단은 아래 이웃에 덮임 = 대기 상태의 반복 겹침 규칙과 동일
        animate(tab, to: end)
    }

    private func collapseToIdle(_ o: Int) {
        guard o < tabs.count else { return }
        let tab = tabs[o]
        tab.setExpanded(false)
        let mid = tabFrame(index: o, expanded: false, windowWidth: expandedW)
        animate(tab, to: mid) { [weak self] in
            guard let self = self, self.hoveredIndex == nil else { return }
            self.setWindowWidth(self.collapsedW)
            for (j, t) in self.tabs.enumerated() {
                t.frame = self.tabFrame(index: j, expanded: false, windowWidth: self.collapsedW)
                t.layer?.zPosition = 0
            }
        }
    }

    private func switchHover(from o: Int, to i: Int) {
        guard o < tabs.count, i < tabs.count else { return }
        let oldTab = tabs[o]
        oldTab.setExpanded(false)
        animate(oldTab, to: tabFrame(index: o, expanded: false, windowWidth: expandedW))

        let newTab = tabs[i]
        newTab.setExpanded(true)
        animate(newTab, to: tabFrame(index: i, expanded: true, windowWidth: expandedW))
    }

    private func animate(_ view: NSView, to frame: NSRect, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().frame = frame
        }, completionHandler: completion)
    }

    private func setWindowWidth(_ w: CGFloat) {
        guard let screen = screenForThisBar() else { return }
        let sf = screen.frame
        let f = frame
        let x = onLeft ? sf.minX : sf.maxX - w
        setFrame(NSRect(x: x, y: f.origin.y, width: w, height: f.height), display: true)
        container.setFrameSize(NSSize(width: w, height: f.height))
    }

    private func screenForThisBar() -> NSScreen? {
        NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        })
    }
}

// MARK: - 바 컨테이너 (창 이탈 감지)

class BarContainerView: NSView {
    var onExitBar: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseExited(with event: NSEvent) {
        // 창 리사이즈로 인한 오발화 방지 — 실제로 창 밖일 때만 축소
        guard let win = window else { return }
        if !win.frame.contains(NSEvent.mouseLocation) {
            onExitBar?()
        }
    }
}

// MARK: - 탭 하나 (평소=세로텍스트 28px / 확장=아이콘+이름 105px)
// 두 콘텐츠를 미리 만들어 두고 표시만 전환. 확장 콘텐츠는 105 고정 배치 + 엣지 앵커.

class TabView: NSView {

    private var app: AppOnScreen
    private let onLeft: Bool
    private let displayID: CGDirectDisplayID
    private weak var tracker: WindowTracker?

    private let collapsedW: CGFloat
    private let expandedW: CGFloat
    private let height: CGFloat

    // 대기 = 진회색(통일), 호버 확장 = 슬레이트 그레이(차별화)
    private let idleColor = NSColor(calibratedRed: 0x3A/255, green: 0x3A/255, blue: 0x3C/255, alpha: 0.95)
    private let hoverColor = NSColor(calibratedRed: 0x70/255, green: 0x80/255, blue: 0x90/255, alpha: 0.98)

    var onHoverEnter: (() -> Void)?
    var onDidActivate: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var collapsedContent: NSView!
    private var expandedContent: NSView!

    static let topInset: CGFloat = 8
    static let bottomInset: CGFloat = 5

    init(app: AppOnScreen, onLeft: Bool,
         displayID: CGDirectDisplayID, tracker: WindowTracker?,
         collapsedW: CGFloat, expandedW: CGFloat, height: CGFloat) {
        self.app = app
        self.onLeft = onLeft
        self.displayID = displayID
        self.tracker = tracker
        self.collapsedW = collapsedW
        self.expandedW = expandedW
        self.height = height
        super.init(frame: NSRect(x: 0, y: 0, width: collapsedW, height: height))

        wantsLayer = true
        // 레티나(2x/3x) 해상도에 맞춰 레이어를 고품질로 그려 모서리·곡선 매끄럽게
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.contentsScale = scale
        layer?.rasterizationScale = scale
        layer?.allowsEdgeAntialiasing = true
        if let g = gradientLayer {
            g.contentsScale = scale
            applyGradient(expanded: false)
            // 세로 그라데이션 방향 (flipped 레이어라 y=0이 상단): 위=밝음, 아래=어두움
            g.startPoint = CGPoint(x: 0.5, y: 0)
            g.endPoint = CGPoint(x: 0.5, y: 1)
            g.borderWidth = 1.0
            g.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
            g.cornerRadius = 12
            g.maskedCorners = onLeft
                ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
                : [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            // B: 겹침 seam 강조 — 앞(아래 index) 탭이 뒤 탭 위로 또렷한 그림자.
            // 위쪽(+height)으로 던져 seam 경계가 도드라지게. 사이드는 살짝만.
            g.shadowColor = NSColor.black.cgColor
            g.shadowOpacity = 0.5
            g.shadowOffset = CGSize(width: onLeft ? 1 : -1, height: 3)
            g.shadowRadius = 3
        }

        buildContents()
    }

    override func makeBackingLayer() -> CALayer { CAGradientLayer() }
    private var gradientLayer: CAGradientLayer? { layer as? CAGradientLayer }

    // 모니터 이동 등으로 화면 배율이 바뀌면 레이어 해상도 다시 맞춤 (계단현상 방지)
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2.0
        layer?.contentsScale = s
        layer?.rasterizationScale = s
        gradientLayer?.contentsScale = s
    }

    // 레이어 형태(둥근 사각형)에 딱 맞는 그림자 path → 알파 기반보다 선명·매끈
    override func layout() {
        super.layout()
        guard let g = gradientLayer else { return }
        g.shadowPath = CGPath(roundedRect: bounds,
                              cornerWidth: g.cornerRadius, cornerHeight: g.cornerRadius,
                              transform: nil)
    }

    // A: 세로 그라데이션 (위 밝게 / 아래 어둡게)로 층 입체감
    private func applyGradient(expanded: Bool) {
        guard let g = gradientLayer else { return }
        let base = expanded ? hoverColor : idleColor
        let top = base.blended(withFraction: 0.10, of: .white) ?? base
        let bottom = base.blended(withFraction: 0.14, of: .black) ?? base
        g.colors = [top.cgColor, bottom.cgColor]
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // 확장/축소 콘텐츠를 미리 만들어 넣고 엣지에 앵커 (autoresizing으로 폭 변화에 추종)
    private func buildContents() {
        let hug: NSView.AutoresizingMask = onLeft ? [.maxXMargin] : [.minXMargin]

        // 평소(세로 텍스트) — 28×height, 엣지 앵커. flipped로 TabView와 좌표계 통일(위=y작음)
        let cx: CGFloat = onLeft ? 0 : bounds.width - collapsedW
        collapsedContent = FlippedHost(frame: NSRect(x: cx, y: 0, width: collapsedW, height: height))
        collapsedContent.autoresizingMask = hug
        addSubview(collapsedContent)
        buildCollapsed(into: collapsedContent)

        // 확장(아이콘+이름) — 105×height, 엣지 앵커
        let ex: CGFloat = onLeft ? 0 : bounds.width - expandedW
        expandedContent = FlippedHost(frame: NSRect(x: ex, y: 0, width: expandedW, height: height))
        expandedContent.autoresizingMask = hug
        addSubview(expandedContent)
        buildExpanded(into: expandedContent)
        expandedContent.isHidden = true
    }

    func setExpanded(_ exp: Bool) {
        collapsedContent.isHidden = exp
        expandedContent.isHidden = !exp
        gradientLayer?.cornerRadius = exp ? 16 : 12
        applyGradient(expanded: exp)
        // 테두리는 은은하게 (흰 배경에서 밝은 테두리가 튀지 않게) — 형태는 그림자가 잡음
        gradientLayer?.borderColor = exp
            ? NSColor.white.withAlphaComponent(0.16).cgColor
            : NSColor.white.withAlphaComponent(0.10).cgColor
    }

    // 앱 데이터 갱신 (재생성 없이). 이름 바뀌면 콘텐츠만 다시 그림.
    func updateApp(_ newApp: AppOnScreen) {
        let nameChanged = newApp.name != app.name
        app = newApp
        if nameChanged {
            collapsedContent.subviews.forEach { $0.removeFromSuperview() }
            expandedContent.subviews.forEach { $0.removeFromSuperview() }
            buildCollapsed(into: collapsedContent)
            buildExpanded(into: expandedContent)
        }
    }

    // MARK: 평소(세로 텍스트)

    private func buildCollapsed(into host: NSView) {
        let display = collapsedName(app.name)
        if containsCJK(display) {
            addUprightLabel(display, into: host)
        } else {
            let rotated = RotatedTextView(text: display,
                                          baseFont: AppFonts.rotatedLatin(14),
                                          color: .white, hostBounds: host.bounds,
                                          topInset: TabView.topInset, bottomInset: TabView.bottomInset)
            rotated.autoresizingMask = [.width, .height]
            host.addSubview(rotated)
        }
    }

    private func collapsedName(_ name: String) -> String {
        let stripped = name.components(separatedBy: .whitespaces).joined()
        let cjk = containsCJK(stripped)
        let limit = cjk ? 12 : 20
        if stripped.count <= limit { return stripped }
        return String(stripped.prefix(limit - 1)) + "…"
    }

    private func addUprightLabel(_ text: String, into host: NSView) {
        let count = CGFloat(text.count)
        let maxUsable = host.bounds.height - TabView.topInset - TabView.bottomInset
        var letterH: CGFloat = 18
        if count * letterH > maxUsable { letterH = max(10, maxUsable / count) }
        let fontSize = max(9, letterH * 0.72)
        let totalH = count * letterH
        var y = TabView.topInset + (maxUsable - totalH) / 2
        for ch in text {
            let label = NSTextField(labelWithString: String(ch))
            label.font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
            label.textColor = .white
            label.alignment = .center
            label.isBezeled = false; label.drawsBackground = false
            label.isEditable = false; label.isSelectable = false
            label.frame = NSRect(x: 0, y: y, width: host.bounds.width, height: letterH)
            host.addSubview(label)
            y += letterH
        }
    }

    // MARK: 확장(아이콘 + 가로 이름) — host는 105×height 고정

    private func buildExpanded(into host: NSView) {
        let side = host.bounds.width   // 105
        let iconSize: CGFloat = 44
        let gap: CGFloat = 5           // 아이콘-이름 간격
        let labelH: CGFloat = 18       // 한 줄
        // 아이콘 + 이름 블록을 상하 정중앙에 배치 (host는 flipped: y 아래로 증가)
        let blockH = iconSize + gap + labelH
        let top = (host.bounds.height - blockH) / 2

        let iconImg = (app.icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil))?.copy() as? NSImage
        iconImg?.size = NSSize(width: iconSize, height: iconSize)
        let iv = NSImageView(frame: NSRect(x: (side - iconSize) / 2, y: top, width: iconSize, height: iconSize))
        iv.image = iconImg
        host.addSubview(iv)

        // 앱 이름 — 한 줄 고정, 좌우 중앙. 영문은 Noto 이탤릭(한글은 시스템 폰트 자동 폴백)
        let lbl = NSTextField(labelWithString: app.name)
        lbl.font = AppFonts.rotatedLatin(14)
        lbl.textColor = .white
        lbl.alignment = .center
        lbl.isBezeled = false; lbl.drawsBackground = false
        lbl.isEditable = false; lbl.isSelectable = false
        lbl.maximumNumberOfLines = 1
        lbl.lineBreakMode = .byTruncatingTail
        lbl.frame = NSRect(x: 3, y: top + iconSize + gap, width: side - 6, height: labelH)
        host.addSubview(lbl)
    }

    private func containsCJK(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (0xAC00...0xD7A3).contains(v) { return true }
            if (0x1100...0x11FF).contains(v) { return true }
            if (0x4E00...0x9FFF).contains(v) { return true }
            if (0x3040...0x30FF).contains(v) { return true }
        }
        return false
    }

    // MARK: 트래킹 & 클릭

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverEnter?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let win = app.windows.first {
            WindowActivator.raise(pid: win.pid, windowID: win.windowID)
            tracker?.markActivated(bundleID: app.bundleID, displayID: displayID)
        }
        onDidActivate?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard app.windows.count > 1 else {
            if let win = app.windows.first {
                WindowActivator.raise(pid: win.pid, windowID: win.windowID)
                tracker?.markActivated(bundleID: app.bundleID, displayID: displayID)
            }
            onDidActivate?()
            return
        }
        // 메뉴는 windowID(생성 순) 오름차순으로 고정 → 활성화로 z-order 바뀌어도 순서 유지.
        // (좌클릭 '최근 창 앞으로'는 z-order 기준 app.windows.first 그대로라 영향 없음)
        let menu = NSMenu()
        for win in app.windows.sorted(by: { $0.windowID < $1.windowID }) {
            let item = NSMenuItem(title: win.title, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = win.windowID
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let wid = sender.representedObject as? CGWindowID,
              let win = app.windows.first(where: { $0.windowID == wid }) else { return }
        WindowActivator.raise(pid: win.pid, windowID: win.windowID)
        tracker?.markActivated(bundleID: app.bundleID, displayID: displayID)
        onDidActivate?()
    }
}

// content host — TabView와 같은 flipped 좌표계(위=y작음)로 통일해
// 세로 한글(위→아래)·아이콘 상단·이름 하단이 뒤집히지 않게 함.
class FlippedHost: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 옆으로 눕힌 텍스트 (영문/숫자용, 아래→위)

class RotatedTextView: NSView {
    private let text: String
    private let baseFont: NSFont
    private let color: NSColor
    private let topInset: CGFloat
    private let bottomInset: CGFloat

    init(text: String, baseFont: NSFont, color: NSColor, hostBounds: NSRect,
         topInset: CGFloat, bottomInset: CGFloat) {
        self.text = text
        self.baseFont = baseFont
        self.color = color
        self.topInset = topInset
        self.bottomInset = bottomInset
        super.init(frame: hostBounds)
        wantsLayer = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let effectiveHeight = bounds.height - topInset - bottomInset
        let effectiveCenterY = bottomInset + effectiveHeight / 2
        let maxTextWidth = effectiveHeight
        let minSize: CGFloat = 8

        var currentFont = baseFont
        var attr = makeAttr(font: currentFont)
        while attr.size().width > maxTextWidth && currentFont.pointSize > minSize {
            // 같은 폰트(패밀리·이탤릭) 유지하며 크기만 축소
            let smaller = NSFont(descriptor: currentFont.fontDescriptor, size: currentFont.pointSize - 0.5)
            currentFont = smaller ?? currentFont
            attr = makeAttr(font: currentFont)
            if smaller == nil { break }
        }
        let textSize = attr.size()

        ctx.saveGState()
        ctx.translateBy(x: bounds.width / 2, y: effectiveCenterY)
        ctx.rotate(by: .pi / 2)
        ctx.translateBy(x: -textSize.width / 2, y: -textSize.height / 2)
        attr.draw(at: .zero)
        ctx.restoreGState()
    }

    private func makeAttr(font: NSFont) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }
}
