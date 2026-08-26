# IndexTab-Win

**IndexTab의 Windows 네이티브 버전 (C# WPF)** — 개발 진행 중.

IndexTab은 각 모니터 가장자리에 세로 인덱스 탭 스트립을 띄워, 그 모니터에 창을 가진 앱을
한눈에 보고 클릭 한 번으로 전환하는 유틸리티입니다. 원본은 macOS(Swift)에서 v0.1.19까지 개발되었고,
이 저장소는 그 동작을 그대로 재현하는 **윈도우 전용 버전**을 새로 만드는 곳입니다.

> 원본 macOS 버전과는 **별도 저장소**로 각각 완성한 뒤, 추후 크로스플랫폼으로 통합할지 판단합니다.

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

## 상태

- [x] 인수인계 문서 작성
- [ ] WPF 프로젝트 스캐폴딩
- [ ] 트레이 아이콘 + 항상-위 스트립 창
- [ ] 창 열거 → 탭 렌더링
- [ ] 클릭 → 창 raise
- [ ] 호버 확장/축소 애니메이션
- [ ] 멀티모니터 · 좌우 위치 · 설정 저장
