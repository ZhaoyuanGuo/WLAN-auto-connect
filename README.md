# CampusNet Auto Login（校园网静默登录）

面向使用 **Dr.COM / 哆点 eportal v4** 认证协议的校园网的跨平台静默登录工具，支持 **Windows** 与 **Android**。

连接校园网 WiFi 后自动完成网页认证，支持开机自启、桌面小组件、控制中心磁贴等便捷入口，全程无需手动打开认证网页。

## 功能特性

### Windows
- WiFi 扫描与选择，多 WiFi 独立档案（账号/密码按 SSID 分别保存）
- 开机自启：通过 Windows 任务计划在登录时静默认证指定 WiFi
- 密码使用 Windows DPAPI 加密，仅当前用户可解密
- 一键连接：自动连接目标 WiFi 并等待关联完成后认证
- 可选：屏蔽 Windows 强制门户探测（NCSI），避免认证前自动弹出浏览器

### Android
- 一键连接 + 静默认证，运行日志可视化
- 桌面小组件：当前状态实时显示，一键触发认证
- 控制中心磁贴（Quick Settings Tile），长按可跳转应用
- 开机自启认证（WorkManager + 开机广播）
- Captive portal 检测守护：防止系统抢占式弹出认证浏览器（两种方案：adb 授权 `WRITE_SECURE_SETTINGS`，或 Shizuku）
- 平板自适应双栏布局，Material 3

## 工作原理

1. 通过门户的 `chkstatus` 接口判断当前是否在线；
2. 未在线时，抓取 AC 劫持重定向中的会话参数（IP / MAC / AC 名）；
3. 调用 Dr.COM eportal v4 的 `/eportal/portal/login`（`login_method=1`）完成认证；
4. 认证按请求源 IP 识别用户，无需浏览器参与。

## 使用前提

- 你的校园网使用 Dr.COM / 哆点 eportal v4 网页认证（认证页地址形如 `http://<门户IP>:801/eportal/...`）；
- 默认认证服务器为 `172.16.200.11:801`，其他学校需修改为自己的门户地址（见下文配置说明）；
- 拥有校园网账号（本地认证账号即可，无需运营商后缀）。

## 安装与使用

### Windows

1. 构建（见下文）后将 `build/windows/x64/runner/Release` 整个目录复制到任意位置，运行 `wlan_auto_connect.exe`；
2. 在应用内选择 WiFi、输入账号密码并保存；
3. 开启「开机自动登录」需通过 UAC 确认注册任务计划（当前用户、非管理员权限运行）。

修改认证服务器：编辑 `%APPDATA%\CampusNetAutoLogin\config.json` 中的 `host` 与 `eport` 字段。

### Android

1. 安装 APK（release 包使用 debug 密钥签名，仅供个人使用）；
2. 首次启动需同意用户协议并授予「位置信息」「附近设备」权限（扫描 WiFi 所需）；
3. 建议开启 Captive portal 守护，二选一：
   - **方案一（adb，一次授权永久有效）**：
     ```
     adb shell pm grant cn.lnpc.wlan_auto_connect android.permission.WRITE_SECURE_SETTINGS
     ```
   - **方案二（Shizuku）**：安装并启动 Shizuku 后，在应用设置页点击授权；
4. 手机厂商（如 HyperOS/MIUI）需在设置中允许应用「自启动」，否则开机认证与磁贴可能失效。

## 本地构建

```bash
flutter build windows --release   # Windows 版
flutter build apk --release       # Android 版（输出 build/app/outputs/flutter-apk/）
```

要求：Flutter SDK（含 Windows 桌面支持）、Android SDK（compileSdk 37）。

## 隐私说明

- 账号、密码等全部数据仅保存在本机（Windows 为 DPAPI 加密的本地文件，Android 为应用沙箱），不上传、不同步、不收集；
- 仅向校园网认证服务器发送认证必需的请求，不连接任何其他外部服务器。

## 免责声明

- 本工具仅供学习交流与个人校园网自动认证使用，请遵守所在学校/单位的网络管理规定；
- 请勿用于登录他人账号或任何未授权的网络访问；
- 使用本工具产生的一切后果由使用者自行承担。

## License

[MIT](LICENSE) © 2026 ZhaoyuanGuo
