import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

class DeviceInfoService {
  static final DeviceInfoService _instance = DeviceInfoService._internal();
  factory DeviceInfoService() => _instance;
  DeviceInfoService._internal();

  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  Future<Map<String, dynamic>> getDeviceInfo() async {
    final packageInfo = await PackageInfo.fromPlatform();

    if (Platform.isIOS) {
      final iosInfo = await _deviceInfo.iosInfo;
      return {
        'platform': 'iOS',
        'osVersion': iosInfo.systemVersion,
        'deviceModel': iosInfo.utsname.machine,
        'deviceName': iosInfo.name,
        'appVersion': packageInfo.version,
        'buildNumber': packageInfo.buildNumber,
      };
    } else if (Platform.isAndroid) {
      final androidInfo = await _deviceInfo.androidInfo;
      return {
        'platform': 'Android',
        'osVersion': androidInfo.version.release,
        'deviceModel': androidInfo.model,
        'deviceName': androidInfo.brand,
        'appVersion': packageInfo.version,
        'buildNumber': packageInfo.buildNumber,
      };
    }

    return {
      'platform': 'Unknown',
      'osVersion': 'Unknown',
      'deviceModel': 'Unknown',
      'deviceName': 'Unknown',
      'appVersion': packageInfo.version,
      'buildNumber': packageInfo.buildNumber,
    };
  }
}
