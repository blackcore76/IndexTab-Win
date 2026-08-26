using IndexTab.Native;

namespace IndexTab.Core;

/// <summary>
/// 현재 연결된 모니터 목록을 물리 픽셀 경계 + DPI 배율과 함께 열거.
/// macOS의 NSScreen.screens 대응.
/// </summary>
public static class DisplayManager
{
    public static List<MonitorInfo> GetMonitors()
    {
        var list = new List<MonitorInfo>();

        NativeMethods.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
            (IntPtr hMonitor, IntPtr hdc, ref NativeMethods.RECT rc, IntPtr data) =>
            {
                var mi = new NativeMethods.MONITORINFOEX { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.MONITORINFOEX>() };
                if (NativeMethods.GetMonitorInfo(hMonitor, ref mi))
                {
                    double scale = 1.0;
                    if (NativeMethods.GetDpiForMonitor(hMonitor, NativeMethods.MDT_EFFECTIVE_DPI, out uint dpiX, out _) == 0 && dpiX > 0)
                        scale = dpiX / 96.0;

                    list.Add(new MonitorInfo
                    {
                        Handle = hMonitor,
                        DeviceName = mi.szDevice,
                        Bounds = mi.rcMonitor,
                        IsPrimary = (mi.dwFlags & NativeMethods.MONITORINFOF_PRIMARY) != 0,
                        DpiScale = scale
                    });
                }
                return true;   // 계속 열거
            }, IntPtr.Zero);

        return list;
    }

    /// <summary>특정 물리 좌표점이 속한 모니터의 deviceName (없으면 null)</summary>
    public static string? DeviceNameAtPoint(int x, int y, List<MonitorInfo> monitors)
    {
        IntPtr h = NativeMethods.MonitorFromPoint(new NativeMethods.POINT(x, y), NativeMethods.MONITOR_DEFAULTTONULL);
        if (h == IntPtr.Zero) return null;
        foreach (var m in monitors)
            if (m.Handle == h) return m.DeviceName;
        return null;
    }
}
