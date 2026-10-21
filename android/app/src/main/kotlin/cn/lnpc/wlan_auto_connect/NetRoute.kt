package cn.lnpc.wlan_auto_connect

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/// 系统网络路由诊断 + 「把本进程流量钉到 WLAN」。
///
/// ## 要解决的问题（2026-10-21 小米15Pro 实测定位）
/// 校园网未认证时 AC 会掐断外网，Android 因此判定该 WLAN「未验证」
/// （NetworkCapabilities 带 CAPTIVE_PORTAL、无 VALIDATED）。此时只要蜂窝可用，
/// 系统就把默认网络切到蜂窝（AOSP 的 avoid-bad-wifi 评分逻辑，HyperOS 的
/// WLAN+/移动数据加速更激进），本应用的门户请求（内网 IP）于是从移动数据发出，
/// 必然超时 —— 界面把它误报成「门户不可达，请检查认证服务器地址」，而地址其实没错。
/// 实测判据：`curl http://172.16.200.11/...` 超时，同一命令加 `--interface wlan0`
/// 立刻 200；`dumpsys connectivity` 的 Active default network 指向 MOBILE。
///
/// - [diagnose]：只读快照，让 Dart 侧能把「地址填错」与「流量被移动数据抢走」分开提示。
/// - [bindWifi] / [unbind]：向系统申请 WLAN 网络并把整个进程的 socket 绑上去，
///   使门户请求不再依赖默认网络的归属。系统是否把未验证网络交给普通应用取决于
///   机型与 targetSdk（Android 9+ 对 captive portal 网络有 well-behaved 过滤），
///   因此调用方必须按返回码优雅降级，不能假定一定成功。
object NetRoute {
    /// 等待系统交付 WLAN 的上限（秒）。requestNetwork 的超时单位就是秒。
    private const val BIND_TIMEOUT_SEC = 4

    /// 当前已绑定的网络与对应的回调（保持注册，解绑时才注销）。
    private var boundNetwork: Network? = null
    private var boundCallback: ConnectivityManager.NetworkCallback? = null

    private fun cm(context: Context): ConnectivityManager? =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

    private fun capsOf(cm: ConnectivityManager, network: Network?): NetworkCapabilities? =
        network?.let { runCatching { cm.getNetworkCapabilities(it) }.getOrNull() }

    /// 全部网络里第一个匹配指定 transport 的网络。
    private fun firstWith(cm: ConnectivityManager, transport: Int): Network? =
        runCatching { cm.allNetworks }.getOrNull()?.firstOrNull { n ->
            capsOf(cm, n)?.hasTransport(transport) == true
        }

    /// 路由快照。返回字段与 Dart 侧 `RouteDiag.fromMap` 一一对应，
    /// 改动必须同步 lib/mobile/android_wlan.dart 与契约测试。
    fun diagnose(context: Context): Map<String, Any> {
        val cm = cm(context)
        val activeCaps = cm?.let { capsOf(it, it.activeNetwork) }
        val wifiCaps =
            cm?.let { c -> capsOf(c, firstWith(c, NetworkCapabilities.TRANSPORT_WIFI)) }
        val mobile = cm?.let { c ->
            c.allNetworks.orEmpty().any { n ->
                val caps = capsOf(c, n)
                caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true &&
                        caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            }
        } ?: false
        val transport = when {
            activeCaps == null -> "none"
            activeCaps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            activeCaps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            activeCaps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "other"
        }
        return mapOf(
            "defaultTransport" to transport,
            "wifiConnected" to (wifiCaps != null),
            "wifiValidated" to (wifiCaps?.hasCapability(
                NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true),
            // CAPTIVE_PORTAL 是 API 23 起的能力位，低版本恒为 false
            "wifiCaptivePortal" to (wifiCaps?.hasCapability(
                NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL) == true),
            "mobileAvailable" to mobile,
            "bound" to (boundNetwork != null),
        )
    }

    /// 把本进程的 socket 钉到 WLAN。返回：
    /// - ok / already：绑定成功（already 表示此前已绑，调用方不必再解绑）
    /// - unsupported：系统版本过低（< API 23 无 bindProcessToNetwork）
    /// - no_wifi：系统明确回称没有可用的 WLAN 网络
    /// - lost：系统先交付了 WLAN 又立刻收回（小米15Pro + 强制门户实测即此路径，
    ///   对应 AOSP 对未验证网络的 well-behaved 过滤）
    /// - timeout / denied：等待超时 / 请求被系统拦下，调用方应回退到提示用户
    /// - error:信息
    ///
    /// 必须在后台线程调用（内部等待系统回调），且用完必须 [unbind]，
    /// 否则小组件/云端同步等流量会一直留在没有外网的校园 WLAN 上。
    fun bindWifi(context: Context): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return "unsupported"
        val cm = cm(context) ?: return "error:no_service"
        synchronized(this) {
            if (boundNetwork != null) return "already"

            val latch = CountDownLatch(1)
            var got: Network? = null
            var unavailable = false
            var lost = false
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    got = network
                    latch.countDown()
                }

                override fun onLost(network: Network) {
                    // 绑定前就掉线：当作没拿到
                    if (got === network) {
                        got = null
                        lost = true
                    }
                }

                override fun onUnavailable() {
                    unavailable = true
                    latch.countDown()
                }
            }
            // 只按 transport 过滤：不加 INTERNET 等能力要求，才可能拿到未验证的 WLAN
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build()
            try {
                cm.requestNetwork(request, callback, BIND_TIMEOUT_SEC)
            } catch (e: SecurityException) {
                return "denied"
            } catch (e: Exception) {
                return "error:${e.message}"
            }

            val arrived = latch.await(BIND_TIMEOUT_SEC + 2L, TimeUnit.SECONDS)
            val network = got
            if (!arrived) {
                runCatching { cm.unregisterNetworkCallback(callback) }
                return "timeout"
            }
            if (network == null) {
                runCatching { cm.unregisterNetworkCallback(callback) }
                return when {
                    unavailable -> "no_wifi"
                    lost -> "lost"
                    else -> "denied"
                }
            }
            return if (runCatching { cm.bindProcessToNetwork(network) }.getOrDefault(false)) {
                boundNetwork = network
                boundCallback = callback
                "ok"
            } else {
                runCatching { cm.unregisterNetworkCallback(callback) }
                "error:bind_failed"
            }
        }
    }

    /// 解除 WLAN 绑定，恢复系统默认网络选择。返回 ok / none / error:信息。
    fun unbind(context: Context): String {
        val cm = cm(context) ?: return "error:no_service"
        synchronized(this) {
            val network = boundNetwork ?: return "none"
            val callback = boundCallback
            boundNetwork = null
            boundCallback = null
            return try {
                // null 表示恢复默认（系统按网络评分自行选择）
                cm.bindProcessToNetwork(null)
                callback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
                "ok"
            } catch (e: Exception) {
                "error:${e.message}"
            }
        }
    }
}
