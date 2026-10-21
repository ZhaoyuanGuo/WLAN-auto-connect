package cn.lnpc.wlan_auto_connect

import android.os.Bundle
import android.view.Window
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 金标联盟「统一导航条适配规范」(Edge-to-Edge)：
        // 内容绘制到状态栏/导航栏之下，系统栏背景透明，
        // 内容 insets 由 Flutter（Scaffold/SafeArea）避让。
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = android.graphics.Color.TRANSPARENT
        window.navigationBarColor = android.graphics.Color.TRANSPARENT
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "wlan_auto_connect/android")
            .setMethodCallHandler { call, result ->
                WlanMethods.handle(this, call, result)
            }
    }

    override fun onResume() {
        super.onResume()
        AppForeground.isForeground = true
    }

    override fun onPause() {
        AppForeground.isForeground = false
        super.onPause()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (!WlanMethods.handlePermissionResult(this, requestCode, grantResults)) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }
}
