using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using IndexTab.Core;
// FrameworkElement에 동명(同名) 인스턴스 속성이 있어 enum 타입명이 가려지므로 별칭 사용
using HAlign = System.Windows.HorizontalAlignment;
using VAlign = System.Windows.VerticalAlignment;

namespace IndexTab.UI;

/// <summary>
/// 탭 하나. macOS TabView 대응.
/// 평소(collapsed): 세로 텍스트 28px. 확장(expanded): 아이콘+이름 105px.
/// 두 콘텐츠를 미리 만들어 두고 Visibility만 전환 → 호버 시 재렌더 지연 제거.
/// </summary>
public sealed class TabView : Border
{
    private AppOnScreen _app;
    private readonly bool _onLeft;
    private readonly double _collapsedW;
    private readonly double _expandedW;
    private readonly double _height;
    private readonly double _scale;

    private readonly Grid _root;
    private FrameworkElement _collapsedContent = null!;
    private FrameworkElement _expandedContent = null!;
    private readonly LinearGradientBrush _bgBrush;

    // 대기=진회색, 호버 확장=슬레이트 그레이 (macOS와 동일 색)
    private static readonly Color IdleBase = Color.FromArgb(0xF2, 0x3A, 0x3A, 0x3C);   // alpha ~0.95
    private static readonly Color HoverBase = Color.FromArgb(0xFA, 0x70, 0x80, 0x90);  // alpha ~0.98

    // 기본 여백/아이콘 (DIP, macOS 포인트와 동일) — _scale을 곱해 사용
    private const double BaseTopInset = 8;
    private const double BaseBottomInset = 5;
    private const double BaseIconSize = 44;
    private double TopInset => BaseTopInset * _scale;
    private double BottomInset => BaseBottomInset * _scale;
    private double IconSize => BaseIconSize * _scale;

    public event Action? HoverEnter;
    public event Action? Activated;

    public string AppKey => _app.Key;

    public TabView(AppOnScreen app, bool onLeft, double collapsedW, double expandedW, double height, double scale)
    {
        _app = app;
        _onLeft = onLeft;
        _collapsedW = collapsedW;
        _expandedW = expandedW;
        _height = height;
        _scale = scale;

        Width = collapsedW;
        Height = height;
        CornerRadius = EdgeCorner(12 * _scale);   // 페이지마커: 바깥 엣지는 각지게, 안쪽만 둥글게
        SnapsToDevicePixels = true;

        // 세로 그라데이션(위 밝음 → 아래 어두움) — 층 입체감
        _bgBrush = new LinearGradientBrush { StartPoint = new Point(0.5, 0), EndPoint = new Point(0.5, 1) };
        Background = _bgBrush;
        BorderThickness = new Thickness(1);
        BorderBrush = new SolidColorBrush(Color.FromArgb(0x1A, 0xFF, 0xFF, 0xFF));

        // seam 그림자 — 앞(아래 index) 탭이 뒤 탭 위로 또렷한 그림자
        Effect = new DropShadowEffect
        {
            Color = Colors.Black,
            Opacity = 0.5,
            BlurRadius = 4,
            ShadowDepth = 3,
            Direction = 270,   // 아래로 그림자 → seam 경계 강조
        };

        _root = new Grid();
        Child = _root;

        BuildContents();
        ApplyGradient(expanded: false);

        MouseEnter += (_, _) => HoverEnter?.Invoke();
        MouseLeftButtonDown += OnLeftClick;
        MouseRightButtonUp += OnRightClick;
    }

    // ── 확장/축소 상태 전환 (표시만 바꿈; 위치/폭 애니메이션은 IndexBar가 담당) ──

    public void SetExpanded(bool expanded)
    {
        _collapsedContent.Visibility = expanded ? Visibility.Collapsed : Visibility.Visible;
        _expandedContent.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        CornerRadius = EdgeCorner((expanded ? 16 : 12) * _scale);
        BorderBrush = new SolidColorBrush(Color.FromArgb(expanded ? (byte)0x28 : (byte)0x1A, 0xFF, 0xFF, 0xFF));
        ApplyGradient(expanded);
    }

    // 페이지마커 모양: 화면 안쪽 모서리만 둥글게, 바깥(엣지) 모서리는 각지게.
    // CornerRadius(topLeft, topRight, bottomRight, bottomLeft)
    //   오른쪽 엣지(onLeft=false) → 왼쪽(안쪽) 모서리만 둥글게
    //   왼쪽 엣지(onLeft=true)    → 오른쪽(안쪽) 모서리만 둥글게
    private CornerRadius EdgeCorner(double r)
        => _onLeft ? new CornerRadius(0, r, r, 0)
                   : new CornerRadius(r, 0, 0, r);

