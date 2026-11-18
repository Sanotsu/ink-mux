import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// Android 存储权限（U-32）：备份导出到用户自选目录（MANAGE_EXTERNAL_STORAGE
/// "所有文件访问"）——授权后 dart:io 可直写 /storage/emulated/0/ 任意路径。
/// 参考实现：Sanotsu/free-fitness（同款权限声明 + 运行时请求 + 选目录直写）。
///
/// · Android 11+：需用户在系统「所有文件访问」页授权（Permission.request
///   会跳转对应页面）；未授权时公共目录 dart:io 直写会被 scoped storage 拒绝
/// · Android ≤10：WRITE_EXTERNAL_STORAGE 运行时授权即可
/// · 桌面 / iOS：桌面无权限模型直接放行；iOS 沙盒策略不同（暂不支持导出到
///   自选目录，走私有目录 + 分享，由调用方处理）
Future<bool> requestStoragePermission() async {
  if (!Platform.isAndroid) return true;
  final manage = await Permission.manageExternalStorage.status;
  if (manage.isGranted) return true;
  final result = await Permission.manageExternalStorage.request();
  return result.isGranted;
}
