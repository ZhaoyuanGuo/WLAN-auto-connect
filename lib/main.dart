import 'dart:io';

import 'package:flutter/material.dart';

import 'mobile_app.dart';
import 'windows_app.dart';

/// 平台分发入口：
/// - Windows：沿用原有窗口初始化与 UI（bootstrapWindows，体验与旧版完全一致）；
/// - Android：edge-to-edge 导航条适配 + 手机/平板自适应 UI（bootstrapMobile）。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    await bootstrapWindows();
  } else {
    await bootstrapMobile();
  }
}
