param(
    [Parameter(Mandatory = $true)][string]$Out
)

# Capture the emulator screen to a PNG (binary-safe via sdcard + pull). ASCII-only.
$adb = 'C:\Users\Administrator\AppData\Local\Android\sdk\platform-tools\adb.exe'
& $adb -s emulator-5554 shell screencap -p /sdcard/qshot.png | Out-Null
$dest = Join-Path 'c:\Flutter\Projects\WLAN-auto-connect\website\help-assets\android' $Out
& $adb -s emulator-5554 pull /sdcard/qshot.png $dest | Out-Null
Write-Output "saved $dest"
