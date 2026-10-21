param(
    [string]$Proc = 'wlan_auto_connect',
    [ValidateSet('click', 'type', 'wheel')][string]$Act = 'click',
    [int]$X = 0,
    [int]$Y = 0,
    [int]$Clicks = 8,
    [string]$Text = ''
)

# Drive the app window via SendInput: click at window-relative pixel coords, wheel, or SendKeys text. ASCII-only.
Add-Type -AssemblyName System.Windows.Forms

$sig = @'
using System;
using System.Runtime.InteropServices;
public static class W {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] p, int cb);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] public struct INPUT {
        [FieldOffset(0)] public uint type;
        [FieldOffset(8)] public MOUSEINPUT mi;
    }
    public static void Click(int sx, int sy) {
        int vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
        int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77);
        int nx = (int)(((sx - vx) * 65535.0) / vw);
        int ny = (int)(((sy - vy) * 65535.0) / vh);
        INPUT[] inps = new INPUT[3];
        inps[0].type = 0; inps[0].mi.dx = nx; inps[0].mi.dy = ny; inps[0].mi.dwFlags = 0x0001 | 0x8000; // MOVE|ABSOLUTE
        inps[1].type = 0; inps[1].mi.dx = nx; inps[1].mi.dy = ny; inps[1].mi.dwFlags = 0x0002 | 0x8000; // LEFTDOWN|ABSOLUTE
        inps[2].type = 0; inps[2].mi.dx = nx; inps[2].mi.dy = ny; inps[2].mi.dwFlags = 0x0004 | 0x8000; // LEFTUP|ABSOLUTE
        SendInput((uint)inps.Length, inps, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void Wheel(int sx, int sy, int notches) {
        int vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
        int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77);
        int nx = (int)(((sx - vx) * 65535.0) / vw);
        int ny = (int)(((sy - vy) * 65535.0) / vh);
        INPUT[] inps = new INPUT[2];
        inps[0].type = 0; inps[0].mi.dx = nx; inps[0].mi.dy = ny; inps[0].mi.dwFlags = 0x0001 | 0x8000;
        inps[1].type = 0; inps[1].mi.mouseData = (uint)(notches * -120); inps[1].mi.dwFlags = 0x0800; // WHEEL
        SendInput((uint)inps.Length, inps, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@
Add-Type $sig
[W]::SetProcessDPIAware() | Out-Null

$p = Get-Process -Name $Proc -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { Write-Error "window not found for process: $Proc"; exit 2 }
$hwnd = $p.MainWindowHandle
[W]::SetForegroundWindow($hwnd) | Out-Null
Start-Sleep -Milliseconds 300
$r = New-Object W+RECT
[W]::GetWindowRect($hwnd, [ref]$r) | Out-Null

if ($Act -eq 'click') {
    [W]::Click(($r.Left + $X), ($r.Top + $Y))
    Write-Output "clicked rel($X,$Y) screen($($r.Left+$X),$($r.Top+$Y))"
} elseif ($Act -eq 'wheel') {
    [W]::Wheel(($r.Left + $X), ($r.Top + $Y), $Clicks)
    Write-Output "wheeled down $Clicks at rel($X,$Y)"
} else {
    [System.Windows.Forms.SendKeys]::SendWait($Text)
    Write-Output "sent: $Text"
}
