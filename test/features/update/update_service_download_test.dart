import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/update/update_manifest.dart';
import 'package:fl_clash/features/update/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 注意：这里刻意不调用 TestWidgetsFlutterBinding.ensureInitialized()，
  // 否则 flutter_test 会把所有 dart:io HttpClient 请求改写成 400。
  late HttpServer server;
  late String baseUrl;
  late Uint8List payload;
  late String sha256Hex;

  setUp(() async {
    payload = Uint8List.fromList(
      List<int>.generate(200 * 1024, (index) => index % 251),
    );
    sha256Hex = sha256.convert(payload).toString();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final start = int.parse(
          RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!,
        );
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.contentLength = payload.length - start;
        request.response.add(payload.sublist(start));
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentLength = payload.length;
        request.response.add(payload);
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  UpdateManifest manifest({
    String? sha,
    UpdateSource source = UpdateSource.github,
  }) {
    return UpdateManifest(
      source: source,
      versionName: '0.9.4',
      versionCode: 2026111901,
      minVersionCode: 0,
      fileName: 'Dawn-0.9.4-setup.exe',
      fileSize: payload.length,
      sha256: sha ?? sha256Hex,
      signature: '',
      downloadUrl: '$baseUrl/Dawn-0.9.4-setup.exe',
      releaseNotes: '',
      mandatory: false,
    );
  }

  Future<Directory> tempDir() async {
    final dir = await Directory.systemTemp.createTemp('dawn_update_test');
    addTearDown(() => dir.delete(recursive: true));
    return dir;
  }

  test('downloads a fresh file and verifies sha256', () async {
    final dir = await tempDir();
    final service = UpdateService.instance;
    await service.download(manifest(), directory: dir.path);
    expect(service.state.phase, UpdatePhase.ready);
    final file = File('${dir.path}${Platform.pathSeparator}Dawn-0.9.4-setup.exe');
    expect(await file.length(), payload.length);
    expect(await fileSha256(file.path), sha256Hex);
  });

  test('resumes a partial file with Range and verifies sha256', () async {
    final dir = await tempDir();
    final file = File('${dir.path}${Platform.pathSeparator}Dawn-0.9.4-setup.exe');
    final half = payload.length ~/ 2;
    await file.writeAsBytes(payload.sublist(0, half));
    final service = UpdateService.instance;
    await service.download(manifest(), directory: dir.path);
    expect(service.state.phase, UpdatePhase.ready);
    expect(await file.length(), payload.length);
    expect(await fileSha256(file.path), sha256Hex);
  });

  test('rejects a bad sha256 and deletes the file', () async {
    final dir = await tempDir();
    final service = UpdateService.instance;
    await service.download(
      manifest(sha: 'deadbeef' * 8),
      directory: dir.path,
    );
    expect(service.state.phase, UpdatePhase.failed);
    expect(service.state.error, contains('sha256'));
    final file = File(
      '${dir.path}${Platform.pathSeparator}Dawn-0.9.4-setup.exe',
    );
    expect(await file.exists(), isFalse);
  });

  test('rejects a panel manifest without signature (S-36)', () async {
    final dir = await tempDir();
    final service = UpdateService.instance;
    await service.download(
      manifest(source: UpdateSource.panel),
      directory: dir.path,
    );
    expect(service.state.phase, UpdatePhase.failed);
    expect(service.state.error, contains('签名'));
    final file = File(
      '${dir.path}${Platform.pathSeparator}Dawn-0.9.4-setup.exe',
    );
    expect(await file.exists(), isFalse);
  });
}
