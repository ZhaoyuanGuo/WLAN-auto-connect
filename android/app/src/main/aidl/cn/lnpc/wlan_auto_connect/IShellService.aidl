package cn.lnpc.wlan_auto_connect;

// Shizuku UserService 接口：在 Shizuku 服务进程（shell uid 2000）中执行命令。
// 注意：实现代码变更后需同步递增 WlanMethods 中 UserServiceArgs 的 version。
interface IShellService {
    int exec(in String[] cmd);
}
