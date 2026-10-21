# 辽宁警察学院校园网自动登录 · 使用教程

> 适用对象：辽宁警察学院（LNPC）校园网用户，WiFi 名 **LNPC-STU**（Dr.COM / 哆点 eportal v4 认证）。
> 本工具可在连上校园网后自动完成网页认证，支持开机自启、桌面小组件 / 磁贴，覆盖 **Windows、Android、iPhone / iPad** 三平台，全程无需手动打开认证网页。
> 官网：https://wlan.suspect.top ｜ 图文教程页：https://wlan.suspect.top/help.html
> 说明：文中演示截图里的账号 `20250001` 为**虚构示例**，请填入你自己的真实学号与密码。

---

## 一、Windows（v1.1.0 · 免管理员安装 · 支持 Win10 / Win11）

桌面版适合经常用笔记本在宿舍 / 教室连校园网的同学：连上 LNPC-STU 后自动完成网页认证，还能开机静默自启、屏蔽系统弹浏览器。

**0. 下载并安装**
在官网首页「下载应用 → 获取 Windows 版」下载安装包 `wlan-auto-connect-v1.1.0-setup.exe`，双击安装（无需管理员权限），完成后从开始菜单打开「校园网自动登录」。
下载地址：https://wlan.suspect.top/dl/wlan-auto-connect-v1.1.0-setup.exe

