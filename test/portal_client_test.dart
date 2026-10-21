import 'package:flutter_test/flutter_test.dart';
import 'package:wlan_auto_connect/services/portal_client.dart';

void main() {
  group('PortalClient.resolveSession 会话参数优先级', () {
    test('AC 劫持参数最优先', () {
      final s = PortalClient.resolveSession(
        hijack: {
          'wlanuserip': '10.0.0.5',
          'wlanusermac': 'aa:bb:cc:dd:ee:ff',
          'wlanacname': 'AC-1',
        },
        chkIp: '10.0.0.9',
        chkMac: '11:22:33:44:55:66',
        localIp: '192.168.1.2',
      );
      expect(s.ip, '10.0.0.5');
      expect(s.mac, 'aa:bb:cc:dd:ee:ff');
      expect(s.acName, 'AC-1');
    });

    test('无劫持时回退到 chkstatus 的 ss5/ss1', () {
      final s = PortalClient.resolveSession(
        hijack: const {},
        chkIp: '10.0.0.9',
        chkMac: '11:22:33:44:55:66',
        localIp: '192.168.1.2',
      );
      expect(s.ip, '10.0.0.9');
      expect(s.mac, '11:22:33:44:55:66');
    });

    test('劫持与 chkstatus 均无时回退到本机网卡 IP', () {
      final s = PortalClient.resolveSession(
        hijack: const {},
        localIp: '192.168.1.2',
      );
      expect(s.ip, '192.168.1.2');
      expect(s.mac, '');
      expect(s.acName, '');
    });

    test('劫持仅含部分字段时逐字段回退', () {
      final s = PortalClient.resolveSession(
        hijack: const {'wlanuserip': '10.0.0.5'},
        chkIp: '10.0.0.9',
        chkMac: '11:22:33:44:55:66',
        localIp: '192.168.1.2',
      );
      expect(s.ip, '10.0.0.5'); // 劫持优先
      expect(s.mac, '11:22:33:44:55:66'); // 劫持无 mac → 回退 chkstatus
    });

    test('全空时返回空串，不抛异常', () {
      final s = PortalClient.resolveSession(hijack: const {});
      expect(s.ip, '');
      expect(s.mac, '');
      expect(s.acName, '');
    });
  });

  group('PortalClient.buildLoginUri 登录 URL 拼装', () {
    test('裸账号 + 运营商后缀拼接，login_method=1', () {
      final uri = PortalClient.buildLoginUri(
        host: '172.16.200.11',
        eport: 801,
        account: '20210101',
        password: 'pw',
        suffix: '@dx',
        session: const LoginSession(ip: '10.0.0.5', mac: 'aa:bb', acName: 'AC-1'),
        v: 1234,
      );
      expect(uri.host, '172.16.200.11');
      expect(uri.port, 801);
      expect(uri.path, '/eportal/portal/login');
      expect(uri.queryParameters['login_method'], '1');
      expect(uri.queryParameters['user_account'], '20210101@dx');
      expect(uri.queryParameters['user_password'], 'pw');
      expect(uri.queryParameters['wlan_user_ip'], '10.0.0.5');
      expect(uri.queryParameters['wlan_user_mac'], 'aa:bb');
      expect(uri.queryParameters['wlan_ac_name'], 'AC-1');
      expect(uri.queryParameters['jsVersion'], '4.X');
      expect(uri.queryParameters['v'], '1234');
      expect(uri.queryParameters['callback'], 'dr1');
    });

    test('无后缀时 user_account 为纯账号', () {
      final uri = PortalClient.buildLoginUri(
        host: 'h',
        eport: 801,
        account: 'acc',
        password: 'p',
        suffix: '',
        session: const LoginSession(),
        v: 1,
      );
      expect(uri.queryParameters['user_account'], 'acc');
    });

    test('账号/密码中的特殊字符被正确编码', () {
      final uri = PortalClient.buildLoginUri(
        host: 'h',
        eport: 801,
        account: 'a+b',
        password: 'p&w=d',
        suffix: '',
        session: const LoginSession(),
        v: 1,
      );
      // Uri 解析后 queryParameters 应还原为原始值（证明编码正确）
      expect(uri.queryParameters['user_account'], 'a+b');
      expect(uri.queryParameters['user_password'], 'p&w=d');
      // 原始字符串中不应出现未编码的分隔符
      expect(uri.toString(), contains('user_password=p%26w%3Dd'));
    });

    test('空 IP/MAC/AC 仍生成合法 URL（参数保留为空）', () {
      final uri = PortalClient.buildLoginUri(
        host: 'h',
        eport: 801,
        account: 'a',
        password: 'p',
        suffix: '',
        session: const LoginSession(),
        v: 1,
      );
      expect(uri.queryParameters['wlan_user_ip'], '');
      expect(uri.queryParameters['wlan_user_mac'], '');
      expect(uri.queryParameters['wlan_ac_name'], '');
      expect(uri.toString(), contains('wlan_user_ipv6='));
    });
  });

  group('PortalClient.parseLoginResult 结果解析', () {
    test('result=1 视为成功', () {
      expect(PortalClient.parseLoginResult({'result': 1}), (true, 'LOGIN_OK'));
    });

    test('result=ok 视为成功', () {
      expect(PortalClient.parseLoginResult({'result': 'ok'}), (true, 'LOGIN_OK'));
    });

    test('ret_code=2 视为已在线（成功）', () {
      expect(PortalClient.parseLoginResult({'ret_code': 2}),
          (true, 'ALREADY_ONLINE'));
    });

    test('失败时返回门户 msg', () {
      expect(PortalClient.parseLoginResult({'result': 0, 'msg': '账号不存在'}),
          (false, '账号不存在'));
    });

    test('失败且无 msg 时返回 UNKNOWN_ERROR', () {
      expect(PortalClient.parseLoginResult({'result': 0}),
          (false, 'UNKNOWN_ERROR'));
      expect(PortalClient.parseLoginResult({'result': 0, 'msg': ''}),
          (false, 'UNKNOWN_ERROR'));
    });

    test('json 为 null 时返回 BAD_RESPONSE', () {
      expect(PortalClient.parseLoginResult(null), (false, 'BAD_RESPONSE'));
    });

    test('ret_code=8（Portal协议认证超时）视为失败并透传', () {
      expect(PortalClient.parseLoginResult({'ret_code': 8, 'msg': 'Portal协议认证超时'}),
          (false, 'Portal协议认证超时'));
    });
  });
}
