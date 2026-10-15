import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String runnerSource =
      File('windows/runner/main.cpp').readAsStringSync();
  final String platformSource = File(
    'lib/platform/windows/windows_platform_services.dart',
  ).readAsStringSync();

  test('single-instance gate runs before Flutter and SQLite can initialize', () {
    final int gate = runnerSource.indexOf('AcquireSingleInstanceMarker()');
    final int dartProject = runnerSource.indexOf('flutter::DartProject project');
    final int windowCreate = runnerSource.indexOf('window.Create(');

    expect(gate, greaterThanOrEqualTo(0));
    expect(gate, lessThan(dartProject));
    expect(gate, lessThan(windowCreate));
  });

  test('native marker is process-lived and does not take thread ownership', () {
    expect(runnerSource, contains('CreateMutexW(nullptr, FALSE'));
    expect(runnerSource, contains('ERROR_ALREADY_EXISTS'));
    expect(runnerSource, contains('ERROR_ACCESS_DENIED'));
    expect(runnerSource, contains('g_single_instance_mutex = handle'));
    expect(runnerSource, isNot(contains('WaitForSingleObject')));
  });

  test('Dart startup no longer uses the thread-owned mutex guard', () {
    expect(platformSource, isNot(contains('WindowsSingleInstanceGuard')));
    expect(platformSource, isNot(contains("import 'windows_single_instance.dart'")));
  });
}
