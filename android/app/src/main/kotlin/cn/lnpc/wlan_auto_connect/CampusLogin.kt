package cn.lnpc.wlan_auto_connect

import android.content.Context
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.URL
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
                    password = p.optString("password", ""),
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
        CampusWidgetProvider.pushUpdate(context)
    }

    /// 执行一次完整的静默认证流程，返回最终文案。
    fun run(context: Context): String {
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
        val (code, body, _) = httpGet(url, 8000, followRedirects = false)
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
        val (code, body, _) = httpGet(url, 5000, followRedirects = false)
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
            "http://www.msftconnecttest.com/connecttest.txt", 6000, followRedirects = false
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

    /// GET 请求（可禁止自动重定向），返回 (statusCode, body, location)，
    /// 失败时 statusCode 为 null。响应按 UTF-8 解码。
    private fun httpGet(
        url: String,
        timeoutMs: Int,
        followRedirects: Boolean,
    ): Triple<Int?, String, String> {
        var conn: HttpURLConnection? = null
        return try {
            val c = URL(url).openConnection() as HttpURLConnection
            conn = c
            c.connectTimeout = timeoutMs
            c.readTimeout = timeoutMs
            c.instanceFollowRedirects = followRedirects
            c.setRequestProperty("User-Agent", "Mozilla/5.0")
            val code = c.responseCode
            val stream = try {
                c.inputStream
            } catch (e: IOException) {
                c.errorStream
            }
            val bytes = stream?.use { it.readBytes() } ?: ByteArray(0)
            Triple(code, String(bytes, Charsets.UTF_8),
                c.getHeaderField("Location") ?: "")
        } catch (e: Exception) {
            Triple(null, "", "")
        } finally {
            conn?.disconnect()
        }
    }
}
