using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using IndexTab.Native;

namespace IndexTab.Core;

/// <summary>
/// 1.5초 주기로 전체 창 목록을 폴링해 모니터별 앱 스냅샷을 만드는 트래커.
/// macOS WindowTracker 대응 — 이 앱의 핵심 데이터 소스.
/// </summary>
public sealed class WindowTracker
{
    /// <summary>스냅샷 갱신 콜백 (UI 스레드로 마샬링해서 호출됨)</summary>
    public Action<List<MonitorSnapshot>>? OnUpdate;

    private System.Threading.Timer? _timer;
    private readonly uint _myPid = (uint)Environment.ProcessId;

    // "deviceName|appKey" → 마지막 활성 시각 (클릭 직후 즉시 반영용)
    private readonly Dictionary<string, DateTime> _lastActivated = new();

    // exe 경로 → (표시이름, 아이콘) 캐시 — 매 폴링마다 재추출 방지
    private readonly Dictionary<string, (string name, ImageSource? icon)> _appMetaCache = new(StringComparer.OrdinalIgnoreCase);

    public void Start()
    {
        Refresh();
        _timer = new System.Threading.Timer(_ => Refresh(), null,
            TimeSpan.FromSeconds(1.5), TimeSpan.FromSeconds(1.5));
    }

    public void Stop()
    {
        _timer?.Dispose();
        _timer = null;
    }

    /// <summary>특정 앱이 특정 모니터에서 활성화됐다고 마킹 (클릭 직후 정렬 즉시 반영)</summary>
    public void MarkActivated(string appKey, string deviceName)
    {
        _lastActivated[$"{deviceName}|{appKey}"] = DateTime.UtcNow;
    }

    private void Refresh()
    {
        try
        {
            var snapshots = BuildSnapshots();
            // UI 스레드로 마샬링
            Application.Current?.Dispatcher.BeginInvoke(() => OnUpdate?.Invoke(snapshots));
        }
        catch { /* 폴링 한 번 실패는 무시하고 다음 주기에 재시도 */ }
    }

