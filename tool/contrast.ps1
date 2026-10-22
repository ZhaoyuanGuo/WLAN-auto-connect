# 计算前景色相对背景色的 WCAG 2.1 对比度，用于核对 website/DESIGN.md 的可读性规则。
# 用法：
#   powershell -File tool/contrast.ps1
#   powershell -File tool/contrast.ps1 '#6B7280' '#374151'
param([string[]]$Colors = @())

function Get-Linear([double]$v) {
    if ($v -le 0.03928) { return $v / 12.92 }
    return [Math]::Pow(($v + 0.055) / 1.055, 2.4)
}

function Get-RelLum([string]$hex) {
    $p = @(1, 3, 5) | ForEach-Object { [Convert]::ToInt32($hex.Substring($_, 2), 16) / 255 }
    return (Get-Linear $p[0]) * 0.2126 + (Get-Linear $p[1]) * 0.7152 + (Get-Linear $p[2]) * 0.0722
}

function Get-Contrast([string]$fg, [string]$bg) {
    $lf = Get-RelLum $fg
    $lb = Get-RelLum $bg
    $hi = [Math]::Max($lf, $lb)
    $lo = [Math]::Min($lf, $lb)
    return ($hi + 0.05) / ($lo + 0.05)
}

$targets = if ($Colors.Count -gt 0) { $Colors } else {
    # 当前 :root 文字色 token，加上两处尚游离在 token 外的内联 fallback（DESIGN.md 债务 V-8）
    @('#171717', '#4B5563', '#6B7280', '#2563EB', '#3B82F6', '#047857', '#DC2626', '#FFFFFF', '#64748B', '#8a8a8a')
}

Write-Output ('{0,-12} {1,14} {2,14}  判定' -f 'color', 'vs FFFFFF', 'vs F7F7F8')
Write-Output ('-' * 58)
foreach ($t in $targets) {
    $a = Get-Contrast $t '#FFFFFF'
    $b = Get-Contrast $t '#F7F7F8'
    # AA 正文 >= 4.5；AA 大字（>=18.5px 或 >=14px 加粗）>= 3.0
    if ($b -ge 4.5) { $v = 'AA OK' } elseif ($b -ge 3.0) { $v = 'AA large only' } else { $v = 'FAIL' }
    Write-Output ('{0,-12} {1,14:N2} {2,14:N2}  {3}' -f $t, $a, $b, $v)
}
