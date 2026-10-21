import 'dart:io';

import 'package:flutter/material.dart';

import 'mobile_app.dart';
import 'services/httpdns_overrides.dart';
import 'windows_app.dart';

/// 平台分发入口：
/// - Windows：沿用原有窗口初始化与 UI（bootstrapWindows，体验与旧版完全一致）；
/// - Android：edge-to-edge 导航条适配 + 手机/平板自适应 UI（bootstrapMobile）。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // HTTPDNS（DoH）拦截器：仅对白名单域名（auth.suspect.top / wlan-sync.suspect.top）
  // 按 IP 直连 + SNI，其他域名保持 LocalDNS 默认行为。关闭方式：
  //   flutter run --dart-define=HTTPDNS_ENABLE=false
  HttpOverrides.global = HttpDnsOverrides();
  if (Platform.isWindows) {
    await bootstrapWindows();
  } else {
    await bootstrapMobile();
  }
}