    private void ApplyGradient(bool expanded)
    {
        Color baseC = expanded ? HoverBase : IdleBase;
        Color top = Blend(baseC, Colors.White, 0.10);
        Color bottom = Blend(baseC, Colors.Black, 0.14);
        _bgBrush.GradientStops.Clear();
        _bgBrush.GradientStops.Add(new GradientStop(top, 0));
        _bgBrush.GradientStops.Add(new GradientStop(bottom, 1));
    }

    private static Color Blend(Color c, Color with, double f)
    {
        byte L(byte a, byte b) => (byte)(a * (1 - f) + b * f);
        return Color.FromArgb(c.A, L(c.R, with.R), L(c.G, with.G), L(c.B, with.B));
    }

    // 앱 데이터 갱신 (재생성 없이). 이름 바뀌면 콘텐츠만 다시 그림.
    public void UpdateApp(AppOnScreen newApp)
    {
        bool nameChanged = newApp.Name != _app.Name;
        bool iconChanged = !ReferenceEquals(newApp.Icon, _app.Icon);
        _app = newApp;
        if (nameChanged || iconChanged)
        {
            _root.Children.Clear();
            BuildContents();
            // 현재 표시 상태 유지
            bool expanded = _expandedContent.Visibility == Visibility.Visible;
            SetExpanded(expanded);
        }
    }

    // ── 콘텐츠 구성 ─────────────────────────────────────────────

    private void BuildContents()
    {
        _collapsedContent = BuildCollapsed();
        _collapsedContent.HorizontalAlignment = _onLeft ? HAlign.Left : HAlign.Right;
        _collapsedContent.Width = _collapsedW;
        _root.Children.Add(_collapsedContent);

        _expandedContent = BuildExpanded();
        _expandedContent.HorizontalAlignment = _onLeft ? HAlign.Left : HAlign.Right;
        _expandedContent.Width = _expandedW;
        _expandedContent.Visibility = Visibility.Collapsed;
        _root.Children.Add(_expandedContent);
    }

    // 평소: 세로 텍스트 (CJK=똑바로 위→아래 / 영문=90° 눕혀 아래→위)
    // 내용을 collapsedW 폭의 Grid로 감싸 중앙 배치. 회전 텍스트에 Width를 강제하면
    // 글자가 잘리므로, 폭 제약은 host(Grid)에만 걸고 텍스트는 자연 크기로 둔다.
    private FrameworkElement BuildCollapsed()
    {
        string display = CollapsedName(_app.Name);
        double availH = _height - TopInset - BottomInset;   // 세로로 쓸 수 있는 길이

        var host = new Grid();   // 폭은 BuildContents에서 collapsedW로 설정

        if (ContainsCJK(display))
        {
            // 글자를 위→아래로 똑바로 쌓기
            var panel = new StackPanel
            {
                Orientation = Orientation.Vertical,
                HorizontalAlignment = HAlign.Center,
                VerticalAlignment = VAlign.Center,
                Margin = new Thickness(0, TopInset, 0, BottomInset),
            };
            double letterH = Math.Min(18 * _scale, availH / Math.Max(1, display.Length));
            double fontSize = Math.Max(9 * _scale, letterH * 0.72);
            foreach (char ch in display)
            {
                panel.Children.Add(new TextBlock
                {
                    Text = ch.ToString(),
                    FontSize = fontSize,
                    FontWeight = FontWeights.Bold,
                    Foreground = Brushes.White,
                    TextAlignment = TextAlignment.Center,
                    HorizontalAlignment = HAlign.Center,
                    Height = letterH,
                    LineHeight = letterH,
                });
            }
            host.Children.Add(panel);
        }
        else
        {
            // 영문/숫자 → 텍스트를 눕혀 아래→위로 (반시계 90°)
            // 회전 전 Width(=회전 후 세로 길이)를 availH로 제한 + 말줄임 → 세로 넘침 방지
            var tb = new TextBlock
            {
                Text = display,
                FontSize = 14 * _scale,
                FontStyle = FontStyles.Italic,
                FontWeight = FontWeights.Medium,
                Foreground = Brushes.White,
                HorizontalAlignment = HAlign.Center,
                VerticalAlignment = VAlign.Center,
                TextAlignment = TextAlignment.Center,
                MaxWidth = availH,
                TextTrimming = TextTrimming.CharacterEllipsis,
                TextWrapping = TextWrapping.NoWrap,
                LayoutTransform = new RotateTransform(-90),   // 아래→위
            };
            host.Children.Add(tb);
        }

        return host;
    }

