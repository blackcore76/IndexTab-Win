using IndexTab.Native;

namespace IndexTab.Core;

/// <summary>
/// 특정 창 하나를 앞으로 raise.
///
/// macOS에서는 "옆 모니터의 같은 앱 창까지 튀어나오는" 문제를 private SkyLight API로
/// 겨우 해결했지만(핸드오프 §4), 윈도우는 z-order가 HWND 단위 전역이라
/// SetForegroundWindow(hwnd) 하나로 그 창만 딱 올라온다.
///
/// 단, SetForegroundWindow는 다른 프로세스가 포그라운드일 때 포커스 훔치기를 막는
/// 제약이 있어, AttachThreadInput으로 입력 큐를 잠깐 붙였다 떼는 알려진 우회를 쓴다.
/// </summary>
public static class WindowActivator
{
    public static void Raise(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;

        // 최소화돼 있으면 먼저 복원
        if (NativeMethods.IsIconic(hwnd))
            NativeMethods.ShowWindow(hwnd, NativeMethods.SW_RESTORE);

        IntPtr foreground = NativeMethods.GetForegroundWindow();
        if (foreground == hwnd)
        {
            // 이미 최상단이면 z-order만 확실히
            NativeMethods.BringWindowToTop(hwnd);
            return;
        }

        uint myThread = NativeMethods.GetCurrentThreadId();
        uint fgThread = foreground != IntPtr.Zero
            ? NativeMethods.GetWindowThreadProcessId(foreground, out _)
            : 0;
        uint targetThread = NativeMethods.GetWindowThreadProcessId(hwnd, out uint targetPid);

        // 대상 프로세스에 포그라운드 전환 허용
        NativeMethods.AllowSetForegroundWindow(NativeMethods.ASFW_ANY);

        bool attachedFg = false, attachedTarget = false;
        try
        {
            // 현재 포그라운드 스레드 + 대상 스레드에 우리 입력 큐를 붙여
            // SetForegroundWindow 제약을 우회
            if (fgThread != 0 && fgThread != myThread)
                attachedFg = NativeMethods.AttachThreadInput(myThread, fgThread, true);
            if (targetThread != 0 && targetThread != myThread && targetThread != fgThread)
                attachedTarget = NativeMethods.AttachThreadInput(myThread, targetThread, true);

            NativeMethods.BringWindowToTop(hwnd);
            NativeMethods.SetForegroundWindow(hwnd);
            NativeMethods.ShowWindow(hwnd, NativeMethods.SW_SHOW);
        }
        finally
        {
            if (attachedFg) NativeMethods.AttachThreadInput(myThread, fgThread, false);
            if (attachedTarget) NativeMethods.AttachThreadInput(myThread, targetThread, false);
        }
    }
}
