import 'package:flutter/material.dart';
import 'package:fl_clash/features/v2board/auth_store.dart';
import 'package:fl_clash/features/v2board/client.dart';

class TicketsView extends StatefulWidget {
  const TicketsView({super.key});

  @override
  State<TicketsView> createState() => _TicketsViewState();
}

class _TicketsViewState extends State<TicketsView> {
  List<Map<String, dynamic>> _tickets = [];
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
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _openCreateDialog() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => const _CreateTicketDialog(),
    );
    if (created == true) _loadData();
  }

  void _openDetail(Map<String, dynamic> ticket) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _TicketDetailPage(ticket: ticket),
      ),
    );
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('工单'), centerTitle: true),
      floatingActionButton: FloatingActionButton(
        onPressed: _openCreateDialog,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.support_agent, size: 56, color: cs.outline),
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
              : _tickets.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.support_agent,
                              size: 56, color: cs.outline),
                          const SizedBox(height: 12),
                          Text('暂无工单', style: TextStyle(color: cs.outline)),
                          const SizedBox(height: 16),
                          OutlinedButton.icon(
                            onPressed: _openCreateDialog,
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('创建工单'),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _loadData,
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
                        itemCount: _tickets.length,
                        itemBuilder: (_, i) =>
                            _TicketCard(
                              ticket: _tickets[i],
                              onTap: () => _openDetail(_tickets[i]),
                            ),
                      ),
                    ),
    );
  }
}

// ========== 工单卡片 ==========
class _TicketCard extends StatelessWidget {
  final Map<String, dynamic> ticket;
  final VoidCallback onTap;
  const _TicketCard({required this.ticket, required this.onTap});

