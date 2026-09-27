package cn.lnpc.wlan_auto_connect

/// Shizuku UserService 实现：运行在 Shizuku 服务进程（shell uid 2000）中，
/// 以 shell 权限执行命令（例如 settings put 关闭系统联网检测）。
class ShellService : IShellService.Stub() {
    override fun exec(cmd: Array<String>): Int {
        return try {
            val p = Runtime.getRuntime().exec(cmd)
            p.waitFor()
        } catch (e: Exception) {
            -1
        }
    }
}
