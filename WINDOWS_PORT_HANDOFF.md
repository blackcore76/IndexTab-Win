# IndexTab — Windows 포팅 인수인계 문서

> **이 문서를 읽는 Claude Code(윈도우 환경)에게:**
> 이건 macOS에서 v0.1.19까지 개발된 `IndexTab`이라는 유틸리티를 **윈도우용으로 새로 만들기 위한** 명세서입니다.
> 맥의 Swift 코드를 그대로 옮기는 게 아니라, **동작·UX·설계 의도를 그대로 재현하는 윈도우 네이티브 앱을 처음부터 만드는 것**이 목표입니다.
> macOS 원본 소스(`Sources/*.swift`)는 같은 폴더에 레퍼런스로 함께 있습니다 — 로직이 헷갈리면 원본을 직접 읽으세요.

---

## 1. IndexTab이 뭐 하는 앱인가 (한 문단)

각 모니터의 **가장자리(기본 오른쪽, 설정으로 왼쪽 가능)** 에 세로로 쌓인 **인덱스 탭 스트립**을 항상 띄워두는 유틸리티입니다.
탭 하나 = 그 모니터에 창을 띄운 앱 하나. 탭을 클릭하면 그 앱의 창이 즉시 앞으로 나옵니다.
브라우저 탭 스트립을 화면 옆에 붙여 "지금 이 모니터에 뭐가 열려 있나"를 한눈에 보고 바로 전환하는 게 목적입니다.
Dock/작업표시줄과 달리 **모니터별로 분리**되어 있고 **세로 공간**을 쓰는 게 차별점입니다.

---

## 2. 정확한 상호작용 모델 (이게 제일 중요 — 그대로 재현할 것)

### 평소 상태 (collapsed)
- 스트립 폭 **28px**. 각 탭 높이 **105px**, 탭끼리 **8px 겹침**(seam)으로 세로로 쌓임.
- 스트립은 화면 세로 **정중앙**에 배치. 탭 개수만큼 높이 계산.
- 탭에는 **앱 이름이 세로로** 표시:
  - **한글/CJK** → 글자를 위→아래로 똑바로 쌓음 (upright).
  - **영문/숫자** → 텍스트를 90° 회전해서 아래→위로 눕힘.
  - 이름 길이 제한: CJK 12자, 영문 20자 초과 시 `…` 말줄임.
- 탭 배경: 진회색 그라데이션(위 밝고 아래 어두움) + seam에 그림자로 층 입체감.

### 호버 (expand)
- 마우스가 특정 탭 위에 올라가면 **그 탭만** 28→105px로 펼쳐지고, 스트립 창 폭도 105px로 넓어짐.
- 펼쳐진 탭은 **앱 아이콘(44px) + 이름 한 줄**을 세로 중앙에 표시. 색은 슬레이트 그레이로 구분.
- 나머지 탭은 28px 그대로 가장자리에 앵커된 채 유지.
- 애니메이션: **0.13초 easeOut**. 한 스트립 = 마우스 연속 추적 → 유기적인 느낌.
- 마우스가 스트립 창 밖으로 나가면 다시 28px로 축소.
- 호버 대상이 탭 A→B로 바뀌면 A는 접히고 B가 펼쳐짐(동시).

### 클릭
- **좌클릭**: 그 앱의 **최근(z-order 최상단) 창 하나**를 앞으로 raise.
- **우클릭**: 창이 2개 이상이면 창 제목 리스트 팝업 메뉴 → 고른 창을 raise. (창이 1개면 좌클릭과 동일)
  - 메뉴 순서는 **창 생성순 고정**(z-order 바뀌어도 순서 안 흔들리게).

### 정렬·개수 규칙 (중요한 디테일)
- 표시되는 앱 목록은 **이름 알파벳순 고정** → 클릭해서 활성화해도 탭 위치가 안 바뀜(근육 기억 유지).
- 단, 최대 개수를 넘으면 **어느 앱을 잘라낼지는 최근 활성화순**으로 결정한 뒤, 남은 걸 다시 이름순 정렬.
- 최대 개수: 논리 세로 해상도 **1080 초과 = 12개, 이하 = 10개**.
- 너무 작은 창(가로<60 또는 세로<40)은 무시(툴팁·팝업 배제).

---

## 3. 아키텍처 (macOS 원본 기준 — 윈도우도 같은 구조 권장)

