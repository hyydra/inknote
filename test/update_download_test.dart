import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notes_app/update_service.dart';

/// The installer the fake server publishes. The digest is the one a real
/// release would carry, so the verification step is exercised for real.
final payloadBytes = List<int>.generate(4096, (i) => i % 251);
String digestOf(List<int> bytes) => sha256.convert(bytes).toString();

UpdateInfo updateWith(String sha256) =>
    UpdateInfo('9.9.9', 'https://example.invalid/file', 'Pennino-Setup.bin', sha256);

/// Answers a download however the test needs: complete bytes, a response that
/// starts and never finishes, a slow trickle, or a refusal.
class FakeReleaseServer {
  Future<Uri> start(void Function(HttpRequest request) handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _subscription = server.listen(handler);
    return Uri.parse('http://${server.address.host}:${server.port}/file');
  }

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;

  Future<void> stop() async {
    await _subscription?.cancel();
    await _server?.close(force: true);
  }
}

void writeAll(HttpRequest request, List<int> bytes) {
  request.response
    ..contentLength = bytes.length
    ..add(bytes);
}

void main() {
  late Directory temporary;
  late FakeReleaseServer server;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('pennino-download-');
    server = FakeReleaseServer();
  });

  tearDown(() async {
    await server.stop();
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  List<String> remainingFileNames(Directory directory) => directory
      .listSync()
      .whereType<Directory>()
      .expand((child) => child.listSync())
      .whereType<File>()
      .map((file) => file.uri.pathSegments.last)
      .toList();

  test('the installer arrives complete and verified', () async {
    final uri = await server.start((request) {
      writeAll(request, payloadBytes);
      request.response.close();
    });
    final progress = <List<int>>[];

    final file = await UpdateService.downloadInstaller(
      update: updateWith(digestOf(payloadBytes)),
      uri: uri,
      directory: temporary,
      onProgress: (received, total) => progress.add([received, total]),
    );

    expect(await file.readAsBytes(), payloadBytes);
    expect(file.existsSync(), isTrue);
    expect(file.uri.pathSegments.last, 'Pennino-Setup.bin');
    // The half-written name is the download's working space, never a leftover.
    expect(remainingFileNames(temporary), ['Pennino-Setup.bin']);
    expect(progress, isNotEmpty);
    expect(progress.last.first, payloadBytes.length);
    expect(progress.last.last, payloadBytes.length);
    expect(
      progress.map((step) => step.first).reduce((a, b) => a > b ? a : b),
      payloadBytes.length,
    );
  });

  test('a download that stops sending data is abandoned, not awaited',
      () async {
    // The failure this guards is the silent one: the server accepts the
    // request, sends a little, and never finishes. Without a read timeout the
    // download waits forever behind a 'Downloading update…' message, and the
    // partial file stays on disk.
    final uri = await server.start((request) {
      request.response.add(payloadBytes.sublist(0, 8));
      request.response.flush();
    });

    await expectLater(
      UpdateService.downloadInstaller(
        update: updateWith(digestOf(payloadBytes)),
        uri: uri,
        directory: temporary,
        idleTimeout: const Duration(milliseconds: 120),
      ),
      throwsA(isA<UpdateDownloadException>()),
    );
    expect(remainingFileNames(temporary), isEmpty);
  });

  test('cancelling a download stops it and keeps no partial file', () async {
    final uri = await server.start((request) async {
      for (var i = 0; i < 500; i++) {
        request.response.add(payloadBytes.sublist(0, 16));
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      request.response.close();
    });
    final cancelled = Completer<void>();
    Future<void>.delayed(const Duration(milliseconds: 80), () => cancelled.complete());

    await expectLater(
      UpdateService.downloadInstaller(
        update: updateWith(digestOf(payloadBytes)),
        uri: uri,
        directory: temporary,
        cancel: cancelled.future,
      ),
      throwsA(
        isA<UpdateDownloadException>().having(
          (error) => error.message,
          'message',
          contains('cancel'),
        ),
      ),
    );
    expect(remainingFileNames(temporary), isEmpty);
  });

  test('a download that does not match its digest is discarded', () async {
    final uri = await server.start((request) {
      writeAll(request, payloadBytes);
      request.response.close();
    });

    await expectLater(
      UpdateService.downloadInstaller(
        update: updateWith('0' * 64),
        uri: uri,
        directory: temporary,
      ),
      throwsFormatException,
    );
    // An installer that cannot be verified must not be left where a later run,
    // or a user, could reach for it.
    expect(remainingFileNames(temporary), isEmpty);
  });

  test('a refused download says so', () async {
    final uri = await server.start((request) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.close();
    });

    await expectLater(
      UpdateService.downloadInstaller(
        update: updateWith(digestOf(payloadBytes)),
        uri: uri,
        directory: temporary,
      ),
      throwsA(isA<UpdateDownloadException>()),
    );
    expect(remainingFileNames(temporary), isEmpty);
  });
}
