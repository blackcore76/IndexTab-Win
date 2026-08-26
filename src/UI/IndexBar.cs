using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using IndexTab.Core;
using IndexTab.Native;
using HAlign = System.Windows.HorizontalAlignment;

namespace IndexTab.UI;

/// <summary>
/// 한 모니터 가장자리에 붙는 세로 인덱스 탭 스트립 창. macOS IndexBar 대응.
///
/// 평소 폭 28(DIP), 탭 호버 시 창을 105로 넓히고 그 탭만 제자리에서 확장.
/// 창 배치는 물리 픽셀 좌표(SetWindowPos)로 직접 하고, 내부 레이아웃은 DIP로.
/// Per-Monitor V2라 창이 해당 모니터에 놓이면 WPF가 그 배율로 알아서 렌더.
/// </summary>
public sealed class IndexBar : Window
{
    // 기본 치수(DIP, macOS 포인트와 동일) — 여기에 UI 배율을 곱해 실제 치수 결정
    private const double BaseCollapsedW = 28;
    private const double BaseExpandedW = 105;
    private const double BaseTabHeight = 105;
    private const double BaseTabOverlap = 8;
    private static readonly Duration Anim = new(TimeSpan.FromSeconds(0.13));

    // UI 배율 적용된 실제 치수 (모니터/설정에 따라 결정)
    private double _scale = 1.0;
    private double CollapsedW => BaseCollapsedW * _scale;
    private double ExpandedW => BaseExpandedW * _scale;
    private double TabHeight => BaseTabHeight * _scale;
    private double TabOverlap => BaseTabOverlap * _scale;

    public string DeviceName { get; private set; }
    private MonitorInfo _monitor;
    private bool _onLeft;

    private readonly Canvas _canvas;
    private readonly List<TabView> _tabs = new();
    private List<string> _appSignature = new();
    private List<AppOnScreen> _apps = new();
    private int? _hoveredIndex;

    private readonly WindowTracker _tracker;

    public IndexBar(MonitorInfo monitor, WindowTracker tracker)
    {
        _monitor = monitor;
        DeviceName = monitor.DeviceName;
        _tracker = tracker;
        _onLeft = Settings.Shared.OnLeft(monitor.DeviceName);
        _scale = Settings.Shared.EffectiveScale(monitor.Bounds.Height);

        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        Topmost = true;
        ResizeMode = ResizeMode.NoResize;
        ShowActivated = false;
        WindowStartupLocation = WindowStartupLocation.Manual;
        // WPF 자체 좌표는 쓰지 않고 SetWindowPos로만 배치하지만, 초기값은 화면 밖 근처로
        Left = -10000; Top = 0; Width = CollapsedW; Height = TabHeight;

        _canvas = new Canvas { HorizontalAlignment = HAlign.Stretch };
        Content = _canvas;

        MouseLeave += (_, _) => OnMouseLeaveBar();

        SourceInitialized += OnSourceInitialized;
    }

    private IntPtr Hwnd => new WindowInteropHelper(this).Handle;

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        // 포커스 안 뺏김 + 도구창(alt-tab 제외) 스타일 부여
        IntPtr h = Hwnd;
        long ex = NativeMethods.GetWindowLongPtr(h, NativeMethods.GWL_EXSTYLE).ToInt64();
        ex |= NativeMethods.WS_EX_NOACTIVATE | NativeMethods.WS_EX_TOOLWINDOW | NativeMethods.WS_EX_TOPMOST;
        NativeMethods.SetWindowLongPtr(h, NativeMethods.GWL_EXSTYLE, new IntPtr(ex));