```
main            → 앱 진입점. Dock 아이콘 없는 백그라운드(accessory) 앱으로 실행.
AppDelegate     → 트레이(메뉴바) 아이콘 + 메뉴. 모니터별 스트립 생성/재생성. 화면 구성 변경 감지.
WindowTracker   → 1.5초 주기로 전체 창 목록 폴링 → 모니터별 앱 스냅샷 생성 (핵심 데이터 소스).
IndexBar        → 한 모니터에 붙는 스트립 창(1개). 탭 스택 레이아웃·호버 확장/축소 애니메이션.
  └ TabView     → 탭 하나. collapsed(세로텍스트)/expanded(아이콘+이름) 두 콘텐츠 전환. 클릭 처리.
WindowActivator → 특정 창 하나를 앞으로 raise (플랫폼 창 관리 API 핵심부).
Settings        → 모니터별 on/off·좌우 위치, 앱 색상 인덱스 등 영구 저장.
```

데이터 흐름: `WindowTracker(폴링)` → `MonitorSnapshot[]` → `AppDelegate.apply()` → 각 `IndexBar.update()` → `TabView` 갱신.
성능 팁(원본에서 이미 함): 앱 구성(bundleID 순서)이 안 바뀌었으면 탭을 **재생성하지 않고 데이터만 갱신** → 1.5초 폴링이 호버를 깨지 않음.

---

## 4. macOS API → Windows API 매핑 (핵심 참고표)

| 기능 | macOS 원본 | Windows 대응 |
|------|-----------|-------------|
| 열린 창 열거 (z-order 순) | `CGWindowListCopyWindowInfo` | `EnumWindows` + `IsWindowVisible` + `GetWindowLong(GWL_EXSTYLE)`로 도구창(WS_EX_TOOLWINDOW) 제외 |
| 창 위치/크기 | `kCGWindowBounds` | `GetWindowRect` (DWM 그림자 제외하려면 `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)`) |
| 창 제목 | AX `kAXTitleAttribute` / `kCGWindowName` | `GetWindowText` / `GetWindowTextLength` |
| 창 → 프로세스 | `kCGWindowOwnerPID` | `GetWindowThreadProcessId` |
| 프로세스 이름/경로 | `NSRunningApplication.localizedName` | `QueryFullProcessImageName` → exe명, 또는 파일 설명 |
| 앱 아이콘 | `NSRunningApplication.icon` | `SHGetFileInfo(SHGFI_ICON)` 또는 `ExtractIconEx`(exe 경로에서) |
| 창이 어느 모니터에 있나 | 창 중심점 → `NSScreen` 매칭 | 창 중심점 → `MonitorFromPoint` / `EnumDisplayMonitors`+`GetMonitorInfo` |
| **특정 창 하나만 앞으로** | `_SLPSSetFrontProcessWithOptions` (private SkyLight) | `SetForegroundWindow` + `AttachThreadInput` 트릭 + `BringWindowToTop`, 최소화 시 `ShowWindow(SW_RESTORE)` |
| 항상 위 / 클릭해도 포커스 안 뺏김 창 | `NSWindow.level=.floating`, `borderless` | `WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`, layered window |
| 반투명·둥근모서리·그림자 | CALayer / CAGradientLayer | Layered Window(`UpdateLayeredWindow`) 또는 Composition(WinUI/Direct2D) |
| 모든 가상데스크톱에 표시 | `collectionBehavior=.canJoinAllSpaces` | 기본 topmost면 됨 (필요시 `IVirtualDesktopManager`) |
| 영구 설정 저장 | `UserDefaults` | 레지스트리 `HKCU` 또는 `%APPDATA%\IndexTab\settings.json` |
| 트레이 아이콘 + 메뉴 | `NSStatusItem` | `Shell_NotifyIcon` (Notify Icon) + context menu |

### ⭐ 윈도우에서 오히려 더 쉬운 점
macOS에서 제일 고생한 부분이 **"같은 앱 창이 여러 모니터에 있을 때 클릭 하나에 다 튀어나오는 문제"** 였고, 이걸 private SkyLight API(`_SLPSSetFrontProcessWithOptions`)로 겨우 해결했습니다.
**윈도우는 z-order가 전역(HWND 단위)** 이라 이 문제가 없습니다. `SetForegroundWindow(hwnd)` 하나로 그 창만 딱 올라옵니다. → 포팅 시 이 파트는 훨씬 단순해집니다. (단, `SetForegroundWindow`의 포커스 훔치기 제약 때문에 `AttachThreadInput` 우회가 필요할 수 있음 — 이건 알려진 패턴.)

---

## 5. 윈도우 기술 스택 선택 (결정 필요)

사용자 목표: **맥은 계속 발전 + 윈도우 신규 + 장기적으로 크로스플랫폼 지향.**

