# =====================================================================
# CampusNetAutoLogin - Silent campus network login (Dr.COM / eportal v4)
#
# Modes:
#   (none)      Boot mode  : wait for network, detect state, silent login
#   -Once       Single mode: one login attempt, prints [OK]/[ERR]/[INFO]
#   -Save       Save mode  : reads JSON {"account","password","suffix",
#                            "host","eport"} from stdin, DPAPI-encrypts
#                            the password, writes config.json + cred.bin
#   -Install    Register   : creates Scheduled Task (logon trigger)
#   -Uninstall  Remove     : deletes the Scheduled Task
#   -Status     Status     : prints saved config / task / online state
# =====================================================================
param(
    [switch]$Once,
    [switch]$Save,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Status,
    [switch]$InstallElevated,
    [string]$ResultFile = ''
)

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Net.Http

$TaskName = 'CampusNetAutoLogin'
$Dir      = Join-Path $env:APPDATA 'CampusNetAutoLogin'
$Script   = Join-Path $Dir 'AutoLogin.ps1'
$LogFile  = Join-Path $Dir 'autologin.log'
$CfgFile  = Join-Path $Dir 'config.json'
$CredFile = Join-Path $Dir 'cred.bin'

# portal server config (defaults, updated by -Save / Load-Config)
$script:Host_    = '172.16.200.11'
$script:EPort    = 801
$script:Account  = ''
$script:Suffix   = ''
$script:PlainPassword = $null

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

function Load-Config {
    if (Test-Path $CfgFile) {
        try {
            $cfg = Get-Content $CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.host)    { $script:Host_   = [string]$cfg.host }
            if ($cfg.eport)   { $script:EPort   = [int]$cfg.eport }
            if ($cfg.account) { $script:Account = [string]$cfg.account }
            if ($null -ne $cfg.suffix) { $script:Suffix = [string]$cfg.suffix }
        } catch { }
    }
}

function Get-SavedPassword {
    if (-not (Test-Path $CredFile)) { return $null }
    try {
        $enc = (Get-Content $CredFile -Raw).Trim()
        if (-not $enc) { return $null }
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
# HTTP helper: GET with redirects disabled.
# Returns @{ Code=int; Body=string(gbk-decoded); Location=string }
# or $null on any failure/timeout.
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
        $body = [System.Text.Encoding]::GetEncoding(936).GetString($bytes)
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

# ---------------------------------------------------------------
# Portal login (eportal v4, login_method=1).
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
    if (-not $ip) { $ip = Get-LocalIPv4 }

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
    if ($null -eq $json) { return @{ ok = $false; msg = 'BAD_RESPONSE' } }
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
        $cfg = @{ host = $script:Host_; eport = $script:EPort; account = $script:Account; suffix = $script:Suffix }
        if ($p['mac'])    { $cfg['mac'] = $p['mac'] }
        if ($p['acname']) { $cfg['acname'] = $p['acname'] }
        if ($p['ssid'])   { $cfg['ssid'] = $p['ssid'] }
        ($cfg | ConvertTo-Json -Compress) | Set-Content -Path $CfgFile -Encoding UTF8
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

# ---------------------------------------------------------------
# Modes
# ---------------------------------------------------------------
if ($Save) {
    $raw = [Console]::In.ReadToEnd()
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir | Out-Null }
    try { $req = $raw | ConvertFrom-Json } catch { Emit 'ERR' 'INVALID_INPUT'; exit 1 }
    if (-not $req.account -or $null -eq $req.password) { Emit 'ERR' 'MISSING_FIELDS'; exit 1 }
    try {
        $sec = ConvertTo-SecureString ([string]$req.password) -AsPlainText -Force
        $enc = ConvertFrom-SecureString $sec
        Set-Content -Path $CredFile -Value $enc -Encoding ASCII
        $cfg = @{ host = [string]$req.host; eport = [int]$req.eport; account = [string]$req.account; suffix = [string]$req.suffix }
        if (Test-Path $CfgFile) {
            # keep previously harvested session params
            try {
                $old = Get-Content $CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($old.mac)    { $cfg['mac'] = [string]$old.mac }
                if ($old.acname) { $cfg['acname'] = [string]$old.acname }
                if ($old.ssid)   { $cfg['ssid'] = [string]$old.ssid }
            } catch { }
        }
        ($cfg | ConvertTo-Json -Compress) | Set-Content -Path $CfgFile -Encoding UTF8
        Emit 'OK' 'SAVED'
        exit 0
    } catch {
        Emit 'ERR' ('SAVE_FAILED: {0}' -f $_.Exception.Message)
        exit 1
    }
}

function Test-IsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return ([System.Security.Principal.WindowsPrincipal]$id).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Actual task registration. The task itself always runs NON-elevated
# (RunLevel Limited) as the current user at logon.
function Register-TaskInternal {
    Load-Config
    if (-not $script:Account) { throw 'NO_SAVED_CONFIG' }
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
    if (-not $script:Account) { Emit 'ERR' 'NO_SAVED_CONFIG'; exit 1 }
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
    $pw = Get-SavedPassword
    $hasPw = ($null -ne $pw -and $pw.Length -gt 0)
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $state = Test-Online
    $online = if ($state -eq $true) { 'yes' } elseif ($state -eq $false) { 'no' } else { 'unknown' }
    Emit 'INFO' ('CONFIG account={0} suffix={1} host={2} eport={3} password_saved={4} task={5} online={6}' -f `
        $script:Account, $script:Suffix, $script:Host_, $script:EPort, $hasPw, [bool]$task, $online)
    exit 0
}

# ---------------------------------------------------------------
# -Once : single cycle, exit 0 on success / 1 on failure
# ---------------------------------------------------------------
if ($Once) {
    Load-Config
    $script:PlainPassword = Get-SavedPassword
    if (-not $script:Account -or -not $script:PlainPassword) {
        Emit 'ERR' 'NO_SAVED_CONFIG'
        exit 1
    }
    if (Login-Cycle) { exit 0 } else { exit 1 }
}

# ---------------------------------------------------------------
# Boot mode (default, from Scheduled Task):
# wait for network up to 3 min, then run cycles with retries.
# ---------------------------------------------------------------
Load-Config
$script:PlainPassword = Get-SavedPassword
if (-not $script:Account -or -not $script:PlainPassword) {
    Emit 'ERR' 'NO_SAVED_CONFIG'
    exit 1
}

Emit 'INFO' 'BOOT_START'
$deadline = (Get-Date).AddMinutes(3)
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
