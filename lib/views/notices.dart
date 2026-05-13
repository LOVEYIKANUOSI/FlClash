import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:fl_clash/features/v2board/auth_store.dart';
import 'package:fl_clash/features/v2board/client.dart';
import 'package:url_launcher/url_launcher.dart';

class NoticesView extends StatefulWidget {
  const NoticesView({super.key});

  @override
  State<NoticesView> createState() => _NoticesViewState();
}

class _NoticesViewState extends State<NoticesView> {
  List<Map<String, dynamic>> _notices = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final authStore = AuthStore();
      await authStore.init();
      final baseUrl = authStore.panelUrl;
      final authData = authStore.authData;

      if (baseUrl == null || authData == null) {
        setState(() {
          _error = '请先登录';
          _loading = false;
        });
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
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('公告'), centerTitle: true),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.campaign_outlined, size: 56, color: cs.outline),
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: cs.outline)),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: _loadData,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : _notices.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.campaign_outlined,
                              size: 56, color: cs.outline),
                          const SizedBox(height: 12),
                          Text('暂无公告',
                              style: TextStyle(color: cs.outline)),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _loadData,
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        itemCount: _notices.length,
                        itemBuilder: (_, i) =>
                            _NoticeCard(notice: _notices[i]),
                      ),
                    ),
    );
  }
}

// 解析 HTML 中的 <a> 标签和纯文本，返回带链接的 TextSpan 列表
List<_Segment> _parseHtmlSegments(String html) {
  final segments = <_Segment>[];
  // 匹配 <a ... href="..." ...>text</a>，支持双引号、单引号、无引号
  final linkRegexp = RegExp(
    r'<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*?)"|' "'" r'([^' "'" r']*?)' "'" r'|([^\s>]+))[^>]*>(.*?)</a>',
    caseSensitive: false,
    dotAll: true,
  );
  int lastEnd = 0;

  for (final match in linkRegexp.allMatches(html)) {
    // 链接前的纯文本
    if (match.start > lastEnd) {
      final before = html.substring(lastEnd, match.start);
      final clean = _stripTags(before);
      if (clean.isNotEmpty) {
        segments.add(_Segment.text(clean));
      }
    }
    // href 在双引号组(1)、单引号组(2)、无引号组(3)
    final url = (match.group(1) ?? match.group(2) ?? match.group(3) ?? '').trim();
    final rawLinkText = match.group(4) ?? '';
    final linkText = _stripTags(rawLinkText).isNotEmpty
        ? _stripTags(rawLinkText)
        : url;
    if (url.isNotEmpty) {
      segments.add(_Segment.link(linkText, url));
    }
    lastEnd = match.end;
  }

  // 链接后的剩余文本
  if (lastEnd < html.length) {
    final after = html.substring(lastEnd);
    final clean = _stripTags(after);
    if (clean.isNotEmpty) {
      segments.add(_Segment.text(clean));
    }
  }

  // 如果没有任何 <a> 匹配，清理整个 HTML 并尝试识别纯 URL
  if (segments.isEmpty) {
    final clean = _stripTags(html);
    if (clean.isNotEmpty) {
      segments.addAll(_extractPlainUrls(clean));
    }
  }

  return segments;
}

String _stripTags(String html) {
  return html.replaceAll(RegExp(r'<[^>]*>'), '').trim();
}

// 从纯文本中提取 http/https 链接
List<_Segment> _extractPlainUrls(String text) {
  final segments = <_Segment>[];
  final urlRegexp = RegExp(r'(https?://[^\s<>"{}|\\^`\[\]]+)');
  int lastEnd = 0;
  for (final match in urlRegexp.allMatches(text)) {
    if (match.start > lastEnd) {
      final before = text.substring(lastEnd, match.start);
      if (before.isNotEmpty) segments.add(_Segment.text(before));
    }
    segments.add(_Segment.link(match.group(0)!, match.group(0)!));
    lastEnd = match.end;
  }
  if (lastEnd < text.length) {
    final after = text.substring(lastEnd);
    if (after.isNotEmpty) segments.add(_Segment.text(after));
  }
  if (segments.isEmpty && text.isNotEmpty) {
    segments.add(_Segment.text(text));
  }
  return segments;
}

class _Segment {
  final String text;
  final String? url; // 非 null 表示是链接
  const _Segment.text(this.text) : url = null;
  const _Segment.link(this.text, this.url);
  bool get isLink => url != null && url!.isNotEmpty;
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
    if (timestamp == null) return '';
    final n = (timestamp is int) ? timestamp : int.tryParse('$timestamp') ?? 0;
    if (n <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(n * 1000);
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  void _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null && await canLaunchUrl(uri)) {
      launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Widget _buildContent(String rawContent, Color textColor, Color linkColor) {
    final segments = _parseHtmlSegments(rawContent);
    if (segments.isEmpty) return const SizedBox.shrink();

    final spans = <TextSpan>[];
    for (final seg in segments) {
      if (seg.isLink) {
        spans.add(TextSpan(
          text: seg.text,
          style: TextStyle(color: linkColor, decoration: TextDecoration.underline),
          recognizer: TapGestureRecognizer()..onTap = () => _openUrl(seg.url!),
        ));
      } else {
        spans.add(TextSpan(
          text: seg.text,
          style: TextStyle(color: textColor, height: 1.6),
        ));
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
    final cs = Theme.of(context).colorScheme;
    final notice = widget.notice;
    final title = notice['title']?.toString() ?? '';
    final rawContent = notice['content']?.toString() ?? '';
    final imgUrl = notice['img_url']?.toString();
    final createdAt = notice['created_at'];
    final tags = notice['tags'];

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行
            Row(
              children: [
                Icon(Icons.campaign, size: 20, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            // 时间
            if (createdAt != null) ...[
              const SizedBox(height: 6),
              Text(
                _formatTime(createdAt),
                style: TextStyle(fontSize: 12, color: cs.outline),
              ),
            ],
            // 标签
            if (tags is List && tags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: tags
                    .map((t) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: cs.primaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '$t',
                            style: TextStyle(
                                fontSize: 11, color: cs.onPrimaryContainer),
                          ),
                        ))
                    .toList()
                    .cast<Widget>(),
              ),
            ],
            // 图片
            if (imgUrl != null && imgUrl.isNotEmpty) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  imgUrl,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    height: 120,
                    alignment: Alignment.center,
                    color: cs.surfaceContainerHighest,
                    child: Icon(Icons.broken_image, color: cs.outline),
                  ),
                ),
              ),
            ],
            // 内容（支持可点击链接）
            if (rawContent.isNotEmpty) ...[
              const SizedBox(height: 10),
              _buildContent(rawContent, cs.onSurfaceVariant, cs.primary),
              // 检查内容长度决定是否显示展开按钮
              if (rawContent.length > 150)
                GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _expanded ? '收起 ▲' : '展开 ▼',
                      style: TextStyle(
                          fontSize: 13,
                          color: cs.primary,
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
