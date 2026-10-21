param(
  [string]$Src  = 'c:\Flutter\Projects\WLAN-auto-connect\website\help.html',
  [string]$Root = 'c:\Flutter\Projects\WLAN-auto-connect\website',
  [string]$Out  = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'help-standalone.html')
)

$enc = [System.Text.UTF8Encoding]::new($false)
$html = [System.IO.File]::ReadAllText($Src, [System.Text.Encoding]::UTF8)

$mime = @{ png = 'image/png'; jpg = 'image/jpeg'; jpeg = 'image/jpeg'; svg = 'image/svg+xml'; webp = 'image/webp' }
$rx = [regex]'src="(help-assets/[^"]+)"'
$count = 0
foreach ($m in $rx.Matches($html)) {
  $rel  = $m.Groups[1].Value
  $path = Join-Path $Root ($rel -replace '/', '\')
  if (-not (Test-Path $path)) { Write-Output "MISS $rel"; continue }
  $ext  = [System.IO.Path]::GetExtension($path).TrimStart('.').ToLower()
  $type = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
  $b64  = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($path))
  # 构造替换后的 src 值（data URI 内联）
  $newSrc = 'src="' + ('data:{0};base64,{1}' -f $type, $b64) + '"'
  $html = $html.Replace($m.Value, $newSrc)
  $count++
  Write-Output ("embedded {0}  ({1:N0} KB)" -f $rel, ($b64.Length / 1KB))
}

[System.IO.File]::WriteAllText($Out, $html, $enc)
$sizeKB = ([System.IO.File]::ReadAllBytes($Out)).Length / 1KB
Write-Output ("DONE  images=$count  out=$Out  size={0:N0} KB" -f $sizeKB)
