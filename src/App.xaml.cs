using System.Windows;

namespace IndexTab;

/// <summary>
/// 앱 진입점. macOS의 main.swift + AppDelegate(초반부) 대응.
/// 실제 트레이/스트립 관리는 AppController가 담당.
/// </summary>
public partial class App : Application
{
    private AppController? _controller;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _controller = new AppController();
        _controller.Start();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _controller?.Dispose();
        base.OnExit(e);
    }
}
