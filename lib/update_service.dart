import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
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

/// Why an update download stopped before a runnable installer was on disk: a
/// server that went quiet, a download the user cancelled, or a refusal.
class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'UpdateDownloadException: $message${cause == null ? '' : ' ($cause)'}';
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

  static Future<UpdateInfo?> check({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!Platform.isAndroid && !Platform.isWindows) return null;
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(Uri.parse(
          'https://api.github.com/repos/hyydra/pennino/releases/latest'));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'Pennino/$appVersion');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Release check failed (${response.statusCode})',
          uri: request.uri,
        );
      }
      final release = jsonDecode(
        await response
            .transform(utf8.decoder)
            .join()
            .timeout(timeout),
      ) as Map<String, dynamic>;
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

  /// Downloads and verifies the installer for [update], and returns the file
  /// to run.
  ///
  /// [uri] is passed separately from [UpdateInfo.downloadUrl] so a test can
  /// serve a body it controls; production gives [_downloadUri], the only
  /// address the app is willing to fetch.
  ///
  /// Every way this stops - a server that goes quiet after answering, a
  /// download the user cancelled, a refusal, a digest that does not match -
  /// leaves nothing behind. The attempt lives in its own temporary directory
  /// and that directory is removed unless a verified installer is standing in
  /// it, so a stalled or cancelled download cannot pile half-installer files
  /// in the temp folder on the way to the next attempt.
  static Future<File> downloadInstaller({
    required UpdateInfo update,
    required Uri uri,
    required Directory directory,
    void Function(int receivedBytes, int totalBytes)? onProgress,
    Future<void>? cancel,
    Duration connectTimeout = const Duration(seconds: 20),
    Duration idleTimeout = const Duration(seconds: 30),
  }) async {
    final attemptDirectory = await createDownloadDirectory(directory);
    final target = File(
      '${attemptDirectory.path}${Platform.pathSeparator}${update.fileName}',
    );
    final partialFile = File('${target.path}.download');
    final client = HttpClient()..connectionTimeout = connectTimeout;
    final done = Completer<void>();
    IOSink? sink;
    StreamSubscription<List<int>>? subscription;
    Timer? idleTimer;
    var settled = false;
    var published = false;
    var received = 0;

    void settleError(Object error, StackTrace stack) {
      if (settled) return;
      settled = true;
      idleTimer?.cancel();
      if (!done.isCompleted) done.completeError(error, stack);
    }

    void armIdleTimer() {
      idleTimer?.cancel();
      idleTimer = Timer(idleTimeout, () => settleError(
            UpdateDownloadException(
              'The update download stopped receiving data',
              idleTimeout,
            ),
            StackTrace.current,
          ));
    }

    try {
      final request = await client.getUrl(uri).timeout(connectTimeout);
      final response = await request.close().timeout(connectTimeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw UpdateDownloadException(
          'The release server answered ${response.statusCode}',
        );
      }
      final total = response.contentLength;
      sink = partialFile.openWrite();
      if (cancel != null) {
        unawaited(cancel.then((_) => settleError(
              const UpdateDownloadException('The update download was cancelled'),
              StackTrace.current,
            )));
      }
      armIdleTimer();
      subscription = response.listen(
        (chunk) {
          if (settled) return;
          received += chunk.length;
          sink!.add(chunk);
          onProgress?.call(received, total < 0 ? received : total);
          armIdleTimer();
        },
        onError: settleError,
        onDone: () async {
          idleTimer?.cancel();
          try {
            await sink!.flush();
            await sink!.close();
          } catch (error, stack) {
            settleError(error, stack);
            return;
          }
          sink = null;
          if (!settled && !done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      await done.future;
      await verifyDownload(partialFile, update.sha256);
      await partialFile.rename(target.path);
      published = true;
      return target;
    } finally {
      idleTimer?.cancel();
      await subscription?.cancel();
      // An open sink holds the file on Windows, and the directory below it
      // cannot be removed while it does.
      try {
        await sink?.close();
      } catch (_) {
        // Already on its way out; the cleanup below is what matters.
      }
      client.close(force: true);
      if (!published) {
        try {
          await attemptDirectory.delete(recursive: true);
        } catch (_) {
          // A refusal or a locked file must not replace one update failure
          // with another; the download result is already decided.
        }
      }
    }
  }

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
    final installNow = await showDialog<bool>(
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
    if (installNow != true || !context.mounted) return;
    await install(context, availableUpdate);
  }

  /// Downloads [update] behind a dialog that says how far it has got and can
  /// be stopped, then hands the verified installer to the platform.
  ///
  /// The caller passes the [UpdateInfo] it is already showing: re-running
  /// [check] here would spend another round trip on a release the screen has
  /// already named, and could well come back with nothing.
  static Future<void> install(
    BuildContext context,
    UpdateInfo update, {
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final progress = ValueNotifier<_UpdateDownloadState>(
      const _UpdateDownloadState(),
    );
    final cancelled = Completer<void>();
    var dialogOpen = true;
    unawaited(showDialog<void>(
      context: navigator.context,
      barrierDismissible: false,
      builder: (_) => _UpdateDownloadDialog(
        version: update.version,
        progress: progress,
        onCancel: () {
          if (cancelled.isCompleted) return;
          cancelled.complete();
          dialogOpen = false;
          navigator.pop();
        },
      ),
    ));
    File? installer;
    Object? failure;
    try {
      installer = await downloadInstaller(
        update: update,
        uri: _downloadUri(update.downloadUrl),
        directory: await getTemporaryDirectory(),
        cancel: cancelled.future,
        onProgress: (receivedBytes, totalBytes) {
          progress.value =
              _UpdateDownloadState(received: receivedBytes, total: totalBytes);
          onProgress?.call(receivedBytes, totalBytes);
        },
      );
    } catch (error) {
      failure = error;
    }
    if (dialogOpen) {
      dialogOpen = false;
      navigator.pop();
    }
    progress.dispose();
    if (failure != null) {
      messenger.showSnackBar(
        SnackBar(content: Text('Update failed: $failure')),
      );
      return;
    }
    final file = installer;
    if (file == null) return;
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod('install', {'path': file.path});
      } else {
        // A previous Windows installer can keep its executable locked after
        // the app exits, so every attempt downloads into its own directory and
        // the app leaves the way clear before the installer runs.
        await Process.start(
          file.path,
          const [],
          mode: ProcessStartMode.detached,
        );
        exit(0);
      }
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Update failed: $error')),
      );
    }
  }
}

