package cn.lnpc.wlan_auto_connect

import android.content.Context
import org.json.JSONObject
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.URLDecoder
import java.net.URLEncoder

/// Dr.COM（哆点）eportal v4 认证协议 —— Dart 版 PortalClient 的 Kotlin 移植，
/// 供桌面小组件「一键连接」与开机自启在无 Flutter 引擎时后台执行。
///
/// 协议要点（与 lib/services/portal_client.dart 一致，2026-09-24 实机验证）：
/// - 在线状态：GET http://<host>/drcom/chkstatus?callback=dr1&jsVersion=4.X
///   返回 JSONP，result==1 在线；ss5=门户眼中本机 IP、ss1=本机 MAC（未在线也返回）。
/// - 登录：GET http://<host>:<eport>/eportal/portal/login，login_method=1，
///   必须用裸账号（不带 ",0," 前缀 / 运营商后缀拼接按档案配置），
///   会话参数优先级：AC 劫持 > chkstatus ss5/ss1 > 本机 wlan 网卡 IP。
/// - 未认证时外网 HTTP 被 AC 劫持（302 或 DNS 劫持到 a79.htm），
///   重定向 URL 携带 wlanusermac/wlanuserip/wlanacname/ssid。
/// - 响应为 UTF-8（GBK 直解会乱码）。
object CampusLogin {
    const val PREFS = "HomeWidgetPreferences"
    const val CONFIG_KEY = "cnConfig"
    const val STATUS_KEY = "cnStatus"

    private const val DEFAULT_HOST = "172.16.200.11"
    private const val DEFAULT_EPORT = 801

    data class Profile(val account: String, val suffix: String, val password: String)

    data class Config(
        val host: String,
        val eport: Int,
        val autoLoginSsid: String,
        val bootAutoLogin: Boolean,
        val profiles: Map<String, Profile>,
    )

    /// 会话参数（可能为空串，逐级回退）。
    data class Session(
        val mac: String,
        val ip: String,
        val acName: String,
        val ssid: String,
    )

    fun readConfig(context: Context): Config? {
        return try {
            val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(CONFIG_KEY, null) ?: return null
            val obj = JSONObject(raw)
            val profiles = mutableMapOf<String, Profile>()
            val rawProfiles = obj.optJSONObject("profiles") ?: JSONObject()
            for (key in rawProfiles.keys()) {
                val p = rawProfiles.optJSONObject(key) ?: continue
                profiles[key] = Profile(
                    account = p.optString("account", ""),
                    suffix = p.optString("suffix", ""),
                    // 密码以 enc:v1: 前缀密文存储（见 SecretStore）；
                    // 历史明文值会被原样返回，解密失败则视为空（需用户重新输入）。
                    password = SecretStore.decrypt(p.optString("password", "")) ?: "",
                )
            }
            Config(
                host = obj.optString("host", DEFAULT_HOST).ifEmpty { DEFAULT_HOST },
                eport = obj.optInt("eport", DEFAULT_EPORT),
                autoLoginSsid = obj.optString("autoLoginSsid", ""),
                bootAutoLogin = obj.optBoolean("bootAutoLogin", true),
                profiles = profiles,
            )
        } catch (e: Exception) {
            null
        }
    }

