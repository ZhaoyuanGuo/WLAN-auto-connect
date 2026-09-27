package cn.lnpc.wlan_auto_connect

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/// 控制中心磁贴「长按」偏好页：SystemUI 收到长按时优先启动声明了
/// QS_TILE_PREFERENCES 的 Activity；这里路由进应用主页，
/// 避免退回系统的应用信息页。NoDisplay 主题避免闪屏。
class TilePreferencesActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val intent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        startActivity(intent)
        finish()
    }
}