  String _formatTime(dynamic timestamp) {
    if (timestamp == null) return '';
    final n = (timestamp is int) ? timestamp : int.tryParse('$timestamp') ?? 0;
    if (n <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(n * 1000);
    return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final subject = ticket['subject']?.toString() ?? '';
    final status = ticket['status'] ?? 0;
    final replyStatus = ticket['reply_status'] ?? 0;
    final createdAt = ticket['created_at'];

    final isOpen = status == 0;
    final awaitingReply = isOpen && replyStatus == 0;
    final replied = isOpen && replyStatus == 1;

    final Color badgeColor;
    final String badgeText;
    if (!isOpen) {
      badgeColor = cs.outline;
      badgeText = '已关闭';
    } else if (awaitingReply) {
      badgeColor = cs.tertiary;
      badgeText = '待回复';
    } else {
      badgeColor = cs.primary;
      badgeText = '已回复';
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: isOpen ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      subject,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: isOpen ? cs.onSurface : cs.outline,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatTime(createdAt),
                      style: TextStyle(fontSize: 12, color: cs.outline),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: badgeColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(
                      fontSize: 12,
                      color: badgeColor,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ========== 创建工单对话框 ==========
class _CreateTicketDialog extends StatefulWidget {
  const _CreateTicketDialog();

  @override
  State<_CreateTicketDialog> createState() => _CreateTicketDialogState();
}

class _CreateTicketDialogState extends State<_CreateTicketDialog> {
  final _subjectCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();
  int _level = 0;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _subjectCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final subject = _subjectCtrl.text.trim();
    final message = _messageCtrl.text.trim();
    if (subject.isEmpty || message.isEmpty) {
      setState(() => _error = '请填写完整');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final authStore = AuthStore();
      await authStore.init();
      await v2BoardClient.createTicket(
        authStore.panelUrl!,
        authStore.authData!,
        subject: subject,
        level: _level,
        message: message,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _submitting = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.of(context).size.width;
    final dialogWidth = screenWidth < 500 ? screenWidth * 0.9 : 460.0;
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: dialogWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('创建工单',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      )),
              const SizedBox(height: 20),
              TextField(
                controller: _subjectCtrl,
                decoration: const InputDecoration(
                  labelText: '主题',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<int>(
                value: _level,
                decoration: const InputDecoration(
                  labelText: '优先级',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('低')),
                  DropdownMenuItem(value: 1, child: Text('中')),
                  DropdownMenuItem(value: 2, child: Text('高')),
                ],
                onChanged: (v) => setState(() => _level = v ?? 0),
              ),
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 140),
                child: TextField(
                  controller: _messageCtrl,
                  maxLines: 8,
                  minLines: 5,
                  decoration: const InputDecoration(
                    labelText: '内容',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: cs.error, fontSize: 13)),
            ],
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _submitting ? null : () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('提交'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ========== 工单详情页 ==========
class _TicketDetailPage extends StatefulWidget {
  final Map<String, dynamic> ticket;
  const _TicketDetailPage({required this.ticket});

  @override
  State<_TicketDetailPage> createState() => _TicketDetailPageState();
}

class _TicketDetailPageState extends State<_TicketDetailPage> {
  Map<String, dynamic>? _detail;
  bool _loading = true;
  final _replyCtrl = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _loadDetail();
  }

  @override
  void dispose() {
    _replyCtrl.dispose();
    super.dispose();
  }

  Future<AuthStore> _getAuth() async {
    final authStore = AuthStore();
    await authStore.init();
    return authStore;
  }

  Future<void> _loadDetail() async {
    try {
      final authStore = await _getAuth();
      final ticketId = widget.ticket['id'] as int;
      final detail = await v2BoardClient.fetchTicketDetail(
        authStore.panelUrl!,
        authStore.authData!,
        ticketId,
      );
      if (mounted) setState(() { _detail = detail; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; });
    }
  }

  Future<void> _reply() async {
    final msg = _replyCtrl.text.trim();
    if (msg.isEmpty) return;
    setState(() => _sending = true);
    try {
      final authStore = await _getAuth();
      await v2BoardClient.replyTicket(
        authStore.panelUrl!,
        authStore.authData!,
        id: widget.ticket['id'] as int,
        message: msg,
      );
      _replyCtrl.clear();
      await _loadDetail();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    if (mounted) setState(() => _sending = false);
  }

  Future<void> _close() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('关闭工单'),
        content: const Text('确定要关闭此工单吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final authStore = await _getAuth();
      await v2BoardClient.closeTicket(
        authStore.panelUrl!,
        authStore.authData!,
        widget.ticket['id'] as int,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  String _formatTime(dynamic timestamp) {
    if (timestamp == null) return '';
    final n = (timestamp is int) ? timestamp : int.tryParse('$timestamp') ?? 0;
    if (n <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(n * 1000);
    return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final subject = widget.ticket['subject']?.toString() ?? '';
    final status = _detail?['status'] ?? widget.ticket['status'] ?? 0;
    final isOpen = status == 0;
    final messages = (_detail?['message'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    return Scaffold(
      appBar: AppBar(
        title: Text(subject, overflow: TextOverflow.ellipsis),
        actions: [
          if (isOpen)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '关闭工单',
              onPressed: _close,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // 消息列表
                Expanded(
                  child: messages.isEmpty
                      ? Center(
                          child: Text('暂无消息',
                              style: TextStyle(color: cs.outline)))
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: messages.length,
                          itemBuilder: (_, i) =>
                              _MessageBubble(message: messages[i]),
                        ),
                ),
                // 回复输入框
                if (isOpen)
                  Container(
                    padding: EdgeInsets.fromLTRB(
                        16, 8, 16, MediaQuery.of(context).padding.bottom + 8),
                    decoration: BoxDecoration(
                      color: cs.surface,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.06),
                          blurRadius: 8,
                          offset: const Offset(0, -2),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _replyCtrl,
                            maxLines: 3,
                            minLines: 1,
                            decoration: InputDecoration(
                              hintText: '输入回复...',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(20),
                                borderSide: BorderSide.none,
                              ),
                              filled: true,
                              fillColor: cs.surfaceContainerHighest,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          onPressed: _sending ? null : _reply,
                          icon: _sending
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Icon(Icons.send),
                        ),
                      ],
                    ),
                  ),
                if (!isOpen)
                  Container(
                    padding: EdgeInsets.fromLTRB(
                        16, 12, 16, MediaQuery.of(context).padding.bottom + 12),
                    width: double.infinity,
                    color: cs.surfaceContainerHighest,
                    child: Text(
                      '此工单已关闭',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.outline, fontSize: 14),
                    ),
                  ),
              ],
            ),
    );
  }
}

// ========== 消息气泡 ==========
class _MessageBubble extends StatelessWidget {
  final Map<String, dynamic> message;
  const _MessageBubble({required this.message});

  String _formatTime(dynamic timestamp) {
    if (timestamp == null) return '';
    final n = (timestamp is int) ? timestamp : int.tryParse('$timestamp') ?? 0;
    if (n <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(n * 1000);
    return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isMe = message['is_me'] == true;
    final text = message['message']?.toString() ?? '';
    final createdAt = message['created_at'];

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: isMe ? cs.primaryContainer : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              text,
              style: TextStyle(
                fontSize: 14,
                color: isMe ? cs.onPrimaryContainer : cs.onSurface,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _formatTime(createdAt),
              style: TextStyle(
                fontSize: 11,
                color: (isMe ? cs.onPrimaryContainer : cs.onSurfaceVariant)
                    .withOpacity(0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
