package cn.lnpc.wlan_auto_connect

import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/// 控制中心（快捷设置）「校园网一键连接」磁贴：
/// - 状态由 HomeWidgetPreferences 驱动（在线=ACTIVE，副标题=最新状态文案）
/// - 点击后与桌面小组件走同一条后台认证链路（LoginWorker）
/// - 添加入口：Android 13+ 调用 requestAddTileService 弹系统确认窗（见
///   WlanMethods.requestAddTile）；低版本由应用引导手动添加。
class CampusTileService : TileService() {

    override fun onStartListening() {
        // 用户下拉控制中心时触发，同步最新状态
        android.util.Log.d(TAG, "onStartListening")
        updateTile()
    }

    override fun onClick() {
        android.util.Log.d(TAG, "onClick")
        // 乐观反馈：磁贴立即变蓝，真实结果由 LoginWorker 回写后刷新
        optimistic = true
        val tile = qsTile
        if (tile != null) {
            tile.label = "校园网"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) tile.subtitle = "正在连接..."
            tile.state = Tile.STATE_ACTIVE
            tile.updateTile()
        }
        val appContext = applicationContext
        val request = androidx.work.OneTimeWorkRequestBuilder<LoginWorker>().build()
        androidx.work.WorkManager.getInstance(appContext).enqueueUniqueWork(
            "cn_login", androidx.work.ExistingWorkPolicy.REPLACE, request
        )
    }

    private fun updateTile() {
        val tile = qsTile ?: return
        if (optimistic) {
            // 等待 LoginWorker 真实结果期间保持乐观状态，避免 requestListeningState
            // 回调读到旧 prefs 把颜色打回灰色
            tile.label = "校园网"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) tile.subtitle = "正在连接..."
            tile.state = Tile.STATE_ACTIVE
            tile.updateTile()
            return
        }
        var text = "待命"
        var online = false
        try {
            val prefs = getSharedPreferences(CampusLogin.PREFS, Context.MODE_PRIVATE)
            val raw = prefs.getString(CampusLogin.STATUS_KEY, null)
            if (raw != null) {
                val obj = org.json.JSONObject(raw)
                text = obj.optString("text", "待命").ifEmpty { "待命" }
                online = obj.optBoolean("online", false)
            }
        } catch (_: Exception) {
        }
        tile.label = "校园网"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = text
        }
        tile.state = if (online) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        android.util.Log.d(TAG, "updateTile: text=$text online=$online")
        tile.updateTile()
    }

    companion object {
        private const val TAG = "CampusTile"

        /// 点击后的乐观状态，直到下一次 setStatus（真实结果）落地
        @Volatile
        private var optimistic = false

        fun clearOptimistic() {
            optimistic = false
        }

        /// 状态变化后请求系统回调 onStartListening 以刷新磁贴
        /// （磁贴仅在控制中心展开时可见，未展开时静默失败无妨）。
        fun pushUpdate(context: Context) {
            try {
                requestListeningState(
                    context, ComponentName(context, CampusTileService::class.java)
                )
            } catch (_: Exception) {
            }
        }
    }
}