        // 창은 항상 확장폭(ExpandedW)으로 고정하고, 탭이 없는 빈 영역은 WM_NCHITTEST에서
        // HTTRANSPARENT를 돌려 클릭을 뒤 창으로 통과시킨다. 이렇게 하면 호버 때 창을
        // 리사이즈할 필요가 없어 layered 창 리페인트로 인한 깜빡임이 사라진다.
        HwndSource.FromHwnd(h)?.AddHook(WndProc);
        UpdateGeometry();
    }

    private const int WM_NCHITTEST = 0x0084;
    private static readonly IntPtr HTTRANSPARENT = new(-1);

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_NCHITTEST)
        {
            if (!IsOverTab(lParam))
            {
                handled = true;
                return HTTRANSPARENT;   // 빈 영역 → 클릭 통과
            }
            // 탭 위 → WPF 기본 처리(HTCLIENT)에 맡겨 마우스 이벤트 정상 수신
        }
        return IntPtr.Zero;
    }

    // 화면 좌표(lParam)가 현재 어떤 탭의 렌더 영역 안인지 판정
    private bool IsOverTab(IntPtr lParam)
    {
        int sx = unchecked((short)(lParam.ToInt64() & 0xFFFF));
        int sy = unchecked((short)((lParam.ToInt64() >> 16) & 0xFFFF));
        if (!NativeMethods.GetWindowRect(Hwnd, out var wr)) return true;

        double dpi = _monitor.DpiScale;
        double cx = (sx - wr.Left) / dpi;
        double cy = (sy - wr.Top) / dpi;

        foreach (var tab in _tabs)
        {
            double l = Canvas.GetLeft(tab); if (double.IsNaN(l)) l = 0;
            double t = Canvas.GetTop(tab); if (double.IsNaN(t)) t = 0;
            double w = tab.ActualWidth, ht = tab.ActualHeight;
            if (cx >= l && cx < l + w && cy >= t && cy < t + ht) return true;
        }
        return false;
    }

    // ── 데이터 갱신 (AppController가 폴링 결과로 호출) ───────────────

    public void UpdateApps(List<AppOnScreen> apps, MonitorInfo monitor)
    {
        _monitor = monitor;
        _onLeft = Settings.Shared.OnLeft(monitor.DeviceName);
        _scale = Settings.Shared.EffectiveScale(monitor.Bounds.Height);
        var newSig = apps.Select(a => a.Key).ToList();

        if (newSig.SequenceEqual(_appSignature) && _tabs.Count == apps.Count)
        {
            // 구성 동일 → 재생성 안 함(호버 유지). 데이터만 갱신.
            // 창 지오메트리는 호버와 무관하게 고정이라 갱신 불필요.
            _apps = apps;
            for (int i = 0; i < _tabs.Count; i++) _tabs[i].UpdateApp(apps[i]);
            return;
        }

        _apps = apps;
        _appSignature = newSig;
        RebuildTabs();
        UpdateGeometry();
    }

    private double TotalHeight()
    {
        int count = Math.Max(_apps.Count, 1);
        return count * TabHeight - Math.Max(0, count - 1) * TabOverlap;
    }

    private void RebuildTabs()
    {
        _hoveredIndex = null;
        _canvas.Children.Clear();
        _tabs.Clear();
        if (_apps.Count == 0)
        {
            Visibility = Visibility.Hidden;   // 표시할 앱 없으면 창 숨김
            return;
        }
        Visibility = Visibility.Visible;

        for (int i = 0; i < _apps.Count; i++)
        {
            int index = i;
            var tab = new TabView(_apps[i], _onLeft, CollapsedW, ExpandedW, TabHeight, _scale);
            PlaceTab(tab, index, expanded: false);
            tab.SetExpanded(false);
            Panel.SetZIndex(tab, index);   // 높은 index가 앞 (macOS와 동일: 나중 추가 = 앞)
            tab.HoverEnter += () => SetHovered(index);
            tab.Activated += () =>
            {
                _tracker.MarkActivated(tab.AppKey, DeviceName);
                SetHovered(null);
            };
            _canvas.Children.Add(tab);
            _tabs.Add(tab);
        }
    }

    // 탭을 항상 확장폭(ExpandedW) 기준으로 배치 — 접힘 탭은 바깥 엣지에 앵커.
    private void PlaceTab(TabView tab, int index, bool expanded)
    {
        double tw = expanded ? ExpandedW : CollapsedW;
        double tx = _onLeft ? 0 : (ExpandedW - tw);
        double ty = index * (TabHeight - TabOverlap);
        // 이전 애니메이션이 값을 붙들고 있으면 직접 대입이 막히므로 먼저 해제
        tab.BeginAnimation(WidthProperty, null);
        tab.BeginAnimation(Canvas.LeftProperty, null);
        tab.Width = tw;
        Canvas.SetLeft(tab, tx);
        Canvas.SetTop(tab, ty);
    }

    // ── 창 위치/크기 ─────────────────────────────────────────────
    //
    // 창은 항상 확장폭(ExpandedW)으로 고정한다. 호버해도 크기/위치가 안 변하므로
    // layered 창 리페인트로 인한 깜빡임이 없다. 빈 영역 클릭 통과는 WndProc이 담당.
    // 물리 픽셀 모니터 경계를 그 모니터의 DPI 배율로 나눠 DIP로 환산해 배치한다.

    private void UpdateGeometry()
    {
        double scale = _monitor.DpiScale;
        double totalHDip = TotalHeight();
        var b = _monitor.Bounds;

        double monLeft = b.Left / scale;
        double monRight = b.Right / scale;
        double monTop = b.Top / scale;
        double monHeight = b.Height / scale;

        double x = _onLeft ? monLeft : (monRight - ExpandedW);
        double y = monTop + (monHeight - totalHDip) / 2;

        Left = x;
        Top = y;
        Width = ExpandedW;
        Height = totalHDip;

        _canvas.Width = ExpandedW;
        _canvas.Height = totalHDip;
    }

    // ── 호버 확장/축소 ───────────────────────────────────────────

    // 마우스가 탭 영역을 벗어나면 축소. 창은 리사이즈되지 않고, 탭 밖은 NCHITTEST가
    // HTTRANSPARENT라 여기 MouseLeave는 "실제로 탭에서 벗어남"을 뜻한다(오발화 없음).
    private void OnMouseLeaveBar() => SetHovered(null);

    private void SetHovered(int? index)
    {
        if (index == _hoveredIndex) return;
        int? old = _hoveredIndex;
        _hoveredIndex = index;

        if (old == null && index is int i1) ExpandFromCollapsed(i1);
        else if (index == null && old is int o1) CollapseToIdle(o1);
        else if (old is int o2 && index is int i2) SwitchHover(o2, i2);
    }

    private void ExpandFromCollapsed(int i)
    {
        if (i >= _tabs.Count) return;
        // 창은 이미 확장폭 고정 → 리사이즈 없음. 그 탭만 제자리에서 펼친다.
        var tab = _tabs[i];
        Panel.SetZIndex(tab, _tabs.Count + 1);
        tab.SetExpanded(true);
        AnimateTab(tab, i, toExpanded: true);
    }

    private void CollapseToIdle(int o)
    {
        if (o >= _tabs.Count) return;
        var tab = _tabs[o];
        tab.SetExpanded(false);
        AnimateTab(tab, o, toExpanded: false, onComplete: () =>
        {
            if (_hoveredIndex != null) return;   // 그 사이 다시 호버되면 취소
            Panel.SetZIndex(tab, o);
        });
    }

    private void SwitchHover(int o, int i)
    {
        if (o >= _tabs.Count || i >= _tabs.Count) return;
        var oldTab = _tabs[o];
        oldTab.SetExpanded(false);
        Panel.SetZIndex(oldTab, o);
        AnimateTab(oldTab, o, toExpanded: false);

        var newTab = _tabs[i];
        Panel.SetZIndex(newTab, _tabs.Count + 1);
        newTab.SetExpanded(true);
        AnimateTab(newTab, i, toExpanded: true);
    }

    // 탭의 Width + Canvas.Left를 목표 상태로 0.13초 easeOut 애니메이션
    private void AnimateTab(TabView tab, int index, bool toExpanded, Action? onComplete = null)
    {
        double tw = toExpanded ? ExpandedW : CollapsedW;
        double targetLeft = _onLeft ? 0 : (ExpandedW - tw);
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };

        var widthAnim = new DoubleAnimation(tw, Anim) { EasingFunction = ease };
        var leftAnim = new DoubleAnimation(targetLeft, Anim) { EasingFunction = ease };

        widthAnim.Completed += (_, _) =>
        {
            // 애니메이션 종료 후 base 값을 목표로 고정하고 클록 해제
            // → 이후 직접 대입(PlaceTab)이 정상 동작
            tab.Width = tw;
            tab.BeginAnimation(WidthProperty, null);
            Canvas.SetLeft(tab, targetLeft);
            tab.BeginAnimation(Canvas.LeftProperty, null);
            onComplete?.Invoke();
        };

        tab.BeginAnimation(WidthProperty, widthAnim);
        tab.BeginAnimation(Canvas.LeftProperty, leftAnim);
    }

    public void CloseBar() => Close();
}
