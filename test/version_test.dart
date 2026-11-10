import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/main.dart';

void main() {
  test('the embedded release version is present', () {
    expect(appVersion, isNotEmpty);
  });

  test('Windows updates select the published installer', () {
    final selected = UpdateService.selectAsset(
      [
        {
          'name': 'Pennino-Windows.zip',
          'browser_download_url': 'https://example.invalid/portable',
        },
        {
          'name': 'Pennino-Windows-Setup.exe',
          'browser_download_url': 'https://example.invalid/installer',
        },
      ],
      windows: true,
    );

    expect(selected?['name'], 'Pennino-Windows-Setup.exe');
  });
}
