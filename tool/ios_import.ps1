param(
  [string]$Desk = 'C:\Users\Administrator\Desktop',
  [string]$OutDir = 'c:\Flutter\Projects\WLAN-auto-connect\website\help-assets\ios',
  [int]$MaxW = 1440
)

Add-Type -AssemblyName System.Drawing

$map = [ordered]@{
  '389' = 'ios-01-site.png'
  '390' = 'ios-02-sharepage.png'
  '391' = 'ios-03-add-shortcut.png'
  '392' = 'ios-04-input-account.png'
  '393' = 'ios-05-input-password.png'
  '394' = 'ios-06-saved.png'
  '395' = 'ios-07-success.png'
  '397' = 'ios-08-share-sheet.png'
  '399' = 'ios-09-add-to-home.png'
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

foreach ($id in $map.Keys) {
  $hit = Get-ChildItem -Path $Desk -Filter "*_${id}_28.png" -File | Select-Object -First 1
  if (-not $hit) { Write-Output "MISS  id=$id"; continue }
  $src = $hit.FullName
  $img = [System.Drawing.Image]::FromFile($src)
  $w = $img.Width; $h = $img.Height
  if ($w -gt $MaxW) { $nw = $MaxW; $nh = [int]([math]::Round($h * ($MaxW / $w))) } else { $nw = $w; $nh = $h }
  $bmp = New-Object System.Drawing.Bitmap $nw, $nh
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
  $g.DrawImage($img, 0, 0, $nw, $nh)
  $g.Dispose(); $img.Dispose()
  $dest = Join-Path $OutDir $map[$id]
  $bmp.Save($dest, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  $kb = ([System.IO.File]::ReadAllBytes($dest)).Length / 1KB
  Write-Output ("{0}  ->  {1}  {2}x{3}  {4:N0} KB" -f $id, $map[$id], $nw, $nh, $kb)
}
$tot = (Get-ChildItem $OutDir -Filter *.png | Measure-Object Length -Sum).Sum / 1MB
Write-Output ("DONE  out={0}  total={1:N2} MB" -f $OutDir, $tot)
