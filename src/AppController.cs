using System.Drawing;
using System.IO;
using System.Windows;
using System.Windows.Threading;
using IndexTab.Core;
using IndexTab.UI;
using Microsoft.Win32;
using WinForms = System.Windows.Forms;

namespace IndexTab;

/// <summary>
/// 트레이 아이콘 + 메뉴, 모니터별 스트립 생성/재생성, 화면 구성 변경 감지.
/// macOS AppDelegate 대응.
/// </summary>
public sealed class AppController : IDisposable
{
    private WinForms.NotifyIcon _tray = null!;
    private WindowTracker _tracker = null!;
    private readonly Dictionary<string, IndexBar> _bars = new();
    private DispatcherTimer? _rebuildDebounce;

    private const string Version = "0.1.1";

    public void Start()
    {
        SetupTray();
        SetupTracker();
        RebuildBars();

        // 화면 구성/해상도/DPI 변경 감지 → 디바운스 후 재생성
        SystemEvents.DisplaySettingsChanged += OnDisplaysChanged;
    }

    // ── 트레이 ───────────────────────────────────────────────────

    private void SetupTray()
    {
        _tray = new WinForms.NotifyIcon
        {
            Icon = LoadTrayIcon(),
            Visible = true,
            Text = "IndexTab",
        };
        _tray.ContextMenuStrip = BuildMenu();
        // 메뉴 열릴 때마다 최신 모니터 목록으로 다시 구성
        _tray.ContextMenuStrip.Opening += (_, _) => RefreshMenu(_tray.ContextMenuStrip);
    }

    private static Icon LoadTrayIcon()
    {
        try
        {
            string icoPath = Path.Combine(AppContext.BaseDirectory, "Assets", "app.ico");
            if (File.Exists(icoPath)) return new Icon(icoPath, 32, 32);   // 트레이용 소형
        }
        catch { }
        return SystemIcons.Application;   // 아이콘 리소스 없으면 기본 아이콘
    }

    private WinForms.ContextMenuStrip BuildMenu()
    {
        var menu = new WinForms.ContextMenuStrip();
        RefreshMenu(menu);
        return menu;
    }

    private void RefreshMenu(WinForms.ContextMenuStrip menu)
    {
        menu.Items.Clear();

        var header = new WinForms.ToolStripMenuItem("모니터별 설정") { Enabled = false };
        menu.Items.Add(header);

        var monitors = DisplayManager.GetMonitors();
        for (int i = 0; i < monitors.Count; i++)
        {
            var m = monitors[i];
            string label = $"모니터 {i + 1}{(m.IsPrimary ? " (주)" : "")}";
            var sub = new WinForms.ToolStripMenuItem(label);

            bool enabled = Settings.Shared.IsEnabled(m.DeviceName);
            bool onLeft = Settings.Shared.OnLeft(m.DeviceName);

            var enableItem = new WinForms.ToolStripMenuItem(enabled ? "✓ 활성화" : "비활성화됨")
            { Checked = enabled };
            string dev = m.DeviceName;
            enableItem.Click += (_, _) =>
            {
                Settings.Shared.SetEnabled(dev, !Settings.Shared.IsEnabled(dev));
                RebuildBars();
            };
            sub.DropDownItems.Add(enableItem);
            sub.DropDownItems.Add(new WinForms.ToolStripSeparator());

            var rightItem = new WinForms.ToolStripMenuItem("오른쪽 (3시)") { Checked = !onLeft };
            rightItem.Click += (_, _) => { Settings.Shared.SetOnLeft(dev, false); RebuildBars(); };
            sub.DropDownItems.Add(rightItem);

            var leftItem = new WinForms.ToolStripMenuItem("왼쪽 (9시)") { Checked = onLeft };
            leftItem.Click += (_, _) => { Settings.Shared.SetOnLeft(dev, true); RebuildBars(); };
            sub.DropDownItems.Add(leftItem);

            menu.Items.Add(sub);
        }

        menu.Items.Add(new WinForms.ToolStripSeparator());

        // 탭 크기(배율) — 자동 + 수동 고정. 4K@100% 처럼 작게 나오는 환경 대응.
        var sizeMenu = new WinForms.ToolStripMenuItem("탭 크기");
        double cur = Settings.Shared.UiScale;   // 0 = 자동
        void AddScale(string label, double value)
        {
            var it = new WinForms.ToolStripMenuItem(label) { Checked = Math.Abs(cur - value) < 0.001 };
            it.Click += (_, _) => { Settings.Shared.SetUiScale(value); RebuildBars(); };
            sizeMenu.DropDownItems.Add(it);
        }
        AddScale("자동", 0);
        sizeMenu.DropDownItems.Add(new WinForms.ToolStripSeparator());
        AddScale("100%", 1.0);
        AddScale("110%", 1.1);
        AddScale("125%", 1.25);
        AddScale("150%", 1.5);
        menu.Items.Add(sizeMenu);

        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add(new WinForms.ToolStripMenuItem($"IndexTab v{Version}") { Enabled = false });

        var restart = new WinForms.ToolStripMenuItem("IndexTab 재시작");
        restart.Click += (_, _) => RestartApp();
        menu.Items.Add(restart);

        var quit = new WinForms.ToolStripMenuItem("IndexTab 종료");
        quit.Click += (_, _) => Application.Current.Shutdown();
        menu.Items.Add(quit);
    }

    private void RestartApp()
    {
        try
        {
            string? exe = Environment.ProcessPath;
            if (exe != null) System.Diagnostics.Process.Start(exe);
        }
        catch { }
        Application.Current.Shutdown();
    }

    // ── 트래커 · 스트립 관리 ─────────────────────────────────────

    private void SetupTracker()
    {
        _tracker = new WindowTracker { OnUpdate = ApplySnapshots };
        _tracker.Start();
    }

    private void RebuildBars()
    {
        foreach (var bar in _bars.Values) bar.CloseBar();
        _bars.Clear();

        foreach (var m in DisplayManager.GetMonitors())
        {
            if (!Settings.Shared.IsEnabled(m.DeviceName)) continue;
            var bar = new IndexBar(m, _tracker);
            bar.Show();
            _bars[m.DeviceName] = bar;
        }
    }

    private void ApplySnapshots(List<MonitorSnapshot> snapshots)
    {
        var monitors = DisplayManager.GetMonitors();
        foreach (var snap in snapshots)
        {
            if (!_bars.TryGetValue(snap.DeviceName, out var bar)) continue;
            var m = monitors.FirstOrDefault(x => x.DeviceName == snap.DeviceName);
            if (m == null) continue;
            bar.UpdateApps(snap.Apps, m);
        }
    }

    private void OnDisplaysChanged(object? sender, EventArgs e)
    {
        _rebuildDebounce?.Stop();
        _rebuildDebounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        _rebuildDebounce.Tick += (_, _) =>
        {
            _rebuildDebounce!.Stop();
            RebuildBars();
        };
        _rebuildDebounce.Start();
    }

    public void Dispose()
    {
        SystemEvents.DisplaySettingsChanged -= OnDisplaysChanged;
        _tracker?.Stop();
        foreach (var bar in _bars.Values) bar.CloseBar();
        _bars.Clear();
        if (_tray != null)
        {
            _tray.Visible = false;
            _tray.Dispose();
        }
    }
}
