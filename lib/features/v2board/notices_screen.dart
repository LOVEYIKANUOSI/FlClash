import 'package:fl_clash/features/v2board/auth_store.dart';
import 'package:fl_clash/features/v2board/client.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

/// 公告页：展示面板下发的公告（支持 HTML 文本里的链接和图片）。
class V2BoardNoticesView extends StatefulWidget {
  const V2BoardNoticesView({super.key});

  @override
  State<V2BoardNoticesView> createState() => _V2BoardNoticesViewState();
}

class _V2BoardNoticesViewState extends State<V2BoardNoticesView> {
  final AuthStore _authStore = AuthStore();
  List<Map<String, dynamic>> _notices = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _authStore.init();
      final baseUrl = _authStore.panelUrl;
      final authData = _authStore.authData;
      if (authData == null) {
        if (mounted) {
          setState(() {
            _error = '登录信息已失效，请重新登录';
            _loading = false;
          });
        }
        return;
      }
      final notices = await v2BoardClient.fetchNotices(baseUrl, authData);
      if (mounted) {
        setState(() {
          _notices = notices;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      title: '公告',
      body: _loading
          ? const Center(child: ActivityIndicator())
          : _error != null
          ? _ErrorView(message: _error!, onRetry: _loadData)
          : _notices.isEmpty
          ? const Center(child: Text('暂无公告'))
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              itemCount: _notices.length,
              itemBuilder: (_, index) => _NoticeCard(notice: _notices[index]),
            ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const GlyphIcon(AppGlyphs.info, size: 48),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTextStyle.subheadline.of(
                context,
              ).copyWith(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

class _NoticeCard extends StatefulWidget {
  final Map<String, dynamic> notice;

  const _NoticeCard({required this.notice});

  @override
  State<_NoticeCard> createState() => _NoticeCardState();
}

class _NoticeCardState extends State<_NoticeCard> {
  bool _expanded = false;

  String _formatTime(dynamic timestamp) {
    final seconds = timestamp is int
        ? timestamp
        : int.tryParse('$timestamp') ?? 0;
    if (seconds <= 0) {
      return '';
    }
    final dateTime = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    final month = dateTime.month.toString().padLeft(2, '0');
    final day = dateTime.day.toString().padLeft(2, '0');
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '${dateTime.year}-$month-$day $hour:$minute';
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return;
    }
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Widget _buildContent(
    String rawContent,
    Color textColor,
    Color linkColor,
  ) {
    final segments = _parseHtmlSegments(rawContent);
    if (segments.isEmpty) {
      return const SizedBox.shrink();
    }
    final spans = <TextSpan>[];
    for (final segment in segments) {
      if (segment.isLink) {
        spans.add(
          TextSpan(
            text: segment.text,
            style: TextStyle(
              color: linkColor,
              decoration: TextDecoration.underline,
            ),
            recognizer: TapGestureRecognizer()
              ..onTap = () => _openUrl(segment.url!),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: segment.text,
            style: TextStyle(color: textColor, height: 1.6),
          ),
        );
      }
    }
    return RichText(
      text: TextSpan(
        style: TextStyle(fontSize: 14, color: textColor, height: 1.6),
        children: spans,
      ),
      maxLines: _expanded ? null : 4,
      overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final notice = widget.notice;
    final title = notice['title']?.toString() ?? '';
    final rawContent = notice['content']?.toString() ?? '';
    final imageUrl = notice['img_url']?.toString() ?? '';
    final createdAt = notice['created_at'];
    final tags = notice['tags'];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const GlyphIcon(AppGlyphs.info, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.headline.of(context, emphasized: true),
                ),
              ),
            ],
          ),
          if (createdAt != null) ...[
            const SizedBox(height: 6),
            Text(
              _formatTime(createdAt),
              style: TextStyle(fontSize: 12, color: colorScheme.outline),
            ),
          ],
          if (tags is List && tags.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final tag in tags)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '$tag',
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (imageUrl.isNotEmpty) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                imageUrl,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  height: 120,
                  alignment: Alignment.center,
                  color: colorScheme.surfaceContainerHighest,
                  child: const GlyphIcon(AppGlyphs.info),
                ),
              ),
            ),
          ],
          if (rawContent.isNotEmpty) ...[
            const SizedBox(height: 10),
            _buildContent(
              rawContent,
              colorScheme.onSurfaceVariant,
              colorScheme.primary,
            ),
            if (rawContent.length > 150)
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _expanded ? '收起' : '展开',
                    style: TextStyle(
                      fontSize: 13,
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Segment {
  final String text;
  final String? url;

  const _Segment.text(this.text) : url = null;
  const _Segment.link(this.text, this.url);

  bool get isLink => url != null && url!.isNotEmpty;
}

List<_Segment> _parseHtmlSegments(String html) {
  final segments = <_Segment>[];
  final linkRegexp = RegExp(
    r'<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*?)"|' "'" r'([^' "'" r']*?)' "'" r'|([^\s>]+))[^>]*>(.*?)</a>',
    caseSensitive: false,
    dotAll: true,
  );

  var lastEnd = 0;
  for (final match in linkRegexp.allMatches(html)) {
    if (match.start > lastEnd) {
      final before = _stripTags(html.substring(lastEnd, match.start));
      if (before.isNotEmpty) {
        segments.add(_Segment.text(before));
      }
    }
    final url = (match.group(1) ?? match.group(2) ?? match.group(3) ?? '')
        .trim();
    final linkText = _stripTags(match.group(4) ?? '');
    if (url.isNotEmpty) {
      segments.add(
        _Segment.link(linkText.isEmpty ? url : linkText, url),
      );
    }
    lastEnd = match.end;
  }
  if (lastEnd < html.length) {
    final after = _stripTags(html.substring(lastEnd));
    if (after.isNotEmpty) {
      segments.add(_Segment.text(after));
    }
  }
  if (segments.isEmpty) {
    final clean = _stripTags(html);
    if (clean.isNotEmpty) {
      segments.addAll(_extractPlainUrls(clean));
    }
  }
  return segments;
}

String _stripTags(String html) => html.replaceAll(RegExp(r'<[^>]*>'), '').trim();

List<_Segment> _extractPlainUrls(String text) {
  final segments = <_Segment>[];
  final urlRegexp = RegExp(r'(https?://[^\s<>"{}|\\^`\[\]]+)');
  var lastEnd = 0;
  for (final match in urlRegexp.allMatches(text)) {
    if (match.start > lastEnd) {
      segments.add(_Segment.text(text.substring(lastEnd, match.start)));
    }
    segments.add(_Segment.link(match.group(0)!, match.group(0)!));
    lastEnd = match.end;
  }
  if (lastEnd < text.length) {
    segments.add(_Segment.text(text.substring(lastEnd)));
  }
  return segments;
}

