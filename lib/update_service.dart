import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_version.dart';

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String fileName;
  final String sha256;

  const UpdateInfo(
    this.version,
    this.downloadUrl,
    this.fileName,
    this.sha256,
  );
}

class UpdateService {
  static const _channel = MethodChannel('notes/update');
  static bool _checked = false;
  static final _sha256Pattern = RegExp(r'^[a-fA-F0-9]{64}$');
  static final ValueNotifier<UpdateInfo?> availableUpdate = ValueNotifier(null);

  static Map<String, dynamic>? selectAsset(
    List<Map<String, dynamic>> assets, {
    required bool windows,
  }) {
    final expectedName =
        windows ? 'Pennino-Windows-Setup.exe' : 'Pennino-Android.apk';
    for (final asset in assets) {
      if ((asset['name'] as String? ?? '').toLowerCase() ==
          expectedName.toLowerCase()) {
        return asset;
      }
    }
    return null;
  }

  static String _digestForAsset(Map<String, dynamic> asset) {
    final digest = asset['digest'];
    if (digest is! String || !digest.startsWith('sha256:')) {
      throw const FormatException(
        'The release asset does not include a SHA-256 digest',
      );
    }
    final value = digest.substring('sha256:'.length);
    if (!_sha256Pattern.hasMatch(value)) {
      throw const FormatException(
        'The release asset has an invalid SHA-256 digest',
      );
    }
    return value.toLowerCase();
  }

  static Uri _downloadUri(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        !uri.path.startsWith('/hyydra/pennino/releases/download/')) {
      throw const FormatException('The release asset URL is not trusted');
    }
    return uri;
  }

  static UpdateInfo parseAsset(
    String version,
    Map<String, dynamic> asset,
  ) {
    final downloadUrl = asset['browser_download_url'];
    final fileName = asset['name'];
    if (downloadUrl is! String || fileName is! String) {
      throw const FormatException('The release asset metadata is incomplete');
    }
    _downloadUri(downloadUrl);
    return UpdateInfo(
      version,
      downloadUrl,
      fileName,
      _digestForAsset(asset),
    );
  }

  static List<int> _parts(String value) => value
      .replaceFirst(RegExp(r'^[vV]'), '')
      .split('.')
      .map((part) => int.tryParse(RegExp(r'^\d+').stringMatch(part) ?? '') ?? 0)
      .toList();

  static bool _isNewer(String candidate, String current) {
    final a = _parts(candidate);
    final b = _parts(current);
    for (var i = 0; i < math.max(a.length, b.length); i++) {
      final left = i < a.length ? a[i] : 0;
      final right = i < b.length ? b[i] : 0;
      if (left != right) return left > right;
    }
    return false;
  }

  static Future<UpdateInfo?> check() async {
    if (!Platform.isAndroid && !Platform.isWindows) return null;
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(
          'https://api.github.com/repos/hyydra/pennino/releases/latest'));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'Pennino/$appVersion');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Release check failed (${response.statusCode})',
          uri: request.uri,
        );
      }
      final release = jsonDecode(await response.transform(utf8.decoder).join())
          as Map<String, dynamic>;
      final version =
          (release['tag_name'] as String? ?? '').replaceFirst('v', '');
      if (!_isNewer(version, appVersion)) return null;
      final assets =
          (release['assets'] as List? ?? const []).cast<Map<String, dynamic>>();
      final selected = selectAsset(assets, windows: Platform.isWindows);
      if (selected == null) {
        throw const FormatException(
          'The latest release is missing the installer for this platform',
        );
      }
      return parseAsset(version, selected);
    } finally {
      client.close();
    }
  }

  static Future<void> verifyDownload(File file, String expectedSha256) async {
    if (!_sha256Pattern.hasMatch(expectedSha256)) {
      throw const FormatException('Invalid expected SHA-256 digest');
    }
    final actual = await sha256.bind(file.openRead()).first;
    if (actual.toString() != expectedSha256.toLowerCase()) {
      throw const FormatException(
        'The downloaded update failed SHA-256 verification',
      );
    }
  }

  static Future<Directory> createDownloadDirectory(
    Directory temporaryDirectory,
  ) =>
      temporaryDirectory.createTemp('pennino-update-');

  static Future<void> prompt(
    BuildContext context, {
    bool automatic = false,
  }) async {
    if (automatic && _checked) return;
    _checked = true;
    UpdateInfo? update;
    try {
      update = await check();
    } catch (error) {
      if (!automatic && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update check failed: $error')),
        );
      }
      return;
    }
    if (!context.mounted) return;
    final availableUpdate = update;
    UpdateService.availableUpdate.value = availableUpdate;
    if (availableUpdate == null) {
      if (!automatic) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pennino is up to date.')),
        );
      }
      return;
    }
    if (automatic) return;
    final install = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pennino update available'),
        content: Text(
          'Version ${availableUpdate.version} is available. Download and install it now?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Update'),
          ),
        ],
      ),
    );
    if (install != true || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Downloading update…')),
    );
    final client = HttpClient();
    try {
      final request =
          await client.getUrl(Uri.parse(availableUpdate.downloadUrl));
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Download failed (${response.statusCode})');
      }
      final directory = await getTemporaryDirectory();
      // A previous Windows installer can keep its executable locked after the
      // app exits. Give every attempt its own directory so that lock cannot
      // prevent a later download from being installed.
      final downloadDirectory = await createDownloadDirectory(directory);
      final partialFile = File(
        '${downloadDirectory.path}${Platform.pathSeparator}${availableUpdate.fileName}.download',
      );
      final file = File(
        '${downloadDirectory.path}${Platform.pathSeparator}${availableUpdate.fileName}',
      );
      await response.pipe(partialFile.openWrite());
      await verifyDownload(partialFile, availableUpdate.sha256);
      await partialFile.rename(file.path);
      if (Platform.isAndroid) {
        await _channel.invokeMethod('install', {'path': file.path});
      } else {
        await Process.start(
          file.path,
          const [],
          mode: ProcessStartMode.detached,
        );
        exit(0);
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update failed: $error')),
        );
      }
    } finally {
      client.close();
    }
  }
}
