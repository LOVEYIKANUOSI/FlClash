import 'package:fl_clash/features/update/update_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> panelData({
    Object? versionCode = 2026111901,
    Object? minVersionCode = 0,
    bool mandatory = false,
  }) {
    return {
      'version_name': '0.9.4',
      'version_code': versionCode,
      'min_version_code': minVersionCode,
      'file_name': 'Dawn-0.9.4-setup.exe',
      'file_size': 31457280,
      'sha256':
          'a3f1c9d2e7b4a8f60c5d1e9b7a3f2c8d4e6b9a1f3c5d7e9b0a2c4e6f8b1d3a5c',
      'signature': 'abc',
      'download_url': 'https://dl.example.com/dawn/Dawn-0.9.4-setup.exe',
      'release_notes': '- 修复 A\n- 新增 B',
      'mandatory': mandatory,
    };
  }

  group('UpdateManifest.fromPanel', () {
    test('parses all fields', () {
      final manifest = UpdateManifest.fromPanel(panelData());
      expect(manifest.source, UpdateSource.panel);
      expect(manifest.versionName, '0.9.4');
      expect(manifest.versionCode, 2026111901);
      expect(manifest.fileSize, 31457280);
      expect(manifest.hasSignature, isTrue);
      expect(manifest.mandatory, isFalse);
    });

    test('tolerates string numbers', () {
      final manifest = UpdateManifest.fromPanel(
        panelData(versionCode: '2026111901'),
      );
      expect(manifest.versionCode, 2026111901);
    });
  });

  group('isNewerThan', () {
    test('prefers versionCode when both sides have one', () {
      final manifest = UpdateManifest.fromPanel(panelData());
      expect(
        manifest.isNewerThan(currentCode: 2026110401, currentVersion: '0.9.3'),
        isTrue,
      );
      expect(
        manifest.isNewerThan(currentCode: 2026111901, currentVersion: '0.9.4'),
        isFalse,
      );
    });

    test('falls back to version name without versionCode', () {
      final manifest = UpdateManifest.fromPanel(panelData(versionCode: 0));
      expect(
        manifest.isNewerThan(currentCode: 0, currentVersion: '0.9.3'),
        isTrue,
      );
      expect(
        manifest.isNewerThan(currentCode: 0, currentVersion: '0.9.5'),
        isFalse,
      );
    });
  });

  group('requiresForce', () {
    test('mandatory wins', () {
      final manifest = UpdateManifest.fromPanel(panelData(mandatory: true));
      expect(manifest.requiresForce(2026111901), isTrue);
    });

    test('below min_version_code forces', () {
      final manifest = UpdateManifest.fromPanel(
        panelData(minVersionCode: 2026111001),
      );
      expect(manifest.requiresForce(2026110401), isTrue);
      expect(manifest.requiresForce(2026111901), isFalse);
    });
  });

  test('signaturePayload matches the server format', () {
    final manifest = UpdateManifest.fromPanel(panelData());
    expect(
      manifest.signaturePayload,
      'dawn-update-v1\n'
      'windows-x64\n'
      '2026111901\n'
      '31457280\n'
      'a3f1c9d2e7b4a8f60c5d1e9b7a3f2c8d4e6b9a1f3c5d7e9b0a2c4e6f8b1d3a5c',
    );
  });

  group('UpdateManifest.fromGitHub', () {
    test('strips v prefix and drops signature/mandatory', () {
      final manifest = UpdateManifest.fromGitHub(
        {'tag_name': 'v0.9.4', 'body': 'notes'},
        downloadUrl: 'https://github.com/x/y/releases/download/v0.9.4/a.exe',
        fileName: 'a.exe',
        sha256: 'A3F1C9D2E7B4A8F60C5D1E9B7A3F2C8D4E6B9A1F3C5D7E9B0A2C4E6F8B1D3A5C',
        fileSize: 100,
      );
      expect(manifest.source, UpdateSource.github);
      expect(manifest.versionName, '0.9.4');
      expect(manifest.versionCode, 0);
      expect(manifest.hasSignature, isFalse);
      expect(manifest.mandatory, isFalse);
      // sha256 统一成小写
      expect(
        manifest.sha256,
        'a3f1c9d2e7b4a8f60c5d1e9b7a3f2c8d4e6b9a1f3c5d7e9b0a2c4e6f8b1d3a5c',
      );
    });
  });
}
