package cn.lnpc.wlan_auto_connect

import android.Manifest
import android.app.StatusBarManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSuggestion
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import androidx.core.content.ContextCompat
import androidx.core.content.ContextCompat.registerReceiver
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import rikka.shizuku.Shizuku

/// 提供给 Flutter 的 Android WLAN 能力：
/// - scan：扫描可见 WiFi（需「附近的设备」+ 位置权限；fresh=true 时等待一次系统刷新）
/// - currentSsid：当前连接的 SSID
/// - openWifiPanel：打开系统 WLAN 面板（Android 10+ 无法静默连网）
/// - syncNetworkSuggestions：把"已配置档案的 SSID 集合"同步为系统的开放网络建议
///   （新增缺失的、移除多余的，避免用户删除档案后系统仍自动连接）
///
/// ## MethodChannel 契约
///
/// Channel 名称：`wlan_auto_connect/android`
/// Dart 侧入口：lib/mobile/android_wlan.dart → AndroidWlan
/// 契约测试：test/method_channel_contract_test.dart（运行 `flutter test` 验证）
///
/// 以下方法名与 Dart 侧必须保持一一对应，修改任一侧时必须同步更新 _kNativeMethods 和 _kDartMethods：
/// - scan, currentSsid, openWifiPanel, syncNetworkSuggestions,
/// - requestPermissions, isLocationServiceEnabled,
/// - ensurePortalDetectionOff, restorePortalDetection, portalStatus,
/// - shizukuEnsurePortalOff, shizukuRestorePortalDetection,
///   shizukuRequestPermission, requestAddTile, refreshTile,
///   encryptSecret, decryptSecret,
///   rootEnsurePortalOff, rootRestorePortalDetection, openUrl,
///   routeDiagnose, routeBindWifi, routeUnbind
object WlanMethods {
    private const val ERR_NO_PERMISSION = "NO_PERMISSION"
    private const val PERMISSION_REQUEST_CODE = 4321
    private val mainHandler = Handler(Looper.getMainLooper())

    /// 应用自己记录的"已向系统注册的网络建议 SSID 集合"。
    /// API 30 以下无法枚举系统已有的建议，只能靠自己记录才能在删档案时回收。
    private const val SUGGEST_PREFS = "campus_suggestions"
    private const val SUGGEST_KEY = "ssids"

    /// Shizuku UserService 连接超时。
    private const val USER_SERVICE_TIMEOUT_SEC = 10L

    /// root 授权等待上限：首次调用 su 会弹 Magisk 授权窗，进程在用户
    /// 作出选择前一直阻塞，需给足反应时间。
    private const val SU_TIMEOUT_SEC = 90L

    /// 等待同一个系统权限弹窗的所有调用方。系统同一时刻只允许一个在途请求，
    /// 因此并发调用必须排队复用同一次弹窗的结果，不能各自发起请求——
    /// 否则后来者会覆盖前者的 Result，导致前一个 Dart Future 永不完成
    /// （表现为「一键连接」按钮永久置灰，只能杀进程）。
    private val pendingPermissionResults = mutableListOf<MethodChannel.Result>()

