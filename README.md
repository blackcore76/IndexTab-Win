# IndexTab-Win

**IndexTab의 Windows 네이티브 버전 (C# WPF)** — 개발 진행 중.

IndexTab은 각 모니터 가장자리에 세로 인덱스 탭 스트립을 띄워, 그 모니터에 창을 가진 앱을
한눈에 보고 클릭 한 번으로 전환하는 유틸리티입니다. 원본은 macOS(Swift)에서 v0.1.19까지 개발되었고,
이 저장소는 그 동작을 그대로 재현하는 **윈도우 전용 버전**을 새로 만드는 곳입니다.

> 🍎 형제 앱(macOS 원본): **[IndexTab-Mac](https://github.com/blackcore76/IndexTab-Mac)** — 별도 저장소로 각각 완성한 뒤, 추후 크로스플랫폼 통합 여부를 판단합니다.

## 👉 개발을 시작하는 Claude Code / 개발자는 여기부터

1. **[`WINDOWS_PORT_HANDOFF.md`](WINDOWS_PORT_HANDOFF.md)** 를 먼저 통독하세요.
   - IndexTab이 뭐 하는 앱인지, 정확한 상호작용 모델, macOS→Windows API 매핑,
     스택 선택 근거, 착수 체크리스트가 전부 들어 있습니다.
2. 로직이 헷갈리면 **[`reference-macos/Sources/`](reference-macos/Sources/)** 의 원본 Swift 소스를 직접 읽으세요.
   (이 폴더는 **읽기 전용 참고용** — 빌드하지 않습니다.)
3. 새 코드는 **[`src/`](src/)** 안에 C# WPF 프로젝트로 작성합니다.

## 폴더 구조

```
IndexTab-Win/
├── README.md                   ← 지금 이 파일
├── WINDOWS_PORT_HANDOFF.md     ← 핵심 명세서 (여기부터 읽기)
├── reference-macos/            ← macOS 원본 (참고 전용, 빌드 안 함)
│   ├── Sources/*.swift
│   ├── Resources/Info.plist
│   └── build.sh
└── src/                        ← C# WPF 프로젝트 (여기서 개발)
```

## 기술 스택

- **언어/프레임워크:** C# + WPF (.NET)
- **창 관리:** Win32 API (`EnumWindows`, `SetForegroundWindow`, `MonitorFromPoint` 등) — P/Invoke
- 자세한 근거는 핸드오프 문서 §5 참고.

## 상태 (v0.1.1 — 포터블 배포 준비)

> 릴리즈 노트: [`RELEASE_NOTES_v0.1.1.md`](RELEASE_NOTES_v0.1.1.md)

- [x] 인수인계 문서 작성
- [x] WPF 프로젝트 스캐폴딩 (.NET 10 / net10.0-windows / x64 / PerMonitorV2)
- [x] 트레이 아이콘 + 항상-위 투명 스트립 창 (NOACTIVATE·TOOLWINDOW·TOPMOST·layered)
- [x] 창 열거 → 탭 렌더링 (세로 텍스트: 한글 upright / 영문 회전, 그라데이션·seam 그림자)
- [x] 클릭 → 창 raise (`SetForegroundWindow`+`AttachThreadInput`) — 동작 검증됨
- [x] 호버 확장/축소 애니메이션 (0.13초 easeOut, 아이콘+이름) — 동작 검증됨
- [x] 멀티모니터 · 좌우 위치 · 설정 저장 (`%APPDATA%\IndexTab\settings.json`)

> 빌드: `cd src && dotnet build` → `dotnet run` (자세한 건 [`src/DEV_NOTES.md`](src/DEV_NOTES.md))
>
> 포터블 배포 빌드: `cd src && dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true`

### 실행 & 권한

설치 없이 **`IndexTab.exe` 실행**만으로 트레이에 상주합니다 (Windows 10/11 64-bit). 두 가지 모드:

- **그냥 실행** → 일반 앱 창 전환 (탐색기·브라우저·메신저 등 — 대부분 이걸로 충분)
- **관리자 권한으로 실행** (우클릭 → *관리자 권한으로 실행*) → 위 + **관리자로 띄운 창**(관리자 PowerShell/터미널 등)까지 제어

> Windows 보안 정책(UIPI)상 낮은 권한 앱은 관리자 창을 제어할 수 없어, 관리자 창까지 다루려면 IndexTab도 관리자로 실행해야 합니다. (향후 코드 서명 + uiAccess로 UAC 없이 지원하는 방안 검토 중)

### 다음 다듬을 점
- 영문 세로 이름이 길면 폰트 축소 대신 말줄임(`…`)됨 → macOS처럼 축소-피팅으로 개선
- 혼합 DPI(모니터별 배율 상이) 환경 정밀 검증
- 앱별 색상 팔레트(macOS `ColorPalette`) 도입 여부 검토
- 시작 프로그램 등록(선택)
