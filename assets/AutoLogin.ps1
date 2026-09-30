# =====================================================================
# CampusNetAutoLogin - Silent campus network login (Dr.COM / eportal v4)
#
# Multi-WiFi: config.json keeps a profile per SSID (account/suffix) and
# exactly ONE autoLoginSsid. Passwords are DPAPI-encrypted per SSID in
# cred.json. Boot/-Once mode only logs in when the machine is connected
# to the autoLoginSsid WiFi.
#
# Modes:
#   (none)      Boot mode  : wait for autoLoginSsid WiFi, then silent login
#   -Once       Single mode: one login attempt, prints [OK]/[ERR]/[INFO]
#                 Optional -Ssid X: use the saved profile of SSID X
#                 instead of the auto-login WiFi.
#   -Save       Save mode  : reads JSON {"host","eport","autoLoginSsid",
#                            "profiles":[{"ssid","account","suffix",
#                            "password"}]} from stdin; empty password
#                            keeps the previously saved one.
#   -FixPopup   Popup fix  : disable Windows NCSI active probing so the
#                            captive-portal auto-opened browser (MSN)
#                            no longer pops up. Self-elevates via UAC.
#   -UndoPopup  Restore    : re-enable NCSI active probing. Self-elevates.
#   -Install    Register   : creates Scheduled Task (logon trigger)
#   -Uninstall  Remove     : deletes the Scheduled Task
#   -Status     Status     : prints saved config / task / online state
# =====================================================================
param(
    [switch]$Once,
    [switch]$Save,
    [switch]$Export,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$InstallElevated,
    [string]$ResultFile = '',
    [string]$Ssid = '',
    [switch]$FixPopup,
    [switch]$UndoPopup,
    [switch]$PopupElevated
)

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Net.Http

$TaskName   = 'CampusNetAutoLogin'
$Dir        = Join-Path $env:APPDATA 'CampusNetAutoLogin'
$Script     = Join-Path $Dir 'AutoLogin.ps1'
$LogFile    = Join-Path $Dir 'autologin.log'
$CfgFile    = Join-Path $Dir 'config.json'
$CredFile   = Join-Path $Dir 'cred.bin'      # legacy single-password file
$CredJson   = Join-Path $Dir 'cred.json'     # per-SSID DPAPI passwords

# portal server config (defaults, updated by -Save / Load-Config)
$script:Host_         = '172.16.200.11'
$script:EPort         = 801
$script:AutoLoginSsid = ''
$script:Profiles      = @{}   # ssid -> @{ account = ''; suffix = '' }
$script:PlainPassword = $null
$script:Account       = ''    # resolved from the autoLogin profile
$script:Suffix        = ''
$script:SessMac       = ''    # session params captured from the AC hijack
$script:SessAcname    = ''
$script:SessSsid      = ''
$script:ChkIp         = ''    # ss5/ss1 from chkstatus (portal-side view of us)
$script:ChkMac        = ''

function Log([string]$msg) {
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }
    if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 256KB)) {
        Set-Content -Path $LogFile -Value '' -Encoding UTF8
    }
    Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
}

function Emit([string]$level, [string]$msg) {
    # Write directly to console: Write-Output would be captured by
    # pipeline contexts like `if (Login-Cycle)`, losing stdout.
    [Console]::Out.WriteLine(("[{0}] {1}" -f $level, $msg))
    Log ("[{0}] {1}" -f $level, $msg)
}

# ---------------------------------------------------------------
# Cred store: cred.json = { "<ssid>": "<DPAPI-encrypted password>" }
# ---------------------------------------------------------------
function Get-CredMap {
    if (-not (Test-Path $CredJson)) { return @{} }
    try {
        $obj = Get-Content $CredJson -Raw -Encoding UTF8 | ConvertFrom-Json
        $map = @{}
        foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
        return $map
    } catch { return @{} }
}

function Set-CredPassword([string]$ssid, [string]$plain) {
    if (-not $ssid) { return }
    $map = Get-CredMap
    try {
        $sec = ConvertTo-SecureString $plain -AsPlainText -Force
        $map[$ssid] = ConvertFrom-SecureString $sec
        ($map | ConvertTo-Json -Compress) | Set-Content -Path $CredJson -Encoding UTF8
    } catch { }
}