    /// 是否已有在途的系统权限弹窗。
    private var permissionRequestInFlight = false

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "scan" -> {
                val fresh = call.argument<Boolean>("fresh") ?: false
                scan(context.applicationContext, fresh, result)
            }
            "currentSsid" -> {
                if (!hasWifiPermission(context)) {
                    result.error(ERR_NO_PERMISSION, permissionHint, null)
                    return
                }
                result.success(currentSsid(context.applicationContext))
            }
            "openWifiPanel" -> {
                openWifiPanel(context.applicationContext)
                result.success(true)
            }
            "syncNetworkSuggestions" -> {
                val ssids = call.argument<List<String>>("ssids") ?: emptyList()
                result.success(syncNetworkSuggestions(context.applicationContext, ssids))
            }
            "requestPermissions" -> {
                requestPermissions(context, result)
            }
            "isLocationServiceEnabled" -> {
                result.success(isLocationServiceEnabled(context.applicationContext))
            }
            "ensurePortalDetectionOff" -> {
                result.success(ensurePortalDetectionOff(context.applicationContext))
            }
            "restorePortalDetection" -> {
                result.success(restorePortalDetection(context.applicationContext))
            }
            "portalStatus" -> {
                val appContext = context.applicationContext
                // Shizuku.pingBinder()/checkSelfPermission() 是同步 binder 调用，
                // 放到后台线程避免 Shizuku 服务端无响应时阻塞主线程。
                thread {
                    val s = portalStatus(appContext)
                    Handler(Looper.getMainLooper()).post { result.success(s) }
                }
            }
            "shizukuEnsurePortalOff" -> {
                val appContext = context.applicationContext
                // 必须后台执行：bindUserService 的回调派发到主线程队列，
                // 若在主线程 latch.await 会死锁导致 ANR
                thread {
                    val r = shizukuSetPortalDetection(appContext, off = true)
                    Handler(Looper.getMainLooper()).post { result.success(r) }
                }
            }
            "shizukuRestorePortalDetection" -> {
                val appContext = context.applicationContext
                thread {
                    val r = shizukuSetPortalDetection(appContext, off = false)
                    Handler(Looper.getMainLooper()).post { result.success(r) }
                }
            }
            "shizukuRequestPermission" -> {
                result.success(shizukuRequestPermission())
            }
            "rootEnsurePortalOff" -> {
                val appContext = context.applicationContext
                // su 可能阻塞在授权弹窗上，后台线程执行 + 回投主线程
                thread {
                    val r = rootSetPortalDetection(appContext, off = true)
                    Handler(Looper.getMainLooper()).post { result.success(r) }
                }
            }
            "rootRestorePortalDetection" -> {
                val appContext = context.applicationContext
                thread {
                    val r = rootSetPortalDetection(appContext, off = false)
                    Handler(Looper.getMainLooper()).post { result.success(r) }
                }
            }
            "routeDiagnose" -> {
                // 多次 binder 调用，放后台线程，避免系统网络服务卡住时冻住 UI
                val appContext = context.applicationContext
                thread {
                    val d = NetRoute.diagnose(appContext)
                    Handler(Looper.getMainLooper()).post { result.success(d) }
                }
            }
            "routeBindWifi" -> {
                val appContext = context.applicationContext
                // 内部要等系统回调交付网络，必须离开主线程
                thread {
                    val r = NetRoute.bindWifi(appContext)
                    Handler(Looper.getMainLooper()).post { result.success(r) }
                }
            }
            "routeUnbind" -> {
                val appContext = context.applicationContext
                thread {
                    val r = NetRoute.unbind(appContext)
                    Handler(Looper.getMainLooper()).post { result.success(r) }
                }
            }
            "openUrl" -> {
                val url = call.argument<String>("url") ?: ""
                result.success(openUrl(context.applicationContext, url))
            }
            "requestAddTile" -> {
                result.success(requestAddTile(context))
            }
            "refreshTile" -> {
                // 前台写状态后同步磁贴：清除乐观态，避免磁贴停在"正在连接..."
                CampusTileService.clearOptimistic()
                CampusTileService.pushUpdate(context.applicationContext)
                result.success(true)
            }
            "encryptSecret" -> {
                val plain = call.argument<String>("value") ?: ""
                result.success(SecretStore.encrypt(plain))
            }
            "decryptSecret" -> {
                val stored = call.argument<String>("value") ?: ""
                result.success(SecretStore.decrypt(stored))
            }
            else -> result.notImplemented()
        }
    }

    /// 请求 Wi-Fi 权限；已齐备时直接返回 true。
    ///
    /// 并发语义：多次调用共享同一次系统弹窗，弹窗关闭后每个调用方都会收到
    /// 同一结论（按回调时刻的真实授权状态判定，而非依赖 grantResults 数组，
    /// 以避免系统在已有在途请求时回传空数组被误判成"用户拒绝"）。
    private fun requestPermissions(context: Context, result: MethodChannel.Result) {
        val perms = requiredWifiPermissions()
        val missing = perms.filter {
            ContextCompat.checkSelfPermission(context, it) !=
                    PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        val activity = context as? android.app.Activity
        if (activity == null) {
            // 无法发起弹窗（非前台 Activity）。这不等于"用户拒绝"，但 Dart 侧
            // 只能拿到布尔值，故返回 false 并在调用方按"未授予"提示。
            result.success(false)
            return
        }
        pendingPermissionResults.add(result)
        if (permissionRequestInFlight) return // 复用已弹出的窗口
        permissionRequestInFlight = true
        activity.requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST_CODE)
    }

    /// MainActivity.onRequestPermissionsResult 转发；返回 true 表示已消费。
    fun handlePermissionResult(
        context: Context,
        requestCode: Int,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        permissionRequestInFlight = false
        // 以真实授权状态为准：系统在"已有在途请求"时会回传空 grantResults，
        // 若按数组判定会误报成用户拒绝。
        val granted = hasWifiPermission(context)
        val pending = pendingPermissionResults.toList()
        pendingPermissionResults.clear()
        for (r in pending) r.success(granted)
        return true
    }

    /// 当前系统版本下 Wi-Fi 扫描 / 读取 SSID 需要申请的权限集合。
    /// Android 13 起「附近的设备」用于读取 SSID / 网络建议等 API，但
    /// startScan()/getScanResults() 在任何版本都仍要求位置权限（扫描结果被
    /// 系统视为位置数据，NEARBY 的 neverForLocation 不会放行它），
    /// 所以 13+ 必须两者都申请，否则高版本上扫描返回空列表。
    private fun requiredWifiPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            listOf(
                Manifest.permission.NEARBY_WIFI_DEVICES,
                Manifest.permission.ACCESS_FINE_LOCATION,
            )
        } else {
            listOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            )
        }

    /// Wi-Fi 扫描 / 读取 SSID 的权限门禁。
    /// - Android 13+：需同时持有「附近的设备」与位置权限——前者供
    ///   getConnectionInfo()/网络建议等 API，后者是 scanResults 的硬要求。
    ///   升级安装的老用户若只有定位，首次调用会触发 requestPermissions
    ///   把缺的补齐，不会死锁。
    /// - Android 12 及以下：定位权限。
    private fun hasWifiPermission(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val nearby = ContextCompat.checkSelfPermission(
                context, Manifest.permission.NEARBY_WIFI_DEVICES
            ) == PackageManager.PERMISSION_GRANTED
            // 扫描结果的硬门禁是位置权限，缺一不可；仅有 NEARBY 时
            // scanResults 会被系统静默清空（Android 13~17 均如此）。
            return nearby && hasLocation(context)
        }
        return hasLocation(context)
    }

    /// 权限缺失时的提示文案（区分"附近的设备"与"位置信息"，避免误导排查方向）。
    private val permissionHint: String
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            "缺少「附近的设备」或「位置信息」权限（扫描 WiFi 两者缺一不可）"
        } else {
            "缺少位置权限"
        }

    /// 系统定位服务是否开启（扫描 WiFi / 读取 SSID 需要它）。
    private fun isLocationServiceEnabled(context: Context): Boolean {
        return try {
            val lm = context.getSystemService(Context.LOCATION_SERVICE)
                    as android.location.LocationManager
            lm.isProviderEnabled(android.location.LocationManager.GPS_PROVIDER) ||
                    lm.isProviderEnabled(android.location.LocationManager.NETWORK_PROVIDER)
        } catch (e: Exception) {
            true
        }
    }

    private fun hasLocation(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED ||
                ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED

    private fun wifiManager(context: Context): WifiManager =
        context.getSystemService(Context.WIFI_SERVICE) as WifiManager

    fun currentSsid(context: Context): String {
        val info = try {
            wifiManager(context).connectionInfo
        } catch (e: SecurityException) {
            null
        } ?: return ""
        val ssid = info.ssid?.removeSurrounding("\"") ?: ""
        return if (ssid.isEmpty() || ssid == "<unknown ssid>") "" else ssid
    }

    private fun scan(context: Context, fresh: Boolean, result: MethodChannel.Result) {
        if (!hasWifiPermission(context)) {
            result.error(ERR_NO_PERMISSION, permissionHint, null)
            return
        }
        // 通道回调在主线程，扫描等待放后台线程执行，结果经 Handler 回投主线程
        thread {
            var error: String? = null
            val list = mutableListOf<Map<String, Any>>()
            try {
                if (fresh) {
                    // 等待一次 SCAN_RESULTS_AVAILABLE_ACTION（系统限流时最多等 2.5 秒）
                    val latch = CountDownLatch(1)
                    val receiver = object : BroadcastReceiver() {
                        override fun onReceive(c: Context?, i: Intent?) {
                            latch.countDown()
                        }
                    }
                    val filter = IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION)
                    registerReceiver(context, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
                    try {
                        wifiManager(context).startScan()
                        latch.await(2500, TimeUnit.MILLISECONDS)
                    } finally {
                        try {
                            context.unregisterReceiver(receiver)
                        } catch (_: Exception) {
                        }
                    }
                }
                val cur = currentSsid(context)
                list.addAll(
                    wifiManager(context).scanResults
                        .filter { !it.SSID.isNullOrEmpty() }
                        .groupBy { it.SSID }
                        .map { (ssid, items) ->
                            val best = items.maxOf { it.level }
                            mapOf(
                                "ssid" to ssid,
                                "signal" to WifiManager.calculateSignalLevel(best, 100),
                                "connected" to (ssid == cur),
                            )
                        }
                        .sortedByDescending { it["signal"] as Int }
                )
            } catch (e: SecurityException) {
                error = ERR_NO_PERMISSION
            } catch (e: Exception) {
                // 返回空列表，由 Dart 层提示
            }
            mainHandler.post {
                if (error != null) result.error(error, permissionHint, null)
                else result.success(list)
            }
        }
    }

    private fun openWifiPanel(context: Context) {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            Intent(Settings.Panel.ACTION_WIFI)
        } else {
            Intent(Settings.ACTION_WIFI_SETTINGS)
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    /// 把"已配置档案的 SSID 集合"同步为系统的开放网络建议。
    ///
    /// 只 setSsid（不设 PSK）适用于校园网这类开放网络；用户档案里没有 Wi-Fi 密码
    /// 字段，对 WPA2 网络注册建议没有意义，故不做处理。
    ///
    /// 关键点：**同时移除多余的旧建议**。原实现只 add 不 remove —— 用户在应用内
    /// 删除档案或"清除全部数据"后，系统仍会继续自动连接该 SSID，而此时应用已无
    /// 对应账号，后台认证必然失败，用户只能卸载应用或去系统设置手动清理。
    ///
    /// 已注册集合的来源：应用自己记录的集合（各版本都可用）∪ 系统当前建议
    /// （API 30+ 才能枚举）。返回 unsupported / ok / error:<msg>
    private fun syncNetworkSuggestions(context: Context, ssids: List<String>): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return "unsupported"
        return try {
            val wm = wifiManager(context)
            val wanted = ssids.filter { it.isNotEmpty() }.toSet()

            val prefs = context.getSharedPreferences(SUGGEST_PREFS, Context.MODE_PRIVATE)
            val recorded = prefs.getStringSet(SUGGEST_KEY, emptySet())?.toSet() ?: emptySet()
            val systemKnown = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                wm.networkSuggestions.mapNotNull { it.ssid }.filter { it.isNotEmpty() }.toSet()
            } else {
                emptySet()
            }

            val stale = (recorded + systemKnown) - wanted
            if (stale.isNotEmpty()) {
                wm.removeNetworkSuggestions(
                    stale.map { WifiNetworkSuggestion.Builder().setSsid(it).build() }
                )
            }

            if (wanted.isNotEmpty()) {
                // 对已存在的建议重复 add 是幂等的，直接全量提交即可
                val status = wm.addNetworkSuggestions(
                    wanted.map { WifiNetworkSuggestion.Builder().setSsid(it).build() }
                )
                if (status != WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS) {
                    return "error:add=$status"
                }
            }
            prefs.edit().putStringSet(SUGGEST_KEY, wanted).apply()
            "ok"
        } catch (e: Exception) {
            "error:${e.message}"
        }
    }

    /// 方案一：直接（凭 WRITE_SECURE_SETTINGS）恢复系统联网检测。
    /// 卸载应用或用户想还原系统行为时使用。
    /// 返回：already_on / restored / no_permission / error:<msg>
    private fun restorePortalDetection(context: Context): String {
        return try {
            val cr = context.contentResolver
            val detection = Settings.Global.getInt(cr, "captive_portal_detection_enabled", 1)
            val mode = Settings.Global.getInt(cr, "captive_portal_mode", 1)
            if (detection == 1 && mode == 1) {
                "already_on"
            } else {
                Settings.Global.putInt(cr, "captive_portal_detection_enabled", 1)
                Settings.Global.putInt(cr, "captive_portal_mode", 1)
                "restored"
            }
        } catch (e: SecurityException) {
            "no_permission"
        } catch (e: Exception) {
            "error:${e.message}"
        }
    }

    /// 自动关闭系统联网检测（captive portal）：连接开放网络后系统检测到门户
    /// 认证会自动拉起浏览器，与本应用的静默登录抢戏。认证由本应用直接向
    /// 门户发 HTTP 请求完成，无需系统代劳，故直接关闭检测。
    /// 需 WRITE_SECURE_SETTINGS 权限（adb pm grant 授予，一次永久有效）。
    /// 返回状态：already_off / disabled / no_permission / error:<msg>
    private fun ensurePortalDetectionOff(context: Context): String {
        return try {
            val cr = context.contentResolver
            val detection = Settings.Global.getInt(
                cr, "captive_portal_detection_enabled", 1
            )
            val mode = Settings.Global.getInt(cr, "captive_portal_mode", 1)
            if (detection == 0 && mode == 0) {
                "already_off"
            } else {
                Settings.Global.putInt(cr, "captive_portal_detection_enabled", 0)
                Settings.Global.putInt(cr, "captive_portal_mode", 0)
                "disabled"
            }
        } catch (e: SecurityException) {
            "no_permission"
        } catch (e: Exception) {
            "error:${e.message}"
        }
    }

    /// 联网检测当前状态 + 三条修复方案的可用性，供设置页卡片渲染。
    fun portalStatus(context: Context): Map<String, Any> {
        val cr = context.contentResolver
        val detection = Settings.Global.getInt(cr, "captive_portal_detection_enabled", 1)
        val mode = Settings.Global.getInt(cr, "captive_portal_mode", 1)
        val writePerm = ContextCompat.checkSelfPermission(
            context, "android.permission.WRITE_SECURE_SETTINGS"
        ) == PackageManager.PERMISSION_GRANTED
        val shizukuRunning = try {
            Shizuku.pingBinder()
        } catch (_: Throwable) {
            false
        }
        val shizukuPerm = try {
            shizukuRunning &&
                    Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        } catch (_: Throwable) {
            false
        }
        return mapOf(
            "off" to (detection == 0 && mode == 0),
            "writePerm" to writePerm,
            "shizukuRunning" to shizukuRunning,
            "shizukuPerm" to shizukuPerm,
            // 仅探测 su 二进制存在性（不执行 su，不会触发授权弹窗）
            "rootAvail" to (suPath() != null),
        )
    }

    /// 方案二：通过 Shizuku（shell 权限）写 `settings put global captive_portal_*`。
    /// [off] = true 关闭系统联网检测，false 恢复系统默认。
    /// 返回：already_off / disabled / already_on / restored / not_running /
    ///       no_permission / error:user_service_failed / error:exit=N / error:<msg>
    private fun shizukuSetPortalDetection(context: Context, off: Boolean): String {
        val running = try {
            Shizuku.pingBinder()
        } catch (_: Throwable) {
            false
        }
        if (!running) return "not_running"
        val perm = try {
            Shizuku.checkSelfPermission()
        } catch (_: Throwable) {
            -1
        }
        if (perm != PackageManager.PERMISSION_GRANTED) return "no_permission"

        // 先读当前状态做短路。原实现缺这一步，导致 Dart 侧专门为 already_off
        // 写的分支永远不会被返回。
        val cr = context.contentResolver
        val detection = Settings.Global.getInt(cr, "captive_portal_detection_enabled", 1)
        val mode = Settings.Global.getInt(cr, "captive_portal_mode", 1)
        if (off && detection == 0 && mode == 0) return "already_off"
        if (!off && detection == 1 && mode == 1) return "already_on"

        val command = if (off) {
            "settings put global captive_portal_detection_enabled 0; " +
                    "settings put global captive_portal_mode 0"
        } else {
            "settings put global captive_portal_detection_enabled 1; " +
                    "settings put global captive_portal_mode 1"
        }
        return when (val exit = runAsShell(context, command)) {
            null -> "error:user_service_failed"
            0 -> if (off) "disabled" else "restored"
            else -> "error:exit=$exit"
        }
    }

    /// 探测 su 二进制路径（不执行 su，因此不会触发授权弹窗）。
    /// 用 `command -v` 而非逐个文件存在性检查：Magisk/KSU/APatch 的安装位置
    /// 各不相同（/sbin、/debug_ramdisk、/system_ext/bin 等），交给 PATH 解析。
    private fun suPath(): String? {
        return try {
            val p = Runtime.getRuntime().exec(arrayOf("sh", "-c", "command -v su"))
            val out = p.inputStream.bufferedReader().readText().trim()
            p.waitFor(3, TimeUnit.SECONDS)
            if (p.exitValue() == 0 && out.isNotEmpty()) out else null
        } catch (e: Exception) {
            null
        }
    }

    /// 方案三：通过 root（su）关闭/恢复系统联网检测。
    /// 首次执行 su 会弹 Magisk/Superuser 授权窗（即“弹窗申请权限”），
    /// 用户拒绝或设备未 root 时以非零退出码结束。
    /// 返回：already_off / disabled / already_on / restored / no_su / denied /
    ///       error:timeout / error:not_applied / error:<msg>
    private fun rootSetPortalDetection(context: Context, off: Boolean): String {
        if (suPath() == null) return "no_su"

        // 先读当前状态做短路，与 shizukuSetPortalDetection 保持一致
        val cr = context.contentResolver
        fun stateOff(): Boolean =
            Settings.Global.getInt(cr, "captive_portal_detection_enabled", 1) == 0 &&
                    Settings.Global.getInt(cr, "captive_portal_mode", 1) == 0
        if (off && stateOff()) return "already_off"
        if (!off && !stateOff()) return "already_on"

        val command = if (off) {
            "settings put global captive_portal_detection_enabled 0; " +
                    "settings put global captive_portal_mode 0"
        } else {
            "settings put global captive_portal_detection_enabled 1; " +
                    "settings put global captive_portal_mode 1"
        }
        return try {
            // 注意：su 进程在用户回答授权弹窗前不会退出，超时需覆盖反应时间
            val p = Runtime.getRuntime().exec(arrayOf("su", "-c", command))
            if (!p.waitFor(SU_TIMEOUT_SEC, TimeUnit.SECONDS)) {
                p.destroy()
                return "error:timeout"
            }
            if (p.exitValue() != 0) return "denied"
            // 退出码 0 不等于生效（部分 ROM 的 su 壳会吞掉 settings 失败），回读确认
            if (stateOff() == off) {
                if (off) "disabled" else "restored"
            } else {
                "error:not_applied"
            }
        } catch (e: Exception) {
            "error:${e.message}"
        }
    }

    /// 用系统浏览器/对应应用打开 http(s) 链接（Shizuku 下载兜底等引导场景）。
    /// 仅放行 http/https，避免被构造为 file:/content: 等敏感 Intent。
    private fun openUrl(context: Context, url: String): Boolean {
        val uri = try {
            Uri.parse(url)
        } catch (e: Exception) {
            return false
        }
        if (uri.scheme != "https" && uri.scheme != "http") return false
        return try {
            context.startActivity(
                Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    /// 通过 Shizuku UserService 以 shell(uid 2000) 身份执行一条命令。
    /// 返回退出码；**null 表示 UserService 未能建立连接**。
    ///
    /// 为什么要把 null 与退出码区分开：部分 ROM 定制会让 UserService 进程创建直接
    /// 失败（典型如联发科在 `LoadedApk.makeApplicationInner()` 里调用
    /// `Application.getProcessName().equals()`，而 Shizuku 的辅助进程里该方法返回
    /// null），此时 `onServiceConnected` 永不回调。原实现只有 "error:timeout" 一种
    /// 表现，用户无法区分「未授权 / 服务端卡住 / ROM 不兼容」，只会按提示反复重试。
    private fun runAsShell(context: Context, command: String): Int? {
        return try {
            val latch = CountDownLatch(1)
            var exit: Int? = null
            val args = Shizuku.UserServiceArgs(ComponentName(context, ShellService::class.java))
                .processNameSuffix("shell_service")
                .version(1)
            val connection = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                    try {
                        val svc = IShellService.Stub.asInterface(binder)
                        exit = svc?.exec(arrayOf("sh", "-c", command))
                    } catch (e: Throwable) {
                        android.util.Log.w("ShellService", "执行命令失败", e)
                        exit = null
                    } finally {
                        latch.countDown()
                    }
                }

                override fun onServiceDisconnected(name: ComponentName?) {}
            }
            Shizuku.bindUserService(args, connection)
            if (!latch.await(USER_SERVICE_TIMEOUT_SEC, TimeUnit.SECONDS)) {
                android.util.Log.w(
                    "ShellService",
                    "UserService 未在 ${USER_SERVICE_TIMEOUT_SEC}s 内连接。" +
                            "常见原因是 ROM 定制导致 LoadedApk.makeApplication 抛 NPE" +
                            "（联发科机型 + Shizuku 13.6.0 已确认），" +
                            "可降级 Shizuku 至 13.5.4 或改用 adb 方案。"
                )
            }
            try {
                Shizuku.unbindUserService(args, connection, true)
            } catch (_: Throwable) {
            }
            exit
        } catch (e: Throwable) {
            android.util.Log.w("ShellService", "bindUserService 异常", e)
            null
        }
    }

    /// 请求 Shizuku 授权（系统弹出 Shizuku 管理器授权窗），结果异步生效，
    /// Dart 侧稍后重查 portalStatus 即可。
    private fun shizukuRequestPermission(): Boolean {
        return try {
            Shizuku.requestPermission(7777)
            true
        } catch (_: Throwable) {
            false
        }
    }

    /// Android 13+：弹出系统「将功能块添加到快捷设置」确认窗（磁贴添加入口）。
    /// 返回 false 表示系统不支持（由应用引导手动添加）。
    private fun requestAddTile(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        val activity = context as? android.app.Activity ?: return false
        return try {
            val sbm = activity.getSystemService(StatusBarManager::class.java) ?: return false
            sbm.requestAddTileService(
                ComponentName(activity, CampusTileService::class.java),
                "校园网一键连接",
                android.graphics.drawable.Icon.createWithResource(
                    activity, R.drawable.ic_tile_campus
                ),
                ContextCompat.getMainExecutor(activity),
            ) { }
            true
        } catch (_: Throwable) {
            false
        }
    }
}
