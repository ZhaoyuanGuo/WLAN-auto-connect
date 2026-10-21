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
            LoginWorker.WORK_NAME, androidx.work.ExistingWorkPolicy.REPLACE, request
        )
    }
}

/// 开机自启：开机后延迟约 20 秒执行一次静默认证。
///
/// 这里**不能**使用 `NetworkType.CONNECTED` 约束：WorkManager 在 API≥26 上把它
/// 实现为「已连接 **且** 已通过验证（NET_CAPABILITY_VALIDATED）」，而未认证的
/// 强制门户校园网恰恰不是 validated —— 该功能唯一有用的场景下约束永远不满足，
/// LoginWorker 会一直停在 ENQUEUED 不执行（界面上开关却显示已开启）。
/// 现改为不加网络约束，由 LoginWorker 自行判断是否已连上目标 WiFi，
/// 并以退避重试覆盖「开机 → WiFi 关联 → 取得 IP」这段时间。
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
            .setInputData(androidx.work.workDataOf(LoginWorker.KEY_FROM_BOOT to true))
            .setInitialDelay(20, java.util.concurrent.TimeUnit.SECONDS)
            .setBackoffCriteria(
                androidx.work.BackoffPolicy.EXPONENTIAL,
                30,
                java.util.concurrent.TimeUnit.SECONDS,
            )
            .build()
        // 与小组件/磁贴统一用 REPLACE，顺带清掉上次会话可能残留的卡住任务。
        androidx.work.WorkManager.getInstance(appContext).enqueueUniqueWork(
            LoginWorker.WORK_NAME, androidx.work.ExistingWorkPolicy.REPLACE, request
        )
    }
}

/// 后台认证任务：无 Flutter 引擎，直接执行原生协议实现并刷新小组件/磁贴。
class LoginWorker(
    context: Context,
    params: androidx.work.WorkerParameters,
) : androidx.work.CoroutineWorker(context, params) {

    companion object {
        const val WORK_NAME = "cn_login"
        const val KEY_FROM_BOOT = "fromBoot"

        /// 开机路径最大重试次数（30s 起指数退避，覆盖 WiFi 关联 + DHCP 耗时）
        private const val MAX_BOOT_ATTEMPTS = 8
    }

    override suspend fun doWork(): androidx.work.ListenableWorker.Result {
        val ctx = applicationContext

        if (inputData.getBoolean(KEY_FROM_BOOT, false) &&
            !CampusLogin.isOnConfiguredWifi(ctx)
        ) {
            // 开机后 WiFi 可能尚未关联/尚未取得 IP。此时既不认证也不写状态
            // （写「未连接校园网」会把小组件状态从正常覆盖成故障态），改为退避重试。
            if (runAttemptCount < MAX_BOOT_ATTEMPTS) {
                return androidx.work.ListenableWorker.Result.retry()
            }
            CampusLogin.setStatus(ctx, false, "未连接校园网")
            CampusNotify.failure(ctx, "开机自动认证未执行：未连接到已配置的校园网 WiFi")
            return androidx.work.ListenableWorker.Result.success()
        }

        val r = try {
            CampusLogin.run(ctx)
        } catch (e: Exception) {
            android.util.Log.w("CampusLogin", "worker 执行异常", e)
            // 必须写状态：磁贴的乐观态（"正在连接..."）只能由 setStatus 清除，
            // 否则会永久卡住。
            CampusLogin.setStatus(ctx, false, "认证异常")
            "TASK_ERROR"
        }

        // 失败时给出可见反馈。Android 11+ 后台应用弹 Toast 会被系统静默丢弃，
        // 故改用通知（见 CampusNotify）。
        val msg = when {
            r == "LOGIN_OK" || r == "ONLINE_ALREADY" -> null
            r.startsWith("LOGIN_FAIL:") -> "登录失败：${r.removePrefix("LOGIN_FAIL:")}"
            r == "NO_CONFIG" || r == "NO_PROFILE" -> "未配置账号，请先在 App 中保存账号密码"
            r == "PORTAL_UNREACHABLE" -> "未连接校园网：门户不可达（请确认已连校园网 WiFi）"
            r == "BAD_RESPONSE" -> "认证服务器响应异常"
            r == "UNCONFIRMED" -> "已提交认证但未确认上线，请稍后查看"
            else -> "校园网认证任务异常"
        }
        if (msg != null) CampusNotify.failure(ctx, msg)

        return androidx.work.ListenableWorker.Result.success()
    }
}