function Get-SavedPassword([string]$ssid) {
    if (-not $ssid) { return $null }
    $map = Get-CredMap
    $enc = $map[$ssid]
    if (-not $enc) { return $null }
    try {
        $sec = ConvertTo-SecureString $enc
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try {
            return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } catch { return $null }
}

# ---------------------------------------------------------------
# Config: profiles + autoLoginSsid (+ harvested session params).
# Legacy single-account config/cred.bin is migrated on first load.
# ---------------------------------------------------------------
function Write-ConfigFile {
    $cfg = [ordered]@{
        host          = $script:Host_
        eport         = $script:EPort
        autoLoginSsid = $script:AutoLoginSsid
    }
    $prof = @{}
    foreach ($k in $script:Profiles.Keys) {
        $prof[$k] = @{ account = [string]$script:Profiles[$k]['account']; suffix = [string]$script:Profiles[$k]['suffix'] }
    }
    $cfg['profiles'] = $prof
    # session params: freshly hijacked values win, else keep previous ones
    $old = $null
    if (Test-Path $CfgFile) {
        try { $old = Get-Content $CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    if ($script:SessMac)         { $cfg['mac'] = $script:SessMac }
    elseif ($old -and $old.mac)  { $cfg['mac'] = [string]$old.mac }
    if ($script:SessAcname)          { $cfg['acname'] = $script:SessAcname }
    elseif ($old -and $old.acname)   { $cfg['acname'] = [string]$old.acname }
    if ($script:SessSsid)        { $cfg['ssid'] = $script:SessSsid }
    elseif ($old -and $old.ssid) { $cfg['ssid'] = [string]$old.ssid }
    ($cfg | ConvertTo-Json -Depth 5 -Compress) | Set-Content -Path $CfgFile -Encoding UTF8
}

function Load-Config {
    if (-not (Test-Path $CfgFile)) { return }
    try {
        $cfg = Get-Content $CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.host)          { $script:Host_ = [string]$cfg.host }
        if ($cfg.eport)         { $script:EPort = [int]$cfg.eport }
        if ($null -ne $cfg.autoLoginSsid) { $script:AutoLoginSsid = [string]$cfg.autoLoginSsid }
        if ($null -ne $cfg.profiles) {
            foreach ($p in $cfg.profiles.PSObject.Properties) {
                $script:Profiles[$p.Name] = @{
                    account = [string]$p.Value.account
                    suffix  = [string]$p.Value.suffix
                }
            }
        }
    } catch { }
    Migrate-Legacy $cfg
}

# Legacy (pre-multi-WiFi) layout: top-level account/suffix in config.json
# and one DPAPI password in cred.bin. Migrate them into profiles + cred.json.
function Migrate-Legacy($cfg) {
    $migrated = $false
    $ssid = ''
    if ($cfg -and $cfg.ssid) { $ssid = [string]$cfg.ssid }   # hijacked campus ssid
    if (-not $ssid) { return }   # unknown SSID: cannot attribute legacy data

    if ((Test-Path $CredFile) -and -not (Test-Path $CredJson)) {
        $enc = ''
        try { $enc = (Get-Content $CredFile -Raw).Trim() } catch { }
        if ($enc) {
            $map = @{}
            $map[$ssid] = $enc
            ($map | ConvertTo-Json -Compress) | Set-Content -Path $CredJson -Encoding UTF8
            $migrated = $true
        }
    }
    if ($cfg -and $cfg.account -and -not $script:Profiles.ContainsKey($ssid)) {
        $script:Profiles[$ssid] = @{ account = [string]$cfg.account; suffix = [string]$cfg.suffix }
        if (-not $script:AutoLoginSsid) { $script:AutoLoginSsid = $ssid }
        $migrated = $true
    }
    if ($migrated) { Write-ConfigFile }
}

# ---------------------------------------------------------------
# Current WLAN state via netsh.
# ---------------------------------------------------------------
function Get-CurrentSsid {
    try {
        $out = (& netsh.exe wlan show interfaces 2>$null) -join "`n"
        # matches "    SSID : xxx" but not "BSSID" (which starts with B)
        if ($out -match '(?m)^\s*SSID\s*:\s*(.+?)\s*$') { return $Matches[1].Trim() }
    } catch { }
    return ''
}

function Connect-Wlan([string]$ssid) {
    if (-not $ssid) { return }
    try { & netsh.exe wlan connect name="$ssid" | Out-Null } catch { }
}

# True when the SSID is currently in the air (netsh wlan show networks).
# Used to avoid sending a connect request for an out-of-range network:
# that request tears down the current WiFi connection and flaps.
function Test-WlanVisible([string]$ssid) {
    if (-not $ssid) { return $false }
    try {
        $out = (& netsh.exe wlan show networks 2>$null) -join "`n"
        foreach ($m in [regex]::Matches($out, '(?m)^\s*SSID\s+\d+\s*:\s*(.+?)\s*$')) {
            if ($m.Groups[1].Value.Trim() -eq $ssid) { return $true }
        }
    } catch { }
    return $false
}

# ---------------------------------------------------------------
# HTTP helper: GET with redirects disabled.
# Returns @{ Code=int; Body=string; Location=string }
# or $null on any failure/timeout.
# Body decode: UTF-8 first (portal login replies in UTF-8, verified
# 2026-09-24: GBK decode turns msg into mojibake), fallback GBK.
# ---------------------------------------------------------------
function Invoke-NoRedirect([string]$url, [int]$timeoutMs = 8000) {
    $client = $null
    try {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $false
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromMilliseconds($timeoutMs)
        $task = $client.GetAsync($url)
        if (-not $task.Wait($timeoutMs + 1000)) { return $null }
        if ($task.Status -ne [System.Threading.Tasks.TaskStatus]::RanToCompletion) { return $null }
        $resp = $task.Result
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        try {
            $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
            $body = $strictUtf8.GetString($bytes)
        } catch {
            $body = [System.Text.Encoding]::GetEncoding(936).GetString($bytes)
        }
        $loc = ''
        if ($null -ne $resp.Headers.Location) { $loc = $resp.Headers.Location.ToString() }
        return @{ Code = [int]$resp.StatusCode; Body = $body; Location = $loc }
    } catch {
        return $null
    } finally {
        if ($null -ne $client) { $client.Dispose() }
    }
}

function Parse-Jsonp([string]$text) {
    if (-not $text) { return $null }
    $s = $text.IndexOf('(')
    $e = $text.LastIndexOf(')')
    if ($s -lt 0 -or $e -le $s) { return $null }
    $payload = $text.Substring($s + 1, $e - $s - 1)
    try { return $payload | ConvertFrom-Json } catch { return $null }
}

# ---------------------------------------------------------------
# Online state via drcom kernel: result==1 means online.
# Returns $true / $false / $null (unreachable).
# ---------------------------------------------------------------
function Test-Online {
    $r = Invoke-NoRedirect ("http://{0}/drcom/chkstatus?callback=dr1&jsVersion=4.X" -f $script:Host_) 5000
    if ($null -eq $r) { return $null }
    $json = Parse-Jsonp $r.Body
    if ($null -eq $json) { return $null }
    # chkstatus reports the portal-side view of this client: ss5 = our IP,
    # ss1 = our MAC. More reliable than hijack capture / guessing the local
    # NIC (with multiple NICs the wrong one gets picked, which triggers
    # ret_code=8 "Portal timeout"). Both fields are present even when
    # result=0 (not online yet).
    try {
        if ($json.ss5) { $script:ChkIp = [string]$json.ss5 }
        if ($json.ss1) { $script:ChkMac = [string]$json.ss1 }
    } catch { }
    if ([string]$json.result -eq '1') { return $true }
    return $false
}

# ---------------------------------------------------------------
# Harvest fresh session params (mac / ip / acname / ssid) from the
# AC hijack redirect. Any external HTTP request gets 302'd (or
# DNS-hijacked) to the portal while unauthenticated.
# ---------------------------------------------------------------
function Get-HijackParams {
    $r = Invoke-NoRedirect 'http://www.msftconnecttest.com/connecttest.txt' 6000
    if ($null -eq $r) { return $null }
    $srv = [regex]::Escape($script:Host_)
    $candidate = ''
    if ($r.Code -ge 300 -and $r.Code -lt 400 -and $r.Location -and $r.Location -match ('a79\.htm|' + $srv)) {
        $candidate = $r.Location
    } else {
        $pat = 'http://' + $srv + '/[^\s"''<>]+'
        if ($r.Body -match $pat) { $candidate = $Matches[0] }
    }
    if (-not $candidate) { return $null }
    $p = @{}
    if ($candidate -match 'wlanusermac=([^&\s]+)') { $p['mac'] = [System.Uri]::UnescapeDataString($Matches[1]) }
    if ($candidate -match 'wlanuserip=([^&\s]+)')  { $p['ip']  = [System.Uri]::UnescapeDataString($Matches[1]) }
    if ($candidate -match 'wlanacname=([^&\s]+)')  { $p['acname'] = [System.Uri]::UnescapeDataString($Matches[1]) }
    if ($candidate -match 'ssid=([^&\s]+)')        { $p['ssid'] = [System.Uri]::UnescapeDataString($Matches[1]) }
    return $p
}

function Get-LocalIPv4 {
    try {
        $nics = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' }
        foreach ($n in $nics) {
            foreach ($a in $n.GetIPProperties().UnicastAddresses) {
                if ($a.Address.AddressFamily -eq 'InterNetwork') {
                    $ip = $a.Address.ToString()
                    if ($ip -notmatch '^(169\.254|127\.)') { return $ip }
                }
            }
        }
    } catch { }
    return ''
}

# Source IP the OS would use to reach the portal (UDP connect picks the
# route without sending any packet). Get-LocalIPv4 picks the wrong NIC
# when wired / USB-tethering / virtual adapters grab the default route,
# which made the portal return ret_code=8.
function Get-PortalSourceIP {
    try {
        $sock = New-Object System.Net.Sockets.Socket(
            [System.Net.Sockets.AddressFamily]::InterNetwork,
            [System.Net.Sockets.SocketType]::Dgram,
            [System.Net.Sockets.ProtocolType]::Udp)
        $sock.Connect([System.Net.IPAddress]::Parse($script:Host_), 80)
        $ip = ([string]$sock.LocalEndPoint) -replace ':\d+$', ''
        $sock.Close()
        if ($ip -and $ip -notmatch '^(169\.254|127\.)') { return $ip }
    } catch { }
    return Get-LocalIPv4
}

# ---------------------------------------------------------------
# Portal login (eportal v4, login_method=1) for the autoLogin profile.
# user_account = account + suffix (bare account; verified 2026-09-24.
# The ",0," prefix makes the server return "account not found".)
# ---------------------------------------------------------------
function Invoke-Login([hashtable]$sessParams) {
    $mac = ''; $ip = ''; $acname = ''
    if ($sessParams) {
        if ($sessParams['mac'])    { $mac = $sessParams['mac'] }
        if ($sessParams['ip'])     { $ip = $sessParams['ip'] }
        if ($sessParams['acname']) { $acname = $sessParams['acname'] }
    }
    # Session param priority: AC hijack > chkstatus ss5/ss1 > route source IP.
    # Verified 2026-09-24: with a wired NIC online the hijack capture fails
    # and local NIC guessing picks the wrong adapter, so the portal answers
    # ret_code=8 "Portal protocol auth timeout".
    if (-not $ip) {
        if ($script:ChkIp) { $ip = $script:ChkIp } else { $ip = Get-PortalSourceIP }
    }
    if (-not $mac -and $script:ChkMac) { $mac = $script:ChkMac }

    # Bare account works; the ",0," prefix causes "account not found".
    $userAccount = $script:Account + $script:Suffix
    $fmt = 'http://{0}:{1}/eportal/portal/login?callback=dr1&login_method=1&user_account={2}&user_password={3}' +
           '&wlan_user_ip={4}&wlan_user_ipv6=&wlan_user_mac={5}&wlan_ac_ip=&wlan_ac_name={6}&jsVersion=4.X&v={7}&lang=zh'
    $url = $fmt -f $script:Host_, $script:EPort,
        [System.Uri]::EscapeDataString($userAccount),
        [System.Uri]::EscapeDataString($script:PlainPassword),
        [System.Uri]::EscapeDataString($ip),
        [System.Uri]::EscapeDataString($mac),
        [System.Uri]::EscapeDataString($acname),
        (Get-Random -Minimum 500 -Maximum 10500)

    $r = Invoke-NoRedirect $url 8000
    if ($null -eq $r) { return @{ ok = $false; msg = 'PORTAL_UNREACHABLE' } }
    $json = Parse-Jsonp $r.Body
    if ($null -eq $json) {
        $snippet = ''
        if ($r.Body) { $snippet = ($r.Body -replace '\s+', ' ').Substring(0, [Math]::Min(120, $r.Body.Length)) }
        return @{ ok = $false; msg = ('BAD_RESPONSE code={0} len={1} body={2}' -f $r.Code, $r.Body.Length, $snippet) }
    }
    if ([string]$json.result -eq '1' -or [string]$json.result -eq 'ok') {
        return @{ ok = $true; msg = 'LOGIN_OK' }
    }
    if ([string]$json.ret_code -eq '2') {
        return @{ ok = $true; msg = 'ALREADY_ONLINE' }
    }
    $msg = [string]$json.msg
    if (-not $msg) { $msg = 'UNKNOWN_ERROR' }
    return @{ ok = $false; msg = $msg }
}

function Save-SessionParams([hashtable]$p) {
    if (-not $p) { return }
    try {
        if ($p['mac'])    { $script:SessMac = $p['mac'] }
        if ($p['acname']) { $script:SessAcname = $p['acname'] }
        if ($p['ssid'])   { $script:SessSsid = $p['ssid'] }
        Write-ConfigFile
    } catch { }
}

# ---------------------------------------------------------------
# Core: one detect-and-login cycle. Returns $true when online.
# ---------------------------------------------------------------
function Login-Cycle {
    $state = Test-Online
    if ($state -eq $true) { Emit 'OK' 'ONLINE_ALREADY'; return $true }
    if ($null -eq $state) { Emit 'INFO' 'PORTAL_UNREACHABLE'; return $false }

    Emit 'INFO' 'NEED_LOGIN'
    $sess = Get-HijackParams
    for ($i = 1; $i -le 3; $i++) {
        $r = Invoke-Login $sess
        if ($r.ok) {
            Start-Sleep -Seconds 2
            if ((Test-Online) -eq $true) {
                Emit 'OK' ('LOGIN_SUCCESS ({0})' -f $r.msg)
                Save-SessionParams $sess
                return $true
            }
            Emit 'INFO' 'LOGIN_SENT_BUT_NOT_ONLINE'
        } else {
            Emit 'INFO' ('LOGIN_REJECTED: {0}' -f $r.msg)
        }
        $sess = Get-HijackParams   # refresh params before retry
        Start-Sleep -Seconds 5
    }
    return $false
}

# Resolve the autoLogin profile: account/suffix/password must exist.
function Select-AutoLoginProfile {
    if (-not $script:AutoLoginSsid) {
        Emit 'ERR' 'NO_AUTOLOGIN_WIFI'
        return $false
    }
    $prof = $script:Profiles[$script:AutoLoginSsid]
    if ($null -eq $prof -or -not $prof['account']) {
        Emit 'ERR' ('NO_PROFILE_FOR_SSID: {0}' -f $script:AutoLoginSsid)
        return $false
    }
    $script:Account = [string]$prof['account']
    $script:Suffix  = [string]$prof['suffix']
    $script:PlainPassword = Get-SavedPassword $script:AutoLoginSsid
    if (-not $script:PlainPassword) {
        Emit 'ERR' ('NO_SAVED_PASSWORD: {0}' -f $script:AutoLoginSsid)
        return $false
    }
    return $true
}

# ---------------------------------------------------------------
# Modes
# ---------------------------------------------------------------
if ($Save) {
    Load-Config   # migrate legacy single-account config first
    $raw = [Console]::In.ReadToEnd()
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }
    try { $req = $raw | ConvertFrom-Json } catch { Emit 'ERR' 'INVALID_INPUT'; exit 1 }
    try {
        if ($req.host)  { $script:Host_ = [string]$req.host }
        if ($req.eport) { $script:EPort = [int]$req.eport }
        if ($null -ne $req.autoLoginSsid) { $script:AutoLoginSsid = [string]$req.autoLoginSsid }
        if ($null -ne $req.profiles) {
            foreach ($p in $req.profiles) {
                $ssid = [string]$p.ssid
                if (-not $ssid -or -not [string]$p.account) { continue }
                $script:Profiles[$ssid] = @{ account = [string]$p.account; suffix = [string]$p.suffix }
                if ([string]$p.password) { Set-CredPassword $ssid ([string]$p.password) }
            }
        }
        Write-ConfigFile
        Emit 'OK' 'SAVED'
        exit 0
    } catch {
        Emit 'ERR' ('SAVE_FAILED: {0}' -f $_.Exception.Message)
        exit 1
    }
}

# Export saved passwords (DPAPI, current user scope) as JSON {ssid: plain}.
# Used by the app's cloud sync to back up profiles across devices.
if ($Export) {
    Load-Config
    $map = @{}
    foreach ($ssid in $script:Profiles.Keys) {
        $pw = Get-SavedPassword ([string]$ssid)
        if ($pw) { $map[[string]$ssid] = $pw }
    }
    Emit 'OK' ($map | ConvertTo-Json -Compress)
    exit 0
}

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return ([System.Security.Principal.WindowsPrincipal]$id).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------
# Captive-portal popup fix. While unauthenticated, Windows NCSI active
# probing sees the AC hijack and auto-opens the default browser (ends
# up on MSN). Disabling active probing stops that popup; real Internet
# access is unaffected (this app does the login itself).
# ---------------------------------------------------------------
$PopupPolKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator'
$PopupNlaKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet'

function Set-PopupFix([bool]$undo) {
    if ($undo) {
        Remove-ItemProperty -Path $PopupPolKey -Name NoActiveProbe -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $PopupNlaKey -Name EnableActiveProbing -Value 1 -Type DWord
    } else {
        if (-not (Test-Path $PopupPolKey)) { New-Item -Path $PopupPolKey -Force | Out-Null }
        Set-ItemProperty -Path $PopupPolKey -Name NoActiveProbe -Value 1 -Type DWord
        Set-ItemProperty -Path $PopupNlaKey -Name EnableActiveProbing -Value 0 -Type DWord
    }
    try { Restart-Service NlaSvc -Force } catch { }
}

function Test-PopupFixed {
    try {
        $pol = (Get-ItemProperty -Path $PopupPolKey -ErrorAction SilentlyContinue).NoActiveProbe
        if ($pol -eq 1) { return $true }
        $nla = (Get-ItemProperty -Path $PopupNlaKey -ErrorAction SilentlyContinue).EnableActiveProbing
        if ($nla -eq 0) { return $true }
    } catch { }
    return $false
}

# Elevated child: apply/undo the fix, report via result file.
function Invoke-PopupElevated {
    try {
        Set-PopupFix $UndoPopup.IsPresent
        $ok = if ($UndoPopup) { -not (Test-PopupFixed) } else { Test-PopupFixed }
        if ($ResultFile) {
            Set-Content -Path $ResultFile -Value ($(if ($ok) { 'OK' } else { 'ERR:VERIFY_FAILED' })) -Encoding ASCII
        }
        exit $(if ($ok) { 0 } else { 1 })
    } catch {
        if ($ResultFile) { Set-Content -Path $ResultFile -Value ('ERR:' + $_.Exception.Message) -Encoding ASCII }
        exit 1
    }
}

# Actual task registration. The task itself always runs NON-elevated
# (RunLevel Limited) as the current user at logon.
function Register-TaskInternal {
    Load-Config
    if (-not (Select-AutoLoginProfile)) { throw 'NO_SAVED_CONFIG' }
    if (-not (Test-Path $Script)) { throw 'SCRIPT_NOT_FOUND' }
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $psExe -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Script)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
}