**1. 阅读并同意用户协议**
首次打开显示《用户协议与隐私声明》。向下滚动阅读到最后一页后，「同意并继续」按钮才会亮起，点击即可进入；不同意可点「退出应用」。
![Windows 用户协议](https://wlan.suspect.top/help-assets/windows/win-01-agreement.png)
![Windows 协议底部同意按钮](https://wlan.suspect.top/help-assets/windows/win-01b-agreement-bottom.png)

**2. 查看使用说明**
进入前会弹出「使用说明」，介绍数据本地保存、一键连接、开机自启等要点，点「我知道了」进入主界面。
![Windows 使用说明](https://wlan.suspect.top/help-assets/windows/win-02-usage.png)

**3. 认识主界面**
左侧是「WiFi 网络」与「登录信息」，右侧是「运行日志」；右上角显示当前联网状态（已联网 / 未联网），并提供语言切换与刷新按钮。
![Windows 主界面](https://wlan.suspect.top/help-assets/windows/win-03-home.png)

**4. 填写账号并完成一次认证**
点「WiFi 网络」右上角扫描并选择本校 **LNPC-STU**（也可不选、直接手动登录）。在「登录信息」填写**学号 / 账号**、**密码**，选择**运营商**（校园用户 / 电信 / 联通 / 移动），点「保存此 WiFi 账号」，再点「立即连接」即可完成一次认证。
![Windows 填写登录信息](https://wlan.suspect.top/help-assets/windows/win-04-login-form.png)

**5. 开启开机自动登录**
在「开机自动登录」卡片点「保存并开启」，之后每次开机登录桌面即对星标 WiFi 静默认证，全程无窗口。可选开启「阻止自动弹出认证网页」，屏蔽 Windows 强制门户探测（需管理员确认）。
![Windows 开机自启](https://wlan.suspect.top/help-assets/windows/win-05-autostart.png)

**6. 认证服务器与云端同步**
默认认证服务器为 `172.16.200.11:801`（Dr.COM / 哆点），本校无需改动；其他学校点右侧铅笔图标修改。「云端同步」可用友爱账号跨设备备份 / 恢复 WiFi 配置。
![Windows 认证服务器与云端](https://wlan.suspect.top/help-assets/windows/win-06-server-cloud.png)

**7. 修改 / 自动探测认证服务器**
点认证服务器的铅笔图标弹出编辑框，可手动填写门户地址与端口；连上校园网且尚未认证时，也可点「自动探测」自动识别门户地址。
![Windows 认证服务器弹窗](https://wlan.suspect.top/help-assets/windows/win-07-portal-dialog.png)

**8. 登录云端账号（可选）**
进入「云端同步」页，用手机号注册 / 登录友爱账号（Uniai），一次注册多端登录。WiFi 档案加密上传，仅本人登录后可读取，可随时删除云端备份。
![Windows 云端登录](https://wlan.suspect.top/help-assets/windows/win-08-cloud.png)

---

## 二、Android（v1.2.1 · 一键连接 · 桌面小组件 / 磁贴 · 联网检测守护）

安卓版支持桌面小组件与控制中心磁贴一键认证，还可关闭系统联网探测实现全程静默。

**0. 下载并安装 APK**
在官网首页「下载应用 → 获取 Android 版」，选择对应架构（近几年的手机选 **64 位 arm64-v8a**），下载 APK 传到手机安装。若提示「未知来源 / 允许安装」，允许即可。
64 位直链：https://wlan.suspect.top/dl/wlan-auto-connect-v1.2.1-arm64-v8a.apk

**1. 阅读并同意用户协议**
首次打开显示《用户协议与隐私声明》，向下滚动到最后一页后「同意并继续」按钮亮起，点击继续。
![Android 用户协议](https://wlan.suspect.top/help-assets/android/and-01-agreement.png)
![Android 协议底部](https://wlan.suspect.top/help-assets/android/and-01b-agreement-bottom.png)

**2. 查看使用说明**
进入前弹出「使用说明」，介绍数据本地保存、一键连接、开机自动认证，点「我知道了」进入首页。
> 权限说明：首次进入时系统会请求**位置信息**与**附近的设备**权限——这是 Android 扫描 WiFi 的系统要求，本软件不会获取你的地理位置轨迹，选择「使用时允许 / 允许」即可。
![Android 使用说明](https://wlan.suspect.top/help-assets/android/and-02-usage.png)

**3. 认识首页**
首页顶部大字显示联网状态（已联网 / 需要登录 / 未连接），下方是「一键连接校园网」按钮，以及「开机自动认证」开关与「桌面小组件 / 快捷按钮」入口。底部在「首页 / 配置 / 设置」三个标签间切换。
![Android 首页](https://wlan.suspect.top/help-assets/android/and-03-home.png)

**4. 选择校园网 WiFi**
切到「配置」标签，点右上角雷达图标扫描，在 WiFi 列表中点选本校 **LNPC-STU**（点条目选择配置，点星标设为自启，仅可设一个）。
![Android 配置页](https://wlan.suspect.top/help-assets/android/and-04-config.png)

**5. 填写账号与密码**
在「登录信息」填写**学号 / 账号**与**密码**，选择**运营商**，点「保存账号」（或「保存并设为自启」）。保存后回到首页点「一键连接校园网」即可完成认证。
![Android 填写表单](https://wlan.suspect.top/help-assets/android/and-05-form-filled.png)

**6. 设置页一览**
「设置」标签包含：**认证服务器**（默认 172.16.200.11:801）、**联网检测守护**（adb / Shizuku / root 三种方案，关闭系统探测后认证全程静默不弹浏览器）、**云端同步** 与 **深色模式**。
![Android 设置页](https://wlan.suspect.top/help-assets/android/and-06-settings.png)

**7. 修改 / 自动探测认证服务器**
点「认证服务器」弹出编辑框，可填门户地址与端口；连上校园网且未认证时点「自动探测」自动识别。本校默认值无需改动。
![Android 认证服务器弹窗](https://wlan.suspect.top/help-assets/android/and-07-portal-dialog.png)

**8. 云端同步（可选）**
进入「云端同步」，按提示填写服务器域名并登录友爱账号（Uniai），即可在多设备间加密备份 / 恢复 WiFi 配置。
![Android 云端同步](https://wlan.suspect.top/help-assets/android/and-08-cloud.png)

**＋. 添加桌面小组件 / 控制中心磁贴**
在桌面长按「添加小组件」，搜索「校园网自动登录」放到桌面；或从下拉快捷设置添加磁贴。之后**无需打开应用**即可一键触发认证，实时查看连接状态。（系统级小组件 / 磁贴添加界面各厂商略有差异。）

> Shizuku 兜底直链（联网检测守护辅助工具，v13.5.4 推荐）：https://dl.suspect.top/wlan/shizuku/shizuku-v13.5.4.apk

---

## 三、iPhone / iPad（快捷指令 · 无需安装 App · 无需越狱 / 描述文件）

iOS / iPadOS 版通过苹果自带的「快捷指令」实现，导入一次、首次输入账号密码（仅存本机），以后连上校园网即可自动登录，不上传任何服务器。

**1. 用 Safari 打开官网，进入 iPhone / iPad 入口**
在 iPhone / iPad 上用 **Safari** 打开官网 https://wlan.suspect.top ，在「下载应用」区找到 **iPhone / iPad** 卡片，点「获取 iPhone / iPad 快捷指令」。
![iPad 官网下载区](https://wlan.suspect.top/help-assets/ios/ios-01-site.png)

**2. 在分享页点「导入快捷指令」**
进入分享页后，点蓝色「导入『校园网自动登陆』快捷指令」按钮。母版不含任何账号密码、只在你自己设备上运行，可放心安装。
![iPad 分享页](https://wlan.suspect.top/help-assets/ios/ios-02-sharepage.png)

**3. 添加快捷指令**
系统会自动跳到「快捷指令」App 并弹出「校园网自动登陆」捷径卡片，点「添加快捷指令」完成导入。若首次运行被拦截，前往「设置 → 快捷指令」打开「允许不受信任的快捷指令」（iOS 17+ 一般无需）。
![iPad 添加快捷指令](https://wlan.suspect.top/help-assets/ios/ios-03-add-shortcut.png)

**4. 首次运行输入账号与密码**
连上 **LNPC-STU** 后运行「校园网自动登陆」，会依次弹出输入**校园网账号**与**密码**。凭据仅保存在本机（`campus.txt`），不上传、不同步 iCloud。
![iPad 输入账号](https://wlan.suspect.top/help-assets/ios/ios-04-input-account.png)
![iPad 输入密码](https://wlan.suspect.top/help-assets/ios/ios-05-input-password.png)

**5. 完成：已保存凭证 · 认证成功**
输入后顶部通知「已保存凭证，以后将自动登录」，随后弹出「认证成功」。以后连上校园网直接运行即免输入；想彻底免点，进「快捷指令 → 自动化」新建「当连接到 LNPC-STU 时 → 运行『校园网自动登陆』」。
![iPad 已保存凭证](https://wlan.suspect.top/help-assets/ios/ios-06-saved.png)
![iPad 认证成功](https://wlan.suspect.top/help-assets/ios/ios-07-success.png)

**6. 添加到主屏幕 / 控制中心（可选）**
在「所有快捷指令」长按「校园网自动登陆」→「分享」→「添加到主屏幕」，可自定义名称与图标。之后桌面一键即可登录，无需进入 App。
![iPad 分享面板](https://wlan.suspect.top/help-assets/ios/ios-08-share-sheet.png)
![iPad 添加到主屏幕](https://wlan.suspect.top/help-assets/ios/ios-09-add-to-home.png)

---

## 常见问题（FAQ）

- **默认认证服务器地址？** `172.16.200.11:801`（Dr.COM / 哆点 eportal v4），本校无需修改。
- **密码存在哪里？安全吗？** Windows 用 DPAPI 加密、Android 存应用沙箱、iOS 快捷指令存本机 `campus.txt`，默认都只在本机，不上传、不共享。云端同步为可选，需你主动注册登录并开启后才加密上传，可随时删除。
- **Android 为什么要定位 / 附近设备权限？** 这是 Android 系统扫描 WiFi 的强制要求，本软件不会上传或记录你的地理位置轨迹。
- **联网检测守护是做什么的？** 关闭系统强制门户探测，避免认证前被系统抢占式弹出浏览器，让认证全程静默。可用 adb / Shizuku / root 三种方案。
- **iPhone / iPad 需要装 App 吗？** 不需要。用系统自带的「快捷指令」实现，无需越狱、无需描述文件。
- **提示连不上 / 认证失败怎么办？** 确认已连上 LNPC-STU、账号密码正确、运营商选择正确；可在应用内查看诊断日志，或到设置里点「自动探测」重新识别门户。
- **开着移动数据时提示「门户不可达 / 流量走移动数据」？** 这不是地址填错：校园网未认证时系统会判定该 WiFi 无外网，并把应用流量改走移动数据，而认证门户是内网地址，从移动数据访问必然超时。临时解法：**关掉移动数据**再点一次「一键连接」；根治：进「设置 → 联网检测守护」用 adb / Shizuku / root 任一方案**关闭系统联网检测**（授权一次永久有效，之后每次启动自动维持），或关掉手机 WLAN 助理 / 移动数据加速类开关。小米 / 红米（HyperOS）、双卡常驻数据的机型最容易碰到。
