param(
  [string]$Src    = 'c:\Flutter\Projects\WLAN-auto-connect\website\help.html',
  [string]$Root   = 'c:\Flutter\Projects\WLAN-auto-connect\website',
  [string]$Out    = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'help-standalone.html'),
  [int]$Quality   = 82,
  [int]$MaxW      = 1280
)

Add-Type -AssemblyName System.Drawing

$enc = [System.Text.UTF8Encoding]::new($false)
$html = [System.IO.File]::ReadAllText($Src, [System.Text.Encoding]::UTF8)

$ici = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
$ep = New-Object System.Drawing.Imaging.EncoderParameters 1
$ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality, [long]$Quality)

$rx = [regex]'src="(help-assets/[^"]+)"'
$count = 0
foreach ($m in $rx.Matches($html)) {
  $rel  = $m.Groups[1].Value
  $path = Join-Path $Root ($rel -replace '/', '\')
  if (-not (Test-Path $path)) { Write-Output "MISS $rel"; continue }

  $img = [System.Drawing.Image]::FromFile($path)
  $w = $img.Width; $h = $img.Height
  if ($w -gt $MaxW) { $nw = $MaxW; $nh = [int]([math]::Round($h * ($MaxW / $w))) } else { $nw = $w; $nh = $h }
  $bmp = New-Object System.Drawing.Bitmap $nw, $nh
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.Clear([System.Drawing.Color]::White)
  $g.DrawImage($img, 0, 0, $nw, $nh)
  $g.Dispose(); $img.Dispose()

  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, $ici, $ep)
  $bmp.Dispose()
  $bytes = $ms.ToArray(); $ms.Dispose()

  $b64 = [System.Convert]::ToBase64String($bytes)
  $newSrc = 'src="data:image/jpeg;base64,' + $b64 + '"'
  $html = $html.Replace($m.Value, $newSrc)
  $count++
  Write-Output ("{0}  ->  jpeg {1}x{2}  {3:N0} KB" -f $rel, $nw, $nh, ($bytes.Length / 1KB))
}

[System.IO.File]::WriteAllText($Out, $html, $enc)
$sizeKB = ([System.IO.File]::ReadAllBytes($Out)).Length / 1KB
Write-Output ("DONE  images={0}  quality={1}  out={2}  size={3:N0} KB ({4:N2} MB)" -f $count, $Quality, $Out, $sizeKB, ($sizeKB / 1MB))