if ($InstallElevated) {
    # Elevated child: register the task, write result file for the parent.
    try {
        Register-TaskInternal
        if ($ResultFile) { Set-Content -Path $ResultFile -Value 'OK' -Encoding ASCII }
        exit 0
    } catch {
        if ($ResultFile) { Set-Content -Path $ResultFile -Value ('ERR:' + $_.Exception.Message) -Encoding ASCII }
        exit 1
    }
}

if ($Install) {
    Load-Config
    if (-not (Select-AutoLoginProfile)) { exit 1 }
    if (-not (Test-Path $Script)) { Emit 'ERR' 'SCRIPT_NOT_FOUND'; exit 1 }

    if (Test-IsAdmin) {
        try {
            Register-TaskInternal
            Emit 'OK' 'TASK_REGISTERED'
            exit 0
        } catch {
            Emit 'ERR' ('TASK_REGISTER_FAILED: {0}' -f $_.Exception.Message)
            exit 1
        }
    }

    # Non-elevated: relaunch self via UAC (user confirms), read result file.
    $resultFile = Join-Path $Dir 'install_result.tmp'
    Remove-Item $resultFile -ErrorAction SilentlyContinue
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $childArgs = '-NoProfile -ExecutionPolicy Bypass -Command "& ''{0}'' -InstallElevated -ResultFile ''{1}''"' -f $Script, $resultFile
    try {
        $proc = Start-Process -FilePath $psExe -Verb RunAs -Wait -PassThru -ArgumentList $childArgs
    } catch {
        Emit 'ERR' 'TASK_REGISTER_FAILED: ELEVATION_DENIED'
        exit 1
    }
    Start-Sleep -Milliseconds 300
    if ($proc.ExitCode -eq 0 -and (Test-Path $resultFile)) {
        Emit 'OK' 'TASK_REGISTERED'
        exit 0
    }
    $detail = ''
    if (Test-Path $resultFile) { $detail = (Get-Content $resultFile -Raw).Trim() }
    Emit 'ERR' ('TASK_REGISTER_FAILED: {0}' -f $(if ($detail) { $detail } else { 'ELEVATED_CHILD_FAILED' }))
    exit 1
}

