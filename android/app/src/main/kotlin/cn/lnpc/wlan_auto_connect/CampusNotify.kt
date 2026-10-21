package cn.lnpc.wlan_auto_connect

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/// 应用是否处于前台，由 MainActivity 的 onResume/onPause 维护。
/// 后台任务据此决定是否需要发通知：前台时用户已能从界面看到结果，不必重复打扰。
object AppForeground {
    @Volatile
    var isForeground: Boolean = false
}

/// 后台认证失败的可见反馈。
///
/// 不使用 Toast：Android 11 (API 30) 起系统禁止后台应用弹 Toast，
/// 原先 LoginWorker 里的 Toast 实际是静默丢失的，用户看不到任何失败原因。
/// 通知在 Android 13+ 需 POST_NOTIFICATIONS 运行时权限；未授权时静默跳过，
/// 不会比改动前更差（小组件/磁贴的文案仍会同步更新）。
object CampusNotify {
    private const val CHANNEL_ID = "campus_login"
    private const val CHANNEL_NAME = "校园网认证"
    private const val NOTIFICATION_ID = 1101

    fun failure(context: Context, message: String) {
        if (AppForeground.isForeground) return
        try {
            // Android 13+ 需要运行时通知权限，未授予直接放弃（避免 lint MissingPermission）
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(
                    context, Manifest.permission.POST_NOTIFICATIONS
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                return
            }
            val compat = NotificationManagerCompat.from(context)
            if (!compat.areNotificationsEnabled()) return

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                        as? NotificationManager ?: return
                if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                    nm.createNotificationChannel(
                        NotificationChannel(
                            CHANNEL_ID,
                            CHANNEL_NAME,
                            NotificationManager.IMPORTANCE_DEFAULT,
                        ).apply { description = "校园网自动认证失败时的提醒" }
                    )
                }
            }

            val contentIntent = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_tile_campus)
                .setContentTitle("校园网自动认证")
                .setContentText(message)
                .setStyle(NotificationCompat.BigTextStyle().bigText(message))
                .setContentIntent(contentIntent)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .build()

            compat.notify(NOTIFICATION_ID, notification)
        } catch (_: Exception) {
            // 通知失败不影响认证结果本身
        }
    }
}
