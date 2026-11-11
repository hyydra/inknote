import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/main.dart';
import 'package:notes_app/update_service.dart';

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

  test('release installer metadata requires a GitHub SHA-256 digest', () {
    final update = UpdateService.parseAsset('0.4.7', {
      'name': 'Pennino-Windows-Setup.exe',
      'browser_download_url':
          'https://github.com/hyydra/pennino/releases/download/v0.4.7/Pennino-Windows-Setup.exe',
      'digest': 'sha256:${'a' * 64}',
    });

    expect(update.sha256, 'a' * 64);
    expect(
      () => UpdateService.parseAsset('0.4.7', {
        'name': 'Pennino-Windows-Setup.exe',
        'browser_download_url':
            'https://github.com/hyydra/pennino/releases/download/v0.4.7/Pennino-Windows-Setup.exe',
      }),
      throwsFormatException,
    );
  });

  test('download verification rejects changed bytes', () async {
    final directory = await Directory.systemTemp.createTemp('update-check-');
    addTearDown(() => directory.delete(recursive: true));
    const contents = 'verified update payload';
    final file = File('${directory.path}/update.bin');
    await file.writeAsString(contents);
    final digest = sha256.convert(utf8.encode(contents)).toString();

    await UpdateService.verifyDownload(file, digest);
    await expectLater(
      UpdateService.verifyDownload(file, '0' * 64),
      throwsFormatException,
    );
  });
}
