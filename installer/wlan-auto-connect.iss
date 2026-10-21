; 校园网自动登录 —— Windows 安装器脚本（Inno Setup 6）
; 免管理员、仅当前用户安装（PrivilegesRequired=lowest，装到 %LOCALAPPDATA%\Programs）
; 编译：ISCC.exe installer\wlan-auto-connect.iss

#define MyAppName "校园网自动登录"
#define MyAppVersion "1.1.0"
#define MyAppPublisher "辽宁警察学院"
#define MyAppURL "https://wlan.suspect.top/"
#define MyAppExeName "wlan_auto_connect.exe"
#define ReleaseDir "..\build\windows\x64\runner\Release"

[Setup]
; 固定 AppId，保证升级/卸载识别为同一程序（勿随意更改）
AppId={{8F3C1D2E-9A4B-4C7D-8E5F-1A2B3C4D5E6F}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\wlan-auto-connect
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
DisableWelcomePage=no
; 免管理员：装到当前用户目录；高级用户可右键以管理员运行切换为全机安装
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\build\installer
OutputBaseFilename=wlan-auto-connect-v{#MyAppVersion}-setup
SetupIconFile=..\assets\icon\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64
ShowLanguageDialog=no
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\data"