    private List<MonitorSnapshot> BuildSnapshots()
    {
        var monitors = DisplayManager.GetMonitors();
        IntPtr shell = NativeMethods.GetShellWindow();

        // deviceName → appKey → windows (EnumWindows는 상단 z-order부터 열거)
        var perDisplay = new Dictionary<string, Dictionary<string, List<WindowRef>>>();
        var appMeta = new Dictionary<string, (string name, ImageSource? icon)>();

        NativeMethods.EnumWindows((hWnd, _) =>
        {
            if (!IsAltTabWindow(hWnd, shell)) return true;

            NativeMethods.GetWindowThreadProcessId(hWnd, out uint pid);
            if (pid == _myPid || pid == 0) return true;

            // 창 경계 획득. 최소화된 창은 GetWindowRect가 (-32000,-32000)을 주므로
            // 모니터 판별이 안 됨 → GetWindowPlacement의 rcNormalPosition(복원 시 위치)로
            // 어느 모니터에 속한 앱인지 판단한다. 이렇게 해야 최소화해도 탭이 남고,
            // 그 탭을 클릭하면 복원(WindowActivator가 SW_RESTORE)된다.
            NativeMethods.RECT frame;
            if (NativeMethods.IsIconic(hWnd))
            {
                var wp = new NativeMethods.WINDOWPLACEMENT { length = Marshal.SizeOf<NativeMethods.WINDOWPLACEMENT>() };
                if (!NativeMethods.GetWindowPlacement(hWnd, ref wp)) return true;
                frame = wp.rcNormalPosition;   // 복원 시 좌표(화면 좌표계)
            }
            else if (NativeMethods.DwmGetWindowAttribute(hWnd, NativeMethods.DWMWA_EXTENDED_FRAME_BOUNDS,
                         out frame, Marshal.SizeOf<NativeMethods.RECT>()) != 0)
            {
                // 실제 창 경계(그림자 제외) 실패 시 GetWindowRect로 폴백
                if (!NativeMethods.GetWindowRect(hWnd, out frame)) return true;
            }

            // 너무 작은 창(툴팁·팝업 등) 무시
            if (frame.Width < 60 || frame.Height < 40) return true;

            // 창 중심이 속한 모니터 판별
            int cx = frame.Left + frame.Width / 2;
            int cy = frame.Top + frame.Height / 2;
            string? device = DisplayManager.DeviceNameAtPoint(cx, cy, monitors);
            if (device == null) return true;

            string exePath = GetProcessPath(pid);
            if (string.IsNullOrEmpty(exePath)) return true;
            string appKey = exePath.ToLowerInvariant();   // = macOS bundleID 역할

            string rawTitle = GetWindowTitle(hWnd);

            var meta = GetAppMeta(exePath);
            string cleanedTitle = CleanTitle(rawTitle, meta.name);

            var wref = new WindowRef { Hwnd = hWnd, Title = cleanedTitle, Pid = pid, Frame = frame };

            if (!perDisplay.TryGetValue(device, out var byApp))
                perDisplay[device] = byApp = new();
            if (!byApp.TryGetValue(appKey, out var wins))
                byApp[appKey] = wins = new();
            wins.Add(wref);

            appMeta.TryAdd(appKey, meta);

            return true;
        }, IntPtr.Zero);

        // 모니터별로 AppOnScreen 정리 → 최대 개수 규칙 → 이름순 고정 (핸드오프 §2)
        var result = new List<MonitorSnapshot>();
        foreach (var m in monitors)
        {
            var byApp = perDisplay.TryGetValue(m.DeviceName, out var d) ? d : new();
            var apps = new List<AppOnScreen>();

            foreach (var (appKey, wins) in byApp)
            {
                var meta = appMeta.TryGetValue(appKey, out var mm) ? mm : (appKey, (ImageSource?)null);
                _lastActivated.TryGetValue($"{m.DeviceName}|{appKey}", out var last);
                apps.Add(new AppOnScreen
                {
                    Key = appKey,
                    Name = meta.Item1,
                    Icon = meta.Item2,
                    Windows = wins,
                    LastActivated = last
                });
            }

            int maxCount = Settings.MaxApps(m.LogicalHeight);
            if (apps.Count > maxCount)
            {
                // 어느 앱을 자를지는 최근 활성화순, 남은 건 다시 이름순
                apps.Sort((a, b) =>
                {
                    int c = b.LastActivated.CompareTo(a.LastActivated);
                    return c != 0 ? c : string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase);
                });
                apps = apps.GetRange(0, maxCount);
            }
            apps.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase));

            result.Add(new MonitorSnapshot { DeviceName = m.DeviceName, Apps = apps });
        }

        return result;
    }

    // ── 창 필터 (alt-tab 목록에 뜰 법한 "진짜 앱 창"인가) ─────────────

    private static bool IsAltTabWindow(IntPtr hWnd, IntPtr shell)
    {
        if (hWnd == shell) return false;
        if (!NativeMethods.IsWindowVisible(hWnd)) return false;
        if (NativeMethods.GetWindowTextLength(hWnd) == 0) return false;

        long ex = NativeMethods.GetWindowLongPtr(hWnd, NativeMethods.GWL_EXSTYLE).ToInt64();
        bool isAppWindow = (ex & NativeMethods.WS_EX_APPWINDOW) != 0;
        bool isToolWindow = (ex & NativeMethods.WS_EX_TOOLWINDOW) != 0;

        // 소유된 창(대화상자·팝업)은 제외 — 단 명시적 APPWINDOW면 허용
        IntPtr owner = NativeMethods.GetWindow(hWnd, NativeMethods.GW_OWNER);
        if (!isAppWindow)
        {
            if (isToolWindow) return false;
            if (owner != IntPtr.Zero) return false;
        }

        // 가상 데스크톱 등으로 숨겨진(cloaked) 창 제외
        if (NativeMethods.DwmGetWindowAttribute(hWnd, NativeMethods.DWMWA_CLOAKED,
                out int cloaked, sizeof(int)) == 0 && cloaked != 0)
            return false;

        return true;
    }

    private static string GetWindowTitle(IntPtr hWnd)
    {
        int len = NativeMethods.GetWindowTextLength(hWnd);
        if (len == 0) return "";
        var sb = new StringBuilder(len + 1);
        NativeMethods.GetWindowText(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    private static string GetProcessPath(uint pid)
    {
        IntPtr h = NativeMethods.OpenProcess(NativeMethods.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == IntPtr.Zero) return "";
        try
        {
            var sb = new StringBuilder(1024);
            uint size = (uint)sb.Capacity;
            return NativeMethods.QueryFullProcessImageName(h, 0, sb, ref size) ? sb.ToString() : "";
        }
        finally { NativeMethods.CloseHandle(h); }
    }

    // exe 경로 → 표시이름 + 아이콘 (캐시)
    private (string name, ImageSource? icon) GetAppMeta(string exePath)
    {
        if (_appMetaCache.TryGetValue(exePath, out var cached)) return cached;

        string name;
        try
        {
            var fvi = FileVersionInfo.GetVersionInfo(exePath);
            name = !string.IsNullOrWhiteSpace(fvi.FileDescription)
                ? fvi.FileDescription!.Trim()
                : Path.GetFileNameWithoutExtension(exePath);
        }
        catch { name = Path.GetFileNameWithoutExtension(exePath); }
        if (string.IsNullOrWhiteSpace(name)) name = Path.GetFileNameWithoutExtension(exePath);

        ImageSource? icon = ExtractIcon(exePath);

        var meta = (name, icon);
        _appMetaCache[exePath] = meta;
        return meta;
    }

    private static ImageSource? ExtractIcon(string exePath)
    {
        try
        {
            using var ico = System.Drawing.Icon.ExtractAssociatedIcon(exePath);
            if (ico == null) return null;
            var src = Imaging.CreateBitmapSourceFromHIcon(
                ico.Handle, System.Windows.Int32Rect.Empty,
                BitmapSizeOptions.FromEmptyOptions());
            src.Freeze();   // 백그라운드 스레드에서 만든 이미지를 UI 스레드에서 쓰려면 필수
            return src;
        }
        catch { return null; }
    }

    // 앱별 창 제목 정리 — 브라우저 접미사 등 제거 (macOS cleanTitle 대응)
    private static string CleanTitle(string raw, string appName)
    {
        string t = raw;
        string[] suffixes =
        {
            " - Google Chrome", " - Chromium", " - Microsoft Edge",
            " — Mozilla Firefox", " - Mozilla Firefox", " - Brave", " - Whale"
        };
        foreach (var s in suffixes)
        {
            if (t.EndsWith(s, StringComparison.Ordinal))
            {
                t = t[..^s.Length];
                break;
            }
        }
        if (string.IsNullOrWhiteSpace(t)) t = appName;
        return t;
    }
}
