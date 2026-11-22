import 'package:fl_clash/features/v2board/domain_probe_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DomainProbeResult.healthy（H-07）', () {
    DomainProbeResult result({
      required bool reachable,
      int statusCode = 0,
      String? error,
    }) {
      return DomainProbeResult(
        domain: 'api.example.com',
        reachable: reachable,
        latencyMs: 12,
        statusCode: statusCode,
        error: error,
      );
    }

    test('连通且非 5xx 视为健康', () {
      // 2xx/3xx/4xx 都说明「域名本身能用」，只是接口语义不同。
      expect(result(reachable: true, statusCode: 200).healthy, isTrue);
      expect(result(reachable: true, statusCode: 302).healthy, isTrue);
      expect(result(reachable: true, statusCode: 404).healthy, isTrue);
    });

    test('连得上但源站 5xx 视为不健康', () {
      // Cloudflare 502/504：域名能解析、TCP 能连，但面板源站挂了，
      // 不能拿它上报切换（否则切过去依然不可用）。
      expect(result(reachable: true, statusCode: 502).healthy, isFalse);
      expect(result(reachable: true, statusCode: 504).healthy, isFalse);
    });

    test('连不上视为不健康', () {
      expect(result(reachable: false).healthy, isFalse);
      expect(
        result(reachable: false, error: 'SocketException').healthy,
        isFalse,
      );
    });
  });
}