class _UpdateDownloadState {
  const _UpdateDownloadState({this.received = 0, this.total = 0});

  final int received;
  final int total;

  double? get fraction => total > 0 ? received / total : null;

  String get label => total > 0
      ? '${_formatBytes(received)} of ${_formatBytes(total)}'
      : '${_formatBytes(received)} downloaded';
}

String _formatBytes(int value) {
  if (value < 1024) return '$value B';
  final units = ['KB', 'MB', 'GB'];
  double size = value / 1024;
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return '${size.toStringAsFixed(size >= 10 ? 0 : 1)} ${units[unit]}';
}

class _UpdateDownloadDialog extends StatefulWidget {
  const _UpdateDownloadDialog({
    required this.version,
    required this.progress,
    required this.onCancel,
  });

  final String version;
  final ValueListenable<_UpdateDownloadState> progress;
  final VoidCallback onCancel;

  @override
  State<_UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<_UpdateDownloadDialog> {
  bool _cancelling = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Downloading Pennino ${widget.version}'),
        content: ValueListenableBuilder<_UpdateDownloadState>(
          valueListenable: widget.progress,
          builder: (context, state, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(value: state.fraction),
              const SizedBox(height: 12),
              Text(_cancelling ? 'Stopping the download…' : state.label),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _cancelling
                ? null
                : () {
                    setState(() => _cancelling = true);
                    widget.onCancel();
                  },
            child: const Text('Cancel'),
          ),
        ],
      );
}