# ---------------------------------------------------------------
# -FixPopup / -UndoPopup : toggle NCSI active probing (admin needed,
# self-elevates via UAC like -Install).
# ---------------------------------------------------------------
if ($PopupElevated) {
    Invoke-PopupElevated
}

if ($FixPopup -or $UndoPopup) {
    if (Test-IsAdmin) {
        Set-PopupFix $UndoPopup.IsPresent
        $ok = if ($UndoPopup) { -not (Test-PopupFixed) } else { Test-PopupFixed }
        if ($ok) { Emit 'OK' 'POPUP_FIXED'; exit 0 }
        Emit 'ERR' 'POPUP_FIX_FAILED'
        exit 1
    }
    $resultFile = Join-Path $Dir 'popup_result.tmp'
    Remove-Item $resultFile -ErrorAction SilentlyContinue
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $undoArg = ''
    if ($UndoPopup) { $undoArg = ' -UndoPopup' }
    $childArgs = '-NoProfile -ExecutionPolicy Bypass -Command "& ''{0}'' -PopupElevated{1} -ResultFile ''{2}''"' -f $Script, $undoArg, $resultFile
    try {
        $proc = Start-Process -FilePath $psExe -Verb RunAs -Wait -PassThru -ArgumentList $childArgs
    } catch {
        Emit 'ERR' 'POPUP_FIX_FAILED: ELEVATION_DENIED'
        exit 1
    }
    Start-Sleep -Milliseconds 300
    if ($proc.ExitCode -eq 0 -and (Test-Path $resultFile)) {
        Emit 'OK' 'POPUP_FIXED'
        exit 0
    }
    $detail = ''
    if (Test-Path $resultFile) { $detail = (Get-Content $resultFile -Raw).Trim() }
    Emit 'ERR' ('POPUP_FIX_FAILED: {0}' -f $(if ($detail) { $detail } else { 'ELEVATED_CHILD_FAILED' }))
    exit 1
}

