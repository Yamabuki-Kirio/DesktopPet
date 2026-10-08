import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:petlife/core/constants.dart';
import 'package:petlife/database/app_database.dart';
import 'package:petlife/database/dao/account_session_dao.dart';
import 'package:petlife/platform/device_info_provider.dart';
import 'package:petlife/sync/api_client.dart';
import 'package:petlife/sync/authenticated_api.dart';
import 'package:petlife/sync/credential_store.dart';
import 'package:petlife/sync/device_identity.dart';
import 'package:petlife/sync/sync_preferences.dart';

import 'support/sqlite_test_bootstrap.dart';

/// Phase 4A：设备信息与设备身份。
///
/// 需求「Phase 4A 第 10 项」要求上报：
/// platform=android / architecture=arm64-v8a / device_name / model_name /
/// os_version / app_version。
///
/// 需求「第 4 条」要求 Windows 与 Android **必须注册成不同设备** ——
/// 这一条由 `platform` 字段保证（服务端 `(user_id, device_local_id)` 唯一）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SqliteTestBootstrap.ensureLoaded();

  late Directory tmp;
  late AppDatabase db;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('petlife_device_env');
  });

  tearDownAll(() {
    DeviceIdentity.resetEnvironmentForTest();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  setUp(() async {
    await AppDatabase.close();
    db = await AppDatabase.open(
      path: p.join(tmp.path, 'device_${DateTime.now().microsecondsSinceEpoch}.db'),
    );
  });

  tearDown(() async {
    DeviceIdentity.resetEnvironmentForTest();
    await AppDatabase.close();
  });

  test('测试宿主（Windows）默认识别为 windows/x64', () {
    DeviceIdentity.resetEnvironmentForTest();
    final DeviceEnvironment env = DeviceIdentity.environment;
    expect(env.platform, 'windows');
    expect(env.architecture, 'x64');
    expect(DeviceIdentity.platform(), 'windows');
    expect(DeviceIdentity.architecture(), 'x64');
    expect(DeviceIdentity.modelName(), isNull, reason: 'Windows 不上报机型');
    expect(DeviceIdentity.appVersion(), AppConstants.appVersion);
  });

  test('配置为 Android 环境后，设备身份随之切换为 android/arm64-v8a', () {
    DeviceIdentity.configureEnvironment(const DeviceEnvironment(
      platform: 'android',
      architecture: 'arm64-v8a',
      deviceName: 'Pixel 7',
      modelName: 'Pixel 7',
      osVersion: 'Android 14 (API 34)',
    ));

    expect(DeviceIdentity.platform(), 'android');
    expect(DeviceIdentity.architecture(), 'arm64-v8a');
    expect(DeviceIdentity.defaultDeviceName(), 'Pixel 7');
    expect(DeviceIdentity.modelName(), 'Pixel 7');
    expect(DeviceIdentity.osVersion(), 'Android 14 (API 34)');
  });

  test('Android 设备注册信息带机型，且与 Windows 不是同一台设备', () async {
    // 同一个 device_local_id（同一台机器上的同一个安装），
    // 平台不同即代表"另一台设备"。
    final AuthenticatedApi api = AuthenticatedApi(
      credentialStore: InMemoryCredentialStore(),
      accountSessionDao: AccountSessionDao(db.raw),
      deviceIdentity: DeviceIdentity(db),
      preferences: SyncPreferences(db),
    );

    DeviceIdentity.configureEnvironment(const DeviceEnvironment(
      platform: 'windows',
      architecture: 'x64',
      deviceName: 'DESKTOP-TEST',
      osVersion: 'Windows 11 (10.0.22631)',
    ));
    final DeviceRegistration windows = await api.buildDeviceRegistration();
    expect(windows.platform, 'windows');
    expect(windows.architecture, 'x64');
    expect(windows.modelName, isNull);

    DeviceIdentity.configureEnvironment(const DeviceEnvironment(
      platform: 'android',
      architecture: 'arm64-v8a',
      deviceName: 'Pixel 7',
      modelName: 'Pixel 7',
      osVersion: 'Android 14 (API 34)',
    ));
    final DeviceRegistration android = await api.buildDeviceRegistration();
    expect(android.platform, 'android');
    expect(android.architecture, 'arm64-v8a');
    expect(android.modelName, 'Pixel 7', reason: 'Android 上报机型');
    expect(android.osVersion, 'Android 14 (API 34)');
    expect(android.appVersion, AppConstants.appVersion);

    // device_local_id 稳定（同一安装不因平台切换而变），平台字段保证"不同设备"
    expect(android.deviceLocalId, windows.deviceLocalId);
    expect(android.platform, isNot(windows.platform));

    api.dispose();
  });

  test('服务端架构白名单包含 Android ABI（否则注册设备会 422）', () {
    final File schema = File(p.join(
      Directory.current.path,
      'server',
      'app',
      'schemas',
      'device.py',
    ));
    expect(schema.existsSync(), isTrue, reason: '服务端 schema 应当存在');
    final String src = schema.readAsStringSync();

    for (final String abi in <String>['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
      expect(src, contains(abi), reason: '服务端 ARCHITECTURE_CHOICES 缺少 $abi');
    }
    expect(src, contains('"android"'), reason: '服务端平台白名单缺少 android');
  });
}
