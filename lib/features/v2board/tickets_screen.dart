import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/v2board/auth_store.dart';
import 'package:fl_clash/features/v2board/client.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';

/// 工单页：列表 + 新建 + 详情/回复/关闭。
class V2BoardTicketsView extends StatefulWidget {
  const V2BoardTicketsView({super.key});

  @override
  State<V2BoardTicketsView> createState() => _V2BoardTicketsViewState();
}

class _V2BoardTicketsViewState extends State<V2BoardTicketsView> {
  final AuthStore _authStore = AuthStore();
  List<Map<String, dynamic>> _tickets = const [];
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
      final baseUrl = _authStore.apiBaseUrl;
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
      final tickets = await v2BoardClient.fetchTickets(baseUrl, authData);
      if (mounted) {
        setState(() {
          _tickets = tickets;
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

  Future<void> _createTicket() async {
    final created = await dialogs.showCommonDialog<bool>(
      child: _CreateTicketForm(authStore: _authStore),
    );
    if (created == true) {
      await _loadData();
    }
  }

  ListItem _ticketItem(Map<String, dynamic> ticket) {
    final status = (ticket['status'] as num?)?.toInt() ?? 0;
    final replyStatus = (ticket['reply_status'] as num?)?.toInt() ?? 0;
    final createdAt = _formatTime(ticket['created_at']);
    final String badge;
    if (status != 0) {
      badge = '已关闭';
    } else if (replyStatus == 0) {
      badge = '待回复';
    } else {
      badge = '已回复';
    }
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.compose),
      title: Text(
        '${ticket['subject'] ?? ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(createdAt),
      trailing: Text(badge),
      widget: V2BoardTicketDetailView(ticket: ticket),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      title: '工单',
      isLoading: _loading && _tickets.isEmpty,
      body: _loading && _tickets.isEmpty
          ? const Center(child: ActivityIndicator())
          : _error != null
          ? _TicketsError(message: _error!, onRetry: _loadData)
          : ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 32),
              children: [
                generateSection(
                  title: '支持',
                  items: [
                    ListItem(
                      leading: const GlyphIcon(AppGlyphs.add),
                      title: const Text('新建工单'),
                      trailing: const GlyphIcon(AppGlyphs.chevronForward),
                      onTap: _createTicket,
                    ),
                  ],
                ),
                if (_tickets.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(child: Text('暂无工单')),
                  )
                else
                  generateSection(
                    title: '我的工单',
                    items: [for (final ticket in _tickets) _ticketItem(ticket)],
                  ),
              ],
            ),
    );
  }
}

class _TicketsError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _TicketsError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const GlyphIcon(AppGlyphs.compose, size: 48),
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

class _CreateTicketForm extends StatefulWidget {
  final AuthStore authStore;

  const _CreateTicketForm({required this.authStore});

  @override
  State<_CreateTicketForm> createState() => _CreateTicketFormState();
}

