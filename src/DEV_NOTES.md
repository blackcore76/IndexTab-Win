# IndexTab-Win 개발 노트

## 환경 (이 PC에서 확인/설치한 것)

- **.NET SDK 10.0** (`winget install Microsoft.DotNet.SDK.10`) — WPF는 `net10.0-windows` 타겟으로 포함.
- 대상 프레임워크: `net10.0-windows`, 플랫폼: **x64**, DPI: **Per-Monitor V2** (`app.manifest`).
- 추가 NuGet 패키지 없음 (WPF + WinForms NotifyIcon 만 사용 — `UseWPF`/`UseWindowsForms`).

## 빌드 / 실행

```bash
cd src
dotnet build                 # 디버그 빌드
dotnet run                   # 빌드 후 바로 실행 (트레이에 아이콘이 뜸)
```

릴리스 단일 실행 파일:

```bash
dotnet publish -c Release -r win-x64 --self-contained false -o publish
```

## 구조 (macOS 원본 → Windows 대응)

| 파일 | 역할 | macOS 원본 |
|------|------|-----------|
| `App.xaml(.cs)` | 진입점(트레이 상주) | `main.swift` |
| `AppController.cs` | 트레이 아이콘·메뉴, 모니터별 스트립 생성/재생성 | `AppDelegate.swift` |
| `Core/WindowTracker.cs` | 1.5초 폴링 → 모니터별 앱 스냅샷 | `WindowTracker.swift` |
| `Core/WindowActivator.cs` | 특정 창 raise (`SetForegroundWindow`+`AttachThreadInput`) | `WindowActivator.swift` |
| `Core/DisplayManager.cs` | 모니터 열거(물리픽셀+DPI) | `NSScreen` |
| `Core/Settings.cs` | 설정 저장(`%APPDATA%\IndexTab\settings.json`) | `Settings.swift`(UserDefaults) |
| `Core/Models.cs` | 데이터 모델 | `AppOnScreen`/`WindowRef`/`MonitorSnapshot` |
| `UI/IndexBar.cs` | 한 모니터의 스트립 창·호버 애니메이션 | `IndexBar.swift` |
| `UI/TabView.cs` | 탭 하나(세로텍스트/아이콘+이름) | `TabView`(IndexBar.swift 내) |
| `Native/NativeMethods.cs` | Win32 P/Invoke 모음 | (CoreGraphics/AppKit) |

## 상호작용 규격 (핸드오프 §2 기준)

- 평소 폭 28, 탭 높이 105, 겹침 8 (DIP). 스트립은 모니터 세로 중앙.
- 호버: 그 탭만 28→105로 확장(0.13초 easeOut). 창 폭도 105로. 벗어나면 축소.
- 좌클릭 = 최상단 창 raise / 우클릭 = 창 여러 개면 제목 메뉴(생성순 고정).
- 목록은 이름순 고정. 최대 개수: 세로 1080 초과=12, 이하=10.

## 알려진 TODO / 다듬을 점

- [ ] 영문 세로 텍스트 회전 방향(-90°) 실제 화면에서 확인 후 미세조정.
- [ ] 혼합 DPI(모니터마다 배율 다름) 환경 정밀 검증.
- [ ] 앱 색상 팔레트(macOS `ColorPalette`) 도입 여부 — 현재는 통일 회색.
- [ ] 시작 프로그램 등록(선택).
