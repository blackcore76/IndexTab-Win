using System.IO;
using System.Text.Json;

namespace IndexTab.Core;

/// <summary>
/// 영구 설정 저장 — macOS의 UserDefaults 대응.
/// %APPDATA%\IndexTab\settings.json 에 JSON으로 저장.
///
/// 모니터 식별자는 macOS의 displayID 대신 GetMonitorInfo의 szDevice(예 "\\.\DISPLAY1")
/// 를 키로 사용한다. 재부팅해도 같은 물리 배치면 유지되는 안정적 식별자.
/// </summary>
public sealed class Settings
{
    public static Settings Shared { get; } = Load();

    // 모니터별 좌우 위치 — deviceName → onLeft(true=왼쪽/9시, false=오른쪽/3시). 기본 오른쪽.
    public Dictionary<string, bool> SidePerDisplay { get; set; } = new();

    // 모니터별 활성화 — deviceName → enabled. 저장 안 된 모니터는 기본 켜짐.
    public Dictionary<string, bool> EnabledPerDisplay { get; set; } = new();

    // UI 배율. 0 = 자동(논리 해상도 기준으로 계산). 그 외 값(예 1.0/1.5/2.0)은 수동 고정.
    // 4K@100% 처럼 물리 픽셀이 작게 잡히는 환경에서 탭을 키우기 위한 것.
    public double UiScale { get; set; } = 0;

    public void SetUiScale(double s)
    {
        UiScale = s;
        Save();
    }

    /// <summary>
    /// 실효 배율. UiScale이 0이면 물리 세로 해상도(1440 기준)로 자동 산정(1.0~2.0).
    /// 물리 기준이라 DPI 배율과 무관하게 4K(2160)는 자동 1.5배가 되어 커진다.
    /// (예: 4K@150% → dpi 1.5 × auto 1.5 = 큼직, 1440p → 1.0으로 macOS 동일 비율)
    /// </summary>
    public double EffectiveScale(double physicalHeight)
    {
        if (UiScale > 0) return UiScale;
        double auto = physicalHeight / 1440.0;
        return Math.Clamp(auto, 1.0, 2.0);
    }

    // ── 조회/변경 헬퍼 ──────────────────────────────────────────

    public bool OnLeft(string deviceName)
        => SidePerDisplay.TryGetValue(deviceName, out var v) && v;

    public void SetOnLeft(string deviceName, bool onLeft)
    {
        SidePerDisplay[deviceName] = onLeft;
        Save();
    }

    public bool IsEnabled(string deviceName)
        => !EnabledPerDisplay.TryGetValue(deviceName, out var v) || v;   // 기본 true

    public void SetEnabled(string deviceName, bool enabled)
    {
        EnabledPerDisplay[deviceName] = enabled;
        Save();
    }

    /// <summary>해상도별 최대 표시 앱 개수 — 논리 세로 1080 초과=12, 이하=10 (핸드오프 §2)</summary>
    public static int MaxApps(double logicalHeight) => logicalHeight > 1080 ? 12 : 10;

    // ── 저장/로드 ───────────────────────────────────────────────

    private static string ConfigDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "IndexTab");

    private static string ConfigPath => Path.Combine(ConfigDir, "settings.json");

    private static readonly JsonSerializerOptions JsonOpts = new() { WriteIndented = true };

    private static Settings Load()
    {
        try
        {
            if (File.Exists(ConfigPath))
            {
                var json = File.ReadAllText(ConfigPath);
                var s = JsonSerializer.Deserialize<Settings>(json, JsonOpts);
                if (s != null) return s;
            }
        }
        catch { /* 손상 시 기본값으로 진행 */ }
        return new Settings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(ConfigDir);
            File.WriteAllText(ConfigPath, JsonSerializer.Serialize(this, JsonOpts));
        }
        catch { /* 저장 실패는 조용히 무시 (다음 변경 때 재시도) */ }
    }
}