if ($Uninstall) {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Emit 'OK' 'TASK_REMOVED'
        exit 0
    } catch {
        Emit 'OK' 'TASK_NOT_FOUND'
        exit 0
    }
}

if ($Status) {
    Load-Config
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $state = Test-Online
    $online = if ($state -eq $true) { 'yes' } elseif ($state -eq $false) { 'no' } else { 'unknown' }
    $profNames = ($script:Profiles.Keys | ForEach-Object { $_ + '(pw=' + [bool](Get-SavedPassword $_) + ')' }) -join ','
    Emit 'INFO' ('CONFIG autoLoginSsid={0} currentSsid={1} profiles={2} task={3} online={4}' -f `
        $script:AutoLoginSsid, (Get-CurrentSsid), $profNames, [bool]$task, $online)
    exit 0
}

# ---------------------------------------------------------------
# -Once : single cycle, exit 0 on success / 1 on failure.
# Only runs when connected to the designated auto-login WiFi.
# ---------------------------------------------------------------
if ($Once) {
    Load-Config
    if ($Ssid) { $script:AutoLoginSsid = $Ssid }   # login for any saved profile
    if (-not (Select-AutoLoginProfile)) { exit 1 }
    $cur = Get-CurrentSsid
    if ($cur -ne $script:AutoLoginSsid) {
        Emit 'ERR' ('SSID_MISMATCH current={0} expect={1}' -f $cur, $script:AutoLoginSsid)
        exit 1
    }
    if (Login-Cycle) { exit 0 } else { exit 1 }
}

# ---------------------------------------------------------------
# Boot mode (default, from Scheduled Task):
# Log in silently once connected to the designated WiFi. NEVER hijack
# the WLAN: while Windows is connected to (or associating with) some
# other network, leave it alone and exit. Only send a connect request
# when nothing is connected AND the target SSID is visible in the air
# (a connect to an out-of-range network tears down the current WiFi
# and flaps until Windows reconnects it).
# ---------------------------------------------------------------
Load-Config
if (-not (Select-AutoLoginProfile)) { exit 1 }

Emit 'INFO' ('BOOT_START ssid={0}' -f $script:AutoLoginSsid)
$deadline = (Get-Date).AddMinutes(3)
$onTarget = $false
while ((Get-Date) -lt $deadline) {
    $cur = Get-CurrentSsid
    if ($cur -eq $script:AutoLoginSsid) { $onTarget = $true; break }
    if ($cur) {
        # User is on some other WiFi on purpose: do not touch it.
        Emit 'INFO' ('OTHER_WIFI_ACTIVE ssid={0} boot_login_skipped' -f $cur)
        exit 0
    }
    if (Test-WlanVisible $script:AutoLoginSsid) {
        Connect-Wlan $script:AutoLoginSsid
        # Association takes seconds; re-issuing connect mid-association
        # aborts it and causes flapping, so wait quietly first.
        $assocEnd = (Get-Date).AddSeconds(20)
        while (((Get-Date) -lt $assocEnd) -and ((Get-Date) -lt $deadline)) {
            Start-Sleep -Seconds 2
            $cur = Get-CurrentSsid
            if ($cur) { break }
        }
        if ($cur -eq $script:AutoLoginSsid) { $onTarget = $true; break }
        if ($cur) {
            Emit 'INFO' ('OTHER_WIFI_ACTIVE ssid={0} boot_login_skipped' -f $cur)
            exit 0
        }
    }
    Start-Sleep -Seconds 3
}
if (-not $onTarget) {
    Emit 'ERR' ('WIFI_NOT_CONNECTED: {0}' -f $script:AutoLoginSsid)
    exit 1
}
Emit 'INFO' ('WLAN_CONNECTED: {0}' -f $script:AutoLoginSsid)

# wait for portal reachability (WiFi may still be settling)
$deadline = (Get-Date).AddMinutes(1)
while ((Get-Date) -lt $deadline) {
    $probe = Invoke-NoRedirect ('http://{0}/drcom/chkstatus?callback=dr1&jsVersion=4.X' -f $script:Host_) 4000
    if ($null -ne $probe) { break }
    Start-Sleep -Seconds 3
}

if (Login-Cycle) { exit 0 }

# last resort: wait 30s, one more cycle (wifi may have re-connected)
Start-Sleep -Seconds 30
if (Login-Cycle) { exit 0 }
Emit 'ERR' 'LOGIN_FAILED_ALL_RETRIES'
exit 1
