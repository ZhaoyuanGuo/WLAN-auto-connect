package cn.lnpc.wlan_auto_connect

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/// 桌面「一键连接」小组件：
/// 渲染 HomeWidgetPreferences 中的状态（由 CampusLogin.setStatus 写入），
/// 按钮点击后交给 CampusConnectReceiver 入队后台认证任务。
class CampusWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, render(context))
        }
    }

    companion object {
        const val ACTION_CONNECT = "cn.lnpc.wlan_auto_connect.ACTION_CONNECT"

        /// 按当前持久化状态渲染小组件界面。
        fun render(context: Context): RemoteViews {
            val prefs = context.getSharedPreferences(CampusLogin.PREFS, Context.MODE_PRIVATE)
            var text = "待命"
            var time = ""
            var online = false
            try {
                val raw = prefs.getString(CampusLogin.STATUS_KEY, null)
                if (raw != null) {
                    val obj = org.json.JSONObject(raw)
                    text = obj.optString("text", "待命").ifEmpty { "待命" }
                    time = obj.optString("time", "")
                    online = obj.optBoolean("online", false)
                }
            } catch (_: Exception) {
            }
            val views = RemoteViews(context.packageName, R.layout.campus_widget)
            views.setTextViewText(R.id.widget_status, text)
            views.setTextViewText(
                R.id.widget_time,
                if (time.isEmpty()) "点击按钮开始认证" else "$time 更新",
            )
            views.setInt(
                R.id.widget_status,
                "setTextColor",
                if (online) 0xFF2E7D32.toInt() else 0xFFEF6C00.toInt(),
            )
            views.setOnClickPendingIntent(R.id.widget_button, connectPendingIntent(context))
            return views
        }

        private fun connectPendingIntent(context: Context): PendingIntent {
            val intent = Intent(context, CampusConnectReceiver::class.java)
                .setAction(ACTION_CONNECT)
            return PendingIntent.getBroadcast(
                context, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        /// 立即刷新全部小组件实例。
        fun pushUpdate(context: Context) {
            try {
                val mgr = AppWidgetManager.getInstance(context)
                mgr.updateAppWidget(
                    ComponentName(context, CampusWidgetProvider::class.java),
                    render(context),
                )
            } catch (_: Exception) {
            }
        }
    }
}

/// 小组件按钮点击：先即时反馈「正在连接」，再入队后台认证任务。
class CampusConnectReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != CampusWidgetProvider.ACTION_CONNECT) return
        val appContext = context.applicationContext
        CampusLogin.setStatus(appContext, false, "正在连接...")
        val request = androidx.work.OneTimeWorkRequestBuilder<LoginWorker>().build()
        androidx.work.WorkManager.getInstance(appContext).enqueueUniqueWork(
            "cn_login", androidx.work.ExistingWorkPolicy.REPLACE, request
        )
    }
}

/// 开机自启：开启「开机自动认证」后，开机联网（WLAN 已配置的开放网络会自动重连）
/// 并延迟约 20 秒执行一次静默认证，对应 Windows 端的开机自启能力。
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }
        val appContext = context.applicationContext
        val cfg = CampusLogin.readConfig(appContext) ?: return
        if (!cfg.bootAutoLogin || cfg.profiles.isEmpty()) return
        val request = androidx.work.OneTimeWorkRequestBuilder<LoginWorker>()
            .setConstraints(
                androidx.work.Constraints.Builder()
                    .setRequiredNetworkType(androidx.work.NetworkType.CONNECTED)
                    .build()
            )
            .setInitialDelay(20, java.util.concurrent.TimeUnit.SECONDS)
            .build()
        androidx.work.WorkManager.getInstance(appContext).enqueueUniqueWork(
            "cn_login", androidx.work.ExistingWorkPolicy.KEEP, request
        )
    }
}

/// 后台认证任务：无 Flutter 引擎，直接执行原生协议实现并刷新小组件。
class LoginWorker(
    context: Context,
    params: androidx.work.WorkerParameters,
) : androidx.work.CoroutineWorker(context, params) {
    override suspend fun doWork(): androidx.work.ListenableWorker.Result {
        val r = try {
            CampusLogin.run(applicationContext)
        } catch (_: Exception) {
            "TASK_ERROR"
        }
        // 失败时弹 Toast 给可见反馈（成功由磁贴变色/小组件文案表达）
        val msg = when {
            r == "LOGIN_OK" || r == "ONLINE_ALREADY" -> null
            r.startsWith("LOGIN_FAIL:") -> "登录失败：${r.removePrefix("LOGIN_FAIL:")}"
            r == "NO_CONFIG" || r == "NO_PROFILE" -> "未配置账号，请先在 App 中保存账号密码"
            r == "PORTAL_UNREACHABLE" -> "未连接校园网：门户不可达（请确认已连校园网 WiFi）"
            r == "BAD_RESPONSE" -> "认证服务器响应异常"
            r == "UNCONFIRMED" -> "已提交认证但未确认上线，请稍后查看"
            else -> "校园网认证任务异常"
        }
        if (msg != null) {
            android.widget.Toast.makeText(applicationContext, msg, android.widget.Toast.LENGTH_LONG).show()
        }
        return androidx.work.ListenableWorker.Result.success()
    }
}