| 스택 | 장점 | 단점 | 추천도 |
|------|------|------|--------|
| **C# + WPF** | Win32 창 API 접근 쉬움(P/Invoke), 투명·애니메이션·트레이 성숙, 개발 빠름 | 윈도우 전용 | ★ 윈도우 우선이면 최적 |
| **C# + WinUI 3** | 최신 UI, 컴포지션 효과 좋음 | 항상-위 layered window 다루기가 WPF보다 까다로움 | ○ |
| **C++ / Win32** | 맥 원본과 가장 유사한 저수준 제어 | 개발 느림, 코드량 많음 | △ |
| **Flutter / Tauri** | 맥·윈도우 **단일 코드베이스** 가능 | 창 열거/raise는 어차피 플랫폼별 네이티브 플러그인 필요 | 크로스플랫폼 진심이면 ○ |

**현실적 조언:** 이 앱의 핵심(다른 앱 창 열거·raise·모니터 판별)은 **본질적으로 OS별 네이티브 코드**라 100% 공유는 불가능합니다.
그래서 "진짜 크로스플랫폼"은 → **UI/상호작용 레이어는 공유(Flutter/Tauri), 창 관리 백엔드만 플랫폼별로** 가 정석입니다.
다만 지금 당장 윈도우 버전을 **가장 빨리·안정적으로** 뽑는 건 **C# WPF**입니다.
→ **권장: 우선 WPF로 윈도우 버전을 완성**해서 동작을 검증하고, 크로스플랫폼 통합은 그 다음 단계로. (사용자와 먼저 상의할 것.)

---

## 6. 사용자(BlackCore) 작업 스타일 — 이렇게 맞춰주면 좋음

- **한국어로 소통**. 코드 주석도 한글로 상세히 다는 걸 선호(맥 원본 참고).
- 개발 환경은 **GitHub Desktop + VSCode** 위주. 터미널/git 직접 써도 되지만, 공유 저장소 push 전엔 상태 확인해줄 것.
- **초보자 관점의 안내** 중시: 설치 가이드, 권한 경고, 실행법을 친절히. (릴리즈 노트는 한/영 병기 습관.)
- 완성도·디테일에 신경 씀(애니메이션 타이밍, 겹침 그림자, 폰트 폴백까지 맥 원본이 꼼꼼함). 대충 동작만 되는 것보다 **UX 디테일 재현**을 기대함.
- 색상: 한국식 손익 색(빨강=상승) 같은 로컬 관습을 챙기는 편 — 이 앱엔 무관하지만 UI 판단 시 참고.

---

## 7. 윈도우에서 처음 할 일 (착수 체크리스트)

1. 이 문서 + `Sources/*.swift`(레퍼런스) 통독. 특히 `WindowTracker.swift`(데이터), `IndexBar.swift`(UX), `WindowActivator.swift`(raise).
2. 스택 확정(권장 WPF) — 사용자와 확인.
3. **뼈대부터**: 트레이 아이콘 + 오른쪽 가장자리에 항상-위 투명 스트립 창 1개 띄우기.
4. `EnumWindows` 폴링으로 "현재 모니터의 앱 목록" 뽑아 탭으로 렌더 (정렬·개수 규칙 §2 적용).
5. 클릭 → `SetForegroundWindow`로 raise 검증.
6. 호버 확장/축소 애니메이션(§2) 구현.
7. 멀티모니터(§4 매핑), 좌우 위치 설정, 영구 저장 순으로 확장.
8. macOS 버전과 **동작 동일성** 기준으로 diff 점검.

---

## 8. 알려진 macOS 특유 이슈 (윈도우엔 대부분 무관)

- macOS는 창 raise에 **손쉬운 사용(Accessibility) 권한** 필수 + 재부팅/업데이트로 권한이 조용히 무효화되는 문제 → 사용자 안내 로직이 많음. **윈도우는 이 권한 문제 없음**(UIAccess 매니페스트가 필요할 수 있는 정도).
- private SkyLight API 의존(§4) → 윈도우는 불필요.
- 레티나 배율 대응 레이어 재설정 → 윈도우는 DPI per-monitor awareness(`SetProcessDpiAwarenessContext`)로 대응.

---

**요약:** 윈도우 포팅은 "복사"가 아니라 "동작 재현 재작성"이고, 핵심 창 관리 부분은 **윈도우가 macOS보다 오히려 쉽습니다**(전역 z-order). 어려운 건 UX 디테일(세로 텍스트·호버 애니메이션·seam 그림자)을 얼마나 충실히 살리느냐입니다. 맥 원본이 그 답을 이미 다 갖고 있으니 그대로 참조하세요.
