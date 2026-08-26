using System.Windows.Media;

namespace IndexTab.Core;

/// <summary>창 하나에 대한 참조 정보 (macOS WindowRef 대응)</summary>
public sealed class WindowRef
{
    public required IntPtr Hwnd { get; init; }        // macOS windowID 대응 (전역 고유)
    public required string Title { get; init; }       // 정리된 창 제목
    public required uint Pid { get; init; }
    public required Native.NativeMethods.RECT Frame { get; init; }  // 물리 픽셀 전역 좌표
}

/// <summary>한 앱의 특정 모니터 상 상태 (macOS AppOnScreen 대응)</summary>
public sealed class AppOnScreen
{
    public required string Key { get; init; }         // 앱 식별 키 (exe 경로 소문자) = macOS bundleID 역할
    public required string Name { get; init; }        // 표시 이름
    public ImageSource? Icon { get; set; }            // 앱 아이콘
    public required List<WindowRef> Windows { get; init; }  // z-order 상단 순
    public DateTime LastActivated { get; set; }       // 최근 활성화 시각 (정렬용)
}

/// <summary>각 모니터의 앱 목록 스냅샷 (macOS MonitorSnapshot 대응)</summary>
public sealed class MonitorSnapshot
{
    public required string DeviceName { get; init; }  // "\\.\DISPLAY1" — 안정적 식별자
    public required List<AppOnScreen> Apps { get; init; }
}

/// <summary>모니터 정보 — 물리 픽셀 경계 + DPI (macOS NSScreen 대응)</summary>
public sealed class MonitorInfo
{
    public required IntPtr Handle { get; init; }
    public required string DeviceName { get; init; }
    public required Native.NativeMethods.RECT Bounds { get; init; }  // 물리 픽셀 전체 영역
    public required bool IsPrimary { get; init; }
    public required double DpiScale { get; init; }    // 1.0 = 96dpi, 1.5 = 144dpi 등

    /// <summary>논리(DIP) 세로 해상도 — 최대 앱 개수 판정용</summary>
    public double LogicalHeight => Bounds.Height / DpiScale;
}