class _CreateTicketFormState extends State<_CreateTicketForm> {
  final TextEditingController _subjectController = TextEditingController();
  final TextEditingController _messageController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _subjectController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final subject = _subjectController.text.trim();
    final message = _messageController.text.trim();
    if (subject.isEmpty || message.isEmpty) {
      setState(() => _error = '请填写主题和内容');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.authStore.init();
      await v2BoardClient.createTicket(
        widget.authStore.apiBaseUrl,
        widget.authStore.authData!,
        subject: subject,
        level: 0,
        message: message,
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '新建工单',
              style: AppTextStyle.title3.of(context, emphasized: true),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _subjectController,
              decoration: const InputDecoration(hintText: '主题'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _messageController,
              maxLines: 6,
              minLines: 4,
              decoration: const InputDecoration(hintText: '详细描述你的问题'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: colorScheme.error, fontSize: 13),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: Text(_submitting ? '提交中…' : '提交'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 工单详情页（消息列表 + 回复 + 关闭）。
class V2BoardTicketDetailView extends StatefulWidget {
  final Map<String, dynamic> ticket;

  const V2BoardTicketDetailView({super.key, required this.ticket});

  @override
  State<V2BoardTicketDetailView> createState() =>
      _V2BoardTicketDetailViewState();
}

class _V2BoardTicketDetailViewState extends State<V2BoardTicketDetailView> {
  final AuthStore _authStore = AuthStore();
  final TextEditingController _replyController = TextEditingController();
  Map<String, dynamic>? _detail;
  bool _loading = true;
  bool _sending = false;

  int get _ticketId => (widget.ticket['id'] as num?)?.toInt() ?? 0;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  @override
  void dispose() {
    _replyController.dispose();
    super.dispose();
  }

  Future<void> _loadDetail() async {
    try {
      await _authStore.init();
      final authData = _authStore.authData;
      if (authData == null) {
        return;
      }
      final detail = await v2BoardClient.fetchTicketDetail(
        _authStore.apiBaseUrl,
        authData,
        _ticketId,
      );
      if (mounted) {
        setState(() {
          _detail = detail;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _reply() async {
    final message = _replyController.text.trim();
    if (message.isEmpty) {
      return;
    }
    setState(() => _sending = true);
    try {
      await _authStore.init();
      await v2BoardClient.replyTicket(
        _authStore.apiBaseUrl,
        _authStore.authData!,
        id: _ticketId,
        message: message,
      );
      _replyController.clear();
      await _loadDetail();
    } catch (e) {
      dialogs.showBanner('$e', level: BannerLevel.error);
    }
    if (mounted) {
      setState(() => _sending = false);
    }
  }

  Future<void> _close() async {
    final confirmed = await dialogs.showMessage(
      message: const TextSpan(text: '关闭后无法继续回复，确定关闭此工单？'),
      title: '关闭工单',
      confirmText: '确定关闭',
      cancelText: '取消',
    );
    if (confirmed != true) {
      return;
    }
    try {
      await _authStore.init();
      await v2BoardClient.closeTicket(
        _authStore.apiBaseUrl,
        _authStore.authData!,
        _ticketId,
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      dialogs.showBanner('$e', level: BannerLevel.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final status =
        (_detail?['status'] as num?)?.toInt() ??
        (widget.ticket['status'] as num?)?.toInt() ??
        0;
    final isOpen = status == 0;
    final messages =
        (_detail?['message'] as List?)?.whereType<Map>().map(
          (e) => Map<String, dynamic>.from(e),
        ).toList() ??
        const <Map<String, dynamic>>[];

    return Scaffold(
      title: '${widget.ticket['subject'] ?? '工单详情'}',
      isLoading: _loading,
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const Center(child: Text('暂无消息'))
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: messages.length,
                    itemBuilder: (_, index) =>
                        _MessageBubble(message: messages[index]),
                  ),
          ),
          if (isOpen)
            Container(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                8 + context.bottomInset,
              ),
              color: colorScheme.surfaceContainerLow,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _replyController,
                          maxLines: 3,
                          minLines: 1,
                          decoration: const InputDecoration(hintText: '输入回复…'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _sending ? null : _reply,
                        child: const Text('回复'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _close,
                      child: const Text('关闭工单'),
                    ),
                  ),
                ],
              ),
            )
          else
            Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + context.bottomInset),
              color: colorScheme.surfaceContainerLow,
              child: const Text('此工单已关闭', textAlign: TextAlign.center),
            ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final Map<String, dynamic> message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final isMe = message['is_me'] == true;
    final text = '${message['message'] ?? ''}';
    final createdAt = _formatTime(message['created_at']);
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: isMe
              ? colorScheme.primaryContainer
              : colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: isMe
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(text, style: const TextStyle(fontSize: 14, height: 1.5)),
            if (createdAt.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                createdAt,
                style: TextStyle(fontSize: 11, color: colorScheme.outline),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _formatTime(dynamic timestamp) {
  final seconds = timestamp is int ? timestamp : int.tryParse('$timestamp') ?? 0;
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
