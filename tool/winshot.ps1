param(
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Proc = 'wlan_auto_connect'
)

# Capture only the app window (by process main window) to a PNG file. ASCII-only.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$sig = @'
using System;
using System.Runtime.InteropServices;
public static class Win {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
Add-Type $sig
[Win]::SetProcessDPIAware() | Out-Null

$hwnd = [IntPtr]::Zero
for ($i = 0; $i -lt 80; $i++) {
    $p = Get-Process -Name $Proc -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($p) { $hwnd = $p.MainWindowHandle; break }
    Start-Sleep -Milliseconds 500
}
if ($hwnd -eq [IntPtr]::Zero) { Write-Error "window not found for process: $Proc"; exit 2 }

if ([Win]::IsIconic($hwnd)) { [Win]::ShowWindow($hwnd, 9) | Out-Null }
[Win]::SetForegroundWindow($hwnd) | Out-Null
[Win]::ShowWindow($hwnd, 5) | Out-Null
Start-Sleep -Milliseconds 700

$r = New-Object Win+RECT
[Win]::GetWindowRect($hwnd, [ref]$r) | Out-Null
$w = $r.Right - $r.Left
$h = $r.Bottom - $r.Top

$bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
$g.Dispose()

$outFull = [System.IO.Path]::GetFullPath($Out)
New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($outFull)) | Out-Null
$bmp.Save($outFull, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "saved $outFull (${w}x${h})"
