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
/// - scan：扫描可见 WiFi（需定位权限；fresh=true 时等待一次系统刷新）
/// - currentSsid：当前连接的 SSID
/// - openWifiPanel：打开系统 WLAN 面板（Android 10+ 无法静默连网）
/// - suggestNetwork：注册开放网络建议，帮助系统自动连接校园网
object WlanMethods {
    private const val ERR_NO_PERMISSION = "NO_PERMISSION"
    private const val PERMISSION_REQUEST_CODE = 4321
    private val mainHandler = Handler(Looper.getMainLooper())

    /// 待回复的权限请求结果（requestPermissions 异步回调）。
    private var pendingPermissionResult: MethodChannel.Result? = null

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "scan" -> {
                val fresh = call.argument<Boolean>("fresh") ?: false
                scan(context.applicationContext, fresh, result)
            }
            "currentSsid" -> {
                if (!hasLocation(context)) {
                    result.error(ERR_NO_PERMISSION, "缺少位置权限", null)
                    return
                }
                result.success(currentSsid(context.applicationContext))
            }
            "openWifiPanel" -> {
                openWifiPanel(context.applicationContext)
                result.success(true)
            }
            "suggestNetwork" -> {
                val ssid = call.argument<String>("ssid") ?: ""
                result.success(suggestNetwork(context.applicationContext, ssid))
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
            "portalStatus" -> {
                result.success(portalStatus(context.applicationContext))
            }
            "shizukuEnsurePortalOff" -> {
                val appContext = context.applicationContext
                // 必须后台执行：bindUserService 的回调派发到主线程队列，
                // 若在主线程 latch.await 会死锁 15s 导致 ANR
                thread {
                    val r = shizukuEnsurePortalOff(appContext)
                    Handler(Looper.getMainLooper()).post { result.success(r) }
                }
            }
            "shizukuRequestPermission" -> {
                result.success(shizukuRequestPermission())
            }
            "requestAddTile" -> {
                result.success(requestAddTile(context))
            }
            else -> result.notImplemented()
        }
    }

    /// 请求定位 +（Android 13+）附近设备权限；已全部授予时直接返回 true。
    private fun requestPermissions(context: Context, result: MethodChannel.Result) {
        val perms = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            perms.add(Manifest.permission.NEARBY_WIFI_DEVICES)
        }
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
            result.success(false)
            return
        }
        pendingPermissionResult = result
        activity.requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST_CODE)
    }

    /// MainActivity.onRequestPermissionsResult 转发；返回 true 表示已消费。
    fun handlePermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val pending = pendingPermissionResult
        pendingPermissionResult = null
        pending?.success(
            grantResults.isNotEmpty() && grantResults.all {
                it == PackageManager.PERMISSION_GRANTED
            }
        )
        return true
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
        if (!hasLocation(context)) {
            result.error(ERR_NO_PERMISSION, "缺少位置权限", null)
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
                if (error != null) result.error(error, "缺少位置权限", null)
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

    /// 注册开放网络建议（Android 10+ 无法直接连接，由系统在发现该网络时提示/自动连接）。
    private fun suggestNetwork(context: Context, ssid: String): Boolean {
        if (ssid.isEmpty() || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        return try {
            val suggestion = WifiNetworkSuggestion.Builder().setSsid(ssid).build()
            wifiManager(context).addNetworkSuggestions(listOf(suggestion)) ==
                    WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS
        } catch (e: Exception) {
            false
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

    /// 联网检测当前状态 + 两条修复方案的可用性，供设置页卡片渲染。
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
        )
    }

    /// 方案二：通过 Shizuku（shell 权限）执行 settings put 关闭联网检测。
    /// 实现：bindUserService 把 ShellService 拉起到 Shizuku 服务进程（shell uid）中执行命令。
    /// 返回：already_off / disabled / not_running / no_permission / error:<msg>
    private fun shizukuEnsurePortalOff(context: Context): String {
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
        return try {
            val latch = CountDownLatch(1)
            var result = "error:timeout"
            val args = Shizuku.UserServiceArgs(ComponentName(context, ShellService::class.java))
                .processNameSuffix("shell_service")
                .version(1)
            val connection = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                    try {
                        val svc = IShellService.Stub.asInterface(binder)
                        if (svc == null) {
                            result = "error:binder_null"
                        } else {
                            val exit = svc.exec(
                                arrayOf(
                                    "sh", "-c",
                                    "settings put global captive_portal_detection_enabled 0; " +
                                            "settings put global captive_portal_mode 0"
                                )
                            )
                            result = if (exit == 0) "disabled" else "error:exit=$exit"
                        }
                    } catch (e: Throwable) {
                        result = "error:${e.message}"
                    } finally {
                        latch.countDown()
                    }
                }

                override fun onServiceDisconnected(name: ComponentName?) {}
            }
            Shizuku.bindUserService(args, connection)
            latch.await(10, TimeUnit.SECONDS)
            try {
                Shizuku.unbindUserService(args, connection, true)
            } catch (_: Throwable) {
            }
            result
        } catch (e: Throwable) {
            "error:${e.message}"
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