    /// 写入小组件状态并刷新桌面小组件界面。
    fun setStatus(context: Context, online: Boolean, text: String) {
        val status = JSONObject()
            .put("online", online)
            .put("text", text)
            .put(
                "time",
                java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault())
                    .format(java.util.Date())
            )
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(STATUS_KEY, status.toString()).apply()
        CampusTileService.clearOptimistic()
        CampusWidgetProvider.pushUpdate(context)
        CampusTileService.pushUpdate(context)
    }

    /// 执行一次完整的静默认证流程，返回最终文案。
    ///
    /// 门户是内网地址：校园网未认证时系统会把默认网络切到蜂窝，请求从移动数据发出
    /// 必然超时（表现为「门户不可达」，实为路由问题，见 NetRoute 注释）。这里在进入
    /// 网络流程前判断是否被抢占，被抢占则把进程钉到 WLAN，流程结束后解绑。
    fun run(context: Context): String {
        val bound = bindWifiIfPreempted(context)
        try {
            return runInner(context)
        } finally {
            // 只由真正拿到绑定的一方解绑，避免并发流程互相踩掉绑定
            if (bound) NetRoute.unbind(context)
        }
    }

    /// 「连着 WiFi 但系统默认网络不是 WiFi」时把进程钉到 WLAN。
    /// 返回是否由本次调用建立绑定（调用方据此决定是否解绑）。
    private fun bindWifiIfPreempted(context: Context): Boolean {
        val diag = NetRoute.diagnose(context)
        val preempted = diag["wifiConnected"] == true && diag["defaultTransport"] != "wifi"
        if (!preempted) return false
        return NetRoute.bindWifi(context) == "ok"
    }

    private fun runInner(context: Context): String {
        val cfg = readConfig(context)
        if (cfg == null || cfg.profiles.isEmpty()) {
            setStatus(context, false, "未配置账号")
            return "NO_CONFIG"
        }

        // 1. 在线检测
        val chk = chkstatus(cfg.host)
        if (chk != null && chk.first) {
            setStatus(context, true, "已联网")
            return "ONLINE_ALREADY"
        }

        // 2. 获取会话参数（AC 劫持 > chkstatus ss5/ss1 > 本机 wlan IP）
        val session = captureHijack(cfg.host)
        val ip = when {
            session.ip.isNotEmpty() -> session.ip
            chk != null && chk.second.isNotEmpty() -> chk.second
            else -> wlanIpv4()
        }
        val mac = when {
            session.mac.isNotEmpty() -> session.mac
            chk != null && chk.third.isNotEmpty() -> chk.third
            else -> ""
        }
        val acName = session.acName

        // 3. 选择档案：劫持到的 SSID > 自启 WiFi > 唯一已存档案
        val profile = pickProfile(cfg, session.ssid)
        if (profile == null) {
            setStatus(context, false, "未配置账号")
            return "NO_PROFILE"
        }

        // 4. 登录
        val v = 500 + (System.currentTimeMillis() % 10000).toInt()
        val url = "http://${cfg.host}:${cfg.eport}/eportal/portal/login" +
                "?callback=dr1&login_method=1" +
                "&user_account=" + enc(profile.account + profile.suffix) +
                "&user_password=" + enc(profile.password) +
                "&wlan_user_ip=" + enc(ip) +
                "&wlan_user_ipv6=" +
                "&wlan_user_mac=" + enc(mac) +
                "&wlan_ac_ip=" +
                "&wlan_ac_name=" + enc(acName) +
                "&jsVersion=4.X&v=$v&lang=zh"
        val (code, body, _) = httpGet(url, 8000)
        if (code == null) {
            setStatus(context, false, "未连接校园网")
            return "PORTAL_UNREACHABLE"
        }
        val json = parseJsonp(body)
        if (json == null) {
            setStatus(context, false, "响应异常")
            return "BAD_RESPONSE"
        }
        val result = json.optString("result", "")
        val ok = result == "1" || result == "ok" || json.optInt("ret_code", -1) == 2
        if (!ok) {
            val msg = json.optString("msg", "").ifEmpty { "未知错误" }
            setStatus(context, false, "登录失败")
            return "LOGIN_FAIL:$msg"
        }

        // 5. 确认上线
        try {
            Thread.sleep(2000)
        } catch (_: InterruptedException) {
        }
        val verified = chkstatus(cfg.host)?.first == true
        if (verified) {
            setStatus(context, true, "已联网")
            return "LOGIN_OK"
        }
        setStatus(context, false, "未确认")
        return "UNCONFIRMED"
    }

    private fun pickProfile(cfg: Config, ssid: String): Profile? {
        if (ssid.isNotEmpty()) {
            cfg.profiles[ssid]?.let { if (it.account.isNotEmpty()) return it }
        }
        if (cfg.autoLoginSsid.isNotEmpty()) {
            cfg.profiles[cfg.autoLoginSsid]?.let { if (it.account.isNotEmpty()) return it }
        }
        val single = cfg.profiles.values.filter { it.account.isNotEmpty() }
        return single.singleOrNull()
    }

    /// chkstatus：在线状态 + ss5(IP) / ss1(MAC)。门户不可达返回 null。
    private fun chkstatus(host: String): Triple<Boolean, String, String>? {
        val url = "http://$host/drcom/chkstatus?callback=dr1&jsVersion=4.X"
        val (code, body, _) = httpGet(url, 5000)
        if (code == null) return null
        val json = parseJsonp(body) ?: return null
        var ss5 = json.optString("ss5", "")
        var ss1 = json.optString("ss1", "")
        if (ss5 == "-") ss5 = ""
        if (ss1 == "-") ss1 = ""
        return Triple(json.optString("result", "") == "1", ss5, ss1)
    }

    /// 从 AC 劫持响应提取会话参数；未被劫持返回全空 Session。
    private fun captureHijack(host: String): Session {
        val (code, body, location) = httpGet(
            "http://www.msftconnecttest.com/connecttest.txt", 6000
        )
        if (code == null) return Session("", "", "", "")
        val hostEscaped = Regex.escape(host)
        var candidate: String? = null
        if (code in 300..399 && location.isNotEmpty() &&
            Regex("a79\\.htm|$hostEscaped").containsMatchIn(location)
        ) {
            candidate = location
        } else {
            val m = Regex("http://$hostEscaped/[^\\s\"'<>]+").find(body)
            if (m != null) candidate = m.value
        }
        if (candidate == null) return Session("", "", "", "")

        fun param(key: String): String {
            val m = Regex("$key=([^&\\s]+)").find(candidate!!)
            return if (m != null) try {
                URLDecoder.decode(m.groupValues[1], "UTF-8")
            } catch (e: Exception) {
                m.groupValues[1]
            } else ""
        }
        return Session(param("wlanusermac"), param("wlanuserip"),
            param("wlanacname"), param("ssid"))
    }

    /// 登录响应 JSONP 解析。
    private fun parseJsonp(text: String): JSONObject? {
        val s = text.indexOf('(')
        val e = text.lastIndexOf(')')
        if (s < 0 || e <= s) return null
        return try {
            JSONObject(text.substring(s + 1, e))
        } catch (e: Exception) {
            null
        }
    }

    private fun enc(s: String): String = try {
        URLEncoder.encode(s, "UTF-8")
    } catch (e: Exception) {
        s
    }

    /// 本机 wlan 网卡 IPv4（排除回环/链路本地），取不到返回空串。
    private fun wlanIpv4(): String {
        return try {
            val it = NetworkInterface.getNetworkInterfaces()
            while (it.hasMoreElements()) {
                val nif = it.nextElement()
                if (!nif.name.startsWith("wlan")) continue
                for (addr in nif.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress &&
                        !addr.isLinkLocalAddress
                    ) {
                        return addr.hostAddress ?: ""
                    }
                }
            }
            ""
        } catch (e: Exception) {
            ""
        }
    }

    /// 当前是否已连接到某个"已配置账号"的 WiFi。
    ///
    /// 后台路径用它判断此刻是否值得认证：在蜂窝网络或别的 WiFi 上尝试只会得到
    /// "未连接校园网"，并把小组件/磁贴原本正常的状态覆盖成故障态。
    fun isOnConfiguredWifi(context: Context): Boolean {
        val cfg = readConfig(context) ?: return false
        if (cfg.profiles.isEmpty()) return false
        val ssid = currentSsid(context) ?: return false
        return cfg.profiles.containsKey(ssid)
    }

    /// 当前连接 SSID；未连接 / 系统不可知（无权限时为 "<unknown ssid>"）返回 null。
    @Suppress("DEPRECATION")
    private fun currentSsid(context: Context): String? = try {
        val wm = context.getSystemService(Context.WIFI_SERVICE)
                as? android.net.wifi.WifiManager
        val raw = wm?.connectionInfo?.ssid?.removeSurrounding("\"") ?: ""
        if (raw.isEmpty() || raw == "<unknown ssid>") null else raw
    } catch (e: Exception) {
        null
    }

    /// 最小 HTTP/1.1 GET 客户端（裸 Socket 实现）。
    ///
    /// 为什么不用 HttpURLConnection：应用通过 networkSecurityConfig 收紧了明文流量
    /// （base-config `cleartextTrafficPermitted=false`），只白名单了默认门户 IP；而
    /// Dr.COM 门户地址是**用户可配置**的（还支持自动探测），静态白名单无法覆盖。
    /// HttpURLConnection 受该策略约束会被直接拦截（CLEARTEXT ... not permitted），
    /// 而 Dart 侧的 dart:io HttpClient 基于自建 socket，完全不受该策略影响 ——
    /// 于是同一个账号在 App 内认证成功、在小组件/磁贴/开机路径静默失败。
    /// 改用裸 socket 后两侧行为一致，且不必为功能放开全局明文策略。
    ///
    /// 只支持 HTTP（门户协议本身即明文），支持 Content-Length 与 chunked。
    private fun httpGet(url: String, timeoutMs: Int): Triple<Int?, String, String> {
        var socket: java.net.Socket? = null
        try {
            val uri = java.net.URI(url)
            val host = uri.host ?: return Triple(null, "", "")
            val port = if (uri.port > 0) uri.port else 80
            val path = buildString {
                append(uri.rawPath?.ifEmpty { "/" } ?: "/")
                uri.rawQuery?.let { append('?').append(it) }
            }

            val s = java.net.Socket()
            socket = s
            s.connect(java.net.InetSocketAddress(host, port), timeoutMs)
            s.soTimeout = timeoutMs
            s.tcpNoDelay = true

            val request = buildString {
                append("GET ").append(path).append(" HTTP/1.1\r\n")
                append("Host: ").append(host)
                if (port != 80) append(':').append(port)
                append("\r\n")
                append("User-Agent: Mozilla/5.0\r\n")
                append("Accept: */*\r\n")
                append("Connection: close\r\n\r\n")
            }
            s.getOutputStream().apply {
                write(request.toByteArray(Charsets.US_ASCII))
                flush()
            }

            // Connection: close ⇒ 读到 EOF；服务器若不遵守则容忍读超时，
            // 已读到的内容仍可用于解析。
            val buf = java.io.ByteArrayOutputStream()
            val input = s.getInputStream()
            val chunk = ByteArray(4096)
            try {
                while (true) {
                    val n = input.read(chunk)
                    if (n < 0) break
                    buf.write(chunk, 0, n)
                }
            } catch (_: java.net.SocketTimeoutException) {
            }
            val raw = buf.toByteArray()
            if (raw.isEmpty()) return Triple(null, "", "")

            val headEnd = indexOfHeaderEnd(raw) ?: return Triple(null, "", "")
            val headerText = String(raw, 0, headEnd.first, Charsets.ISO_8859_1)
            val lines = headerText.split("\r\n")
            val code = lines.firstOrNull()
                ?.split(' ')?.getOrNull(1)?.toIntOrNull()
                ?: return Triple(null, "", "")

            var location = ""
            var chunked = false
            var contentLength = -1
            for (i in 1 until lines.size) {
                val idx = lines[i].indexOf(':')
                if (idx <= 0) continue
                when (lines[i].substring(0, idx).trim().lowercase()) {
                    "location" -> location = lines[i].substring(idx + 1).trim()
                    "transfer-encoding" ->
                        chunked = lines[i].substring(idx + 1).contains("chunked", true)
                    "content-length" ->
                        contentLength = lines[i].substring(idx + 1).trim().toIntOrNull() ?: -1
                }
            }

            val bodyBytes = when {
                chunked -> dechunk(raw, headEnd.second)
                contentLength >= 0 ->
                    raw.copyOfRange(headEnd.second, minOf(raw.size, headEnd.second + contentLength))
                else -> raw.copyOfRange(headEnd.second, raw.size)
            }
            return Triple(code, String(bodyBytes, Charsets.UTF_8), location)
        } catch (e: Exception) {
            android.util.Log.d("CampusLogin", "httpGet fail ($url): $e")
            return Triple(null, "", "")
        } finally {
            try {
                socket?.close()
            } catch (_: Exception) {
            }
        }
    }

    /// HTTP 头与体的分界位置（\r\n\r\n）。返回 (头长度, 体起始下标)。
    private fun indexOfHeaderEnd(b: ByteArray): Pair<Int, Int>? {
        for (i in 0..b.size - 4) {
            if (b[i] == 13.toByte() && b[i + 1] == 10.toByte() &&
                b[i + 2] == 13.toByte() && b[i + 3] == 10.toByte()
            ) {
                return Pair(i, i + 4)
            }
        }
        return null
    }

    /// chunked 传输解码（门户可能对较长响应启用）。
    private fun dechunk(raw: ByteArray, bodyStart: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        var pos = bodyStart
        while (pos < raw.size) {
            var lineEnd = pos
            while (lineEnd + 1 < raw.size &&
                !(raw[lineEnd] == 13.toByte() && raw[lineEnd + 1] == 10.toByte())
            ) {
                lineEnd++
            }
            if (lineEnd + 1 >= raw.size) break
            val sizeText = String(raw, pos, lineEnd - pos, Charsets.ISO_8859_1)
                .substringBefore(';').trim()
            val size = sizeText.toIntOrNull(16) ?: break
            pos = lineEnd + 2
            if (size == 0) break
            val end = minOf(raw.size, pos + size)
            out.write(raw, pos, end - pos)
            pos = end + 2 // 跳过块尾 CRLF
        }
        return out.toByteArray()
    }
}