    // 확장: 아이콘(44) + 이름 한 줄, 세로 중앙
    private FrameworkElement BuildExpanded()
    {
        var stack = new StackPanel
        {
            Orientation = Orientation.Vertical,
            HorizontalAlignment = HAlign.Center,
            VerticalAlignment = VAlign.Center,
        };

        var icon = new Image
        {
            Width = IconSize,
            Height = IconSize,
            Source = _app.Icon,
            HorizontalAlignment = HAlign.Center,
            Margin = new Thickness(0, 0, 0, 5 * _scale),
        };
        RenderOptions.SetBitmapScalingMode(icon, BitmapScalingMode.HighQuality);
        stack.Children.Add(icon);

        stack.Children.Add(new TextBlock
        {
            Text = _app.Name,
            FontSize = 12 * _scale,
            FontStyle = FontStyles.Italic,
            Foreground = Brushes.White,
            TextAlignment = TextAlignment.Center,
            HorizontalAlignment = HAlign.Center,
            MaxWidth = _expandedW - 6 * _scale,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
        });

        return stack;
    }

    // 접힌(세로) 탭에 쓸 짧은 표기명 만들기.
    // 한글+영문 혼용 이름은 영문 토큰을 떼고 CJK 코어만 남긴다.
    //   "Windows 탐색기" → "탐색기",  "Google 계정" → "계정"
    // 순수 영문/순수 한글은 원래대로. (호버 확장 탭은 전체 이름을 따로 보여줌)
    private string CollapsedName(string name)
    {
        string display = PreferCjkCore(name);
        string stripped = new string(display.Where(c => !char.IsWhiteSpace(c)).ToArray());
        bool cjk = ContainsCJK(stripped);
        int limit = cjk ? 12 : 20;
        if (stripped.Length <= limit) return stripped;
        return string.Concat(stripped.AsSpan(0, limit - 1), "…");
    }

    // 한글(CJK)과 라틴 문자가 섞여 있으면 라틴 토큰을 버리고 CJK만 남긴다.
    private static string PreferCjkCore(string name)
    {
        bool hasCjk = ContainsCJK(name);
        bool hasLatin = name.Any(c => c is (>= 'A' and <= 'Z') or (>= 'a' and <= 'z'));
        if (!hasCjk || !hasLatin) return name;   // 혼용이 아니면 그대로

        // CJK 문자와 공백만 유지 → 라틴 단어·숫자·기호 제거 후 공백 정리
        var kept = new string(name.Where(c => IsCjkChar(c) || char.IsWhiteSpace(c)).ToArray());
        kept = string.Join(" ", kept.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        return kept.Length > 0 ? kept : name;    // 남는 게 없으면 원래 이름
    }

    private static bool IsCjkChar(char c)
    {
        int v = c;
        return v is (>= 0xAC00 and <= 0xD7A3)   // 한글 음절
            or (>= 0x1100 and <= 0x11FF)         // 한글 자모
            or (>= 0x4E00 and <= 0x9FFF)         // 한자
            or (>= 0x3040 and <= 0x30FF);        // 히라가나·가타카나
    }

    private static bool ContainsCJK(string s)
    {
        foreach (char c in s)
            if (IsCjkChar(c)) return true;
        return false;
    }

    // ── 클릭 ────────────────────────────────────────────────────

    private void OnLeftClick(object sender, MouseButtonEventArgs e)
    {
        var win = _app.Windows.FirstOrDefault();
        if (win != null)
            WindowActivator.Raise(win.Hwnd);
        Activated?.Invoke();
    }

    private void OnRightClick(object sender, MouseButtonEventArgs e)
    {
        if (_app.Windows.Count <= 1)
        {
            var win = _app.Windows.FirstOrDefault();
            if (win != null) WindowActivator.Raise(win.Hwnd);
            Activated?.Invoke();
            return;
        }

        // 메뉴는 창 생성순(HWND 값 오름차순) 고정 → z-order 바뀌어도 순서 유지
        var menu = new ContextMenu();
        foreach (var w in _app.Windows.OrderBy(w => w.Hwnd.ToInt64()))
        {
            var item = new MenuItem { Header = w.Title };
            IntPtr hwnd = w.Hwnd;
            item.Click += (_, _) =>
            {
                WindowActivator.Raise(hwnd);
                Activated?.Invoke();
            };
            menu.Items.Add(item);
        }
        menu.IsOpen = true;
    }
}
