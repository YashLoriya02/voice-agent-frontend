import 'dart:async';

import 'package:flutter/material.dart';

import '../services/gmail_service.dart';
import '../services/maps_service.dart';
import '../services/message_notification_service.dart';
import '../theme/agent_theme.dart';

class SettingsReadRequest {
  const SettingsReadRequest(this.tool, this.arguments);
  final String tool;
  final Map<String, dynamic> arguments;
}

class AgentSettingsScreen extends StatefulWidget {
  const AgentSettingsScreen({
    super.key,
    required this.provider,
    required this.wakeEnabled,
    required this.isDefaultAssistant,
    required this.onProviderChanged,
    required this.onWakeChanged,
    required this.onMakeDefault,
    required this.onPreview,
    this.onRefreshDefault,
  });
  final String provider;
  final bool wakeEnabled, isDefaultAssistant;
  final Future<void> Function(String) onProviderChanged;
  final Future<void> Function(bool) onWakeChanged;
  final Future<bool> Function() onMakeDefault;
  final Future<void> Function() onPreview;
  final Future<bool> Function()? onRefreshDefault;
  @override
  State<AgentSettingsScreen> createState() => _AgentSettingsScreenState();
}

class _AgentSettingsScreenState extends State<AgentSettingsScreen>
    with WidgetsBindingObserver {
  final _sections = List.generate(4, (_) => GlobalKey());
  Map<String, dynamic> _messages = {}, _gmail = {}, _maps = {};
  late String _provider;
  late bool _wakeEnabled, _isDefault;
  bool _loading = true, _busy = false;
  String? _feedback;
  int _refreshGeneration = 0;

  @override
  void initState() {
    super.initState();
    _provider = widget.provider;
    _wakeEnabled = widget.wakeEnabled;
    _isDefault = widget.isDefaultAssistant;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<Map<String, dynamic>> _status(
    Future<Map<String, dynamic>> Function() load,
  ) async {
    try {
      return await load();
    } catch (_) {
      return {'unavailable': true};
    }
  }

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    final results = await Future.wait([
      _status(MessageNotificationService.status),
      _status(GmailService.status),
      _status(MapsService.status),
      _status(
        () async => {
          'selected': await widget.onRefreshDefault?.call() ?? _isDefault,
        },
      ),
    ]);
    if (!mounted || generation != _refreshGeneration) return;
    setState(() {
      _messages = results[0];
      _gmail = results[1];
      _maps = results[2];
      _isDefault = results[3]['selected'] == true;
      _loading = false;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => _feedback = 'This action is unavailable. Check Android access settings and try again.',
        );
      }
    } finally {
      if (mounted) {
        await _refresh();
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  void _read(String tool, Map<String, dynamic> arguments) =>
      Navigator.pop(context, SettingsReadRequest(tool, arguments));
  void _jump(int index) {
    final target = _sections[index].currentContext;
    if (target != null) {
      Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      backgroundColor: AgentTheme.background,
      body: AgentBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 20, 8),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back to agent',
                      onPressed: _busy ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'SETTINGS',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Refresh access status',
                      onPressed: _busy ? null : _refresh,
                      icon: const Icon(
                        Icons.refresh_rounded,
                        color: AgentTheme.muted,
                      ),
                    ),
                  ],
                ),
              ),
              if (_feedback != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AgentTheme.surface,
                    border: Border.all(color: AgentTheme.stroke),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _feedback!,
                    style: const TextStyle(
                      color: AgentTheme.cyan,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _hero(),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final item in [
                            (0, 'Voice'),
                            (1, 'Messages'),
                            (2, 'Gmail'),
                            (3, 'Maps'),
                          ])
                            ActionChip(
                              label: Text(item.$2),
                              onPressed: () => _jump(item.$1),
                              backgroundColor: AgentTheme.surface,
                              side: const BorderSide(color: AgentTheme.stroke),
                              labelStyle: const TextStyle(
                                color: AgentTheme.muted,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                      if (_loading || _busy) ...[
                        const SizedBox(height: 16),
                        const LinearProgressIndicator(
                          minHeight: 2,
                          color: AgentTheme.cyan,
                          backgroundColor: AgentTheme.stroke,
                        ),
                      ],
                      const SizedBox(height: 22),
                      _voiceCard(),
                      const SizedBox(height: 16),
                      _messagesCard(),
                      const SizedBox(height: 16),
                      _gmailCard(),
                      const SizedBox(height: 16),
                      _mapsCard(),
                      const SizedBox(height: 24),
                      const Row(
                        children: [
                          Icon(
                            Icons.lock_outline_rounded,
                            size: 15,
                            color: AgentTheme.muted,
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Mail and message readouts stay on your phone. Voice commands use your selected voice service.',
                              style: TextStyle(
                                color: AgentTheme.muted,
                                fontSize: 11,
                                height: 1.6,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  Widget _hero() => Row(
    children: [
      Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(17),
          gradient: const LinearGradient(
            colors: [AgentTheme.blue, AgentTheme.cyan],
          ),
          boxShadow: const [
            BoxShadow(color: Color(0x302F6BFF), blurRadius: 24),
          ],
        ),
        child: const Icon(Icons.hub_rounded, size: 27, color: Colors.white),
      ),
      const SizedBox(width: 14),
      const Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Make it yours.',
              style: TextStyle(
                fontSize: 27,
                fontWeight: FontWeight.w800,
                letterSpacing: -.6,
              ),
            ),
            SizedBox(height: 5),
            Text(
              'Your voice. Your connections. Your control.',
              style: TextStyle(
                color: AgentTheme.muted,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    ],
  );
  Widget _card({
    required int section,
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Widget> children,
  }) => Container(
    key: _sections[section],
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: AgentTheme.surface.withValues(alpha: .86),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: AgentTheme.stroke),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0xFF102849),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, color: AgentTheme.cyan, size: 19),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AgentTheme.muted,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        ...children,
      ],
    ),
  );
  Widget _voiceCard() => _card(
    section: 0,
    icon: Icons.graphic_eq_rounded,
    title: 'Voice & activation',
    subtitle: 'Choose how your agent listens and responds.',
    children: [
      Row(
        children: [
          Expanded(
            child: _providerOption(
              'customGroq',
              'Custom',
              'Groq + Deepgram',
              Icons.tune_rounded,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _providerOption(
              'deepgramVoiceAgent',
              'Deepgram',
              'Voice Agent',
              Icons.blur_on_rounded,
            ),
          ),
        ],
      ),
      const SizedBox(height: 20),
      Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hey Agent',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 4),
                Text(
                  'Hands-free wake phrase',
                  style: TextStyle(color: AgentTheme.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: _wakeEnabled,
            activeThumbColor: AgentTheme.green,
            onChanged: _busy
                ? null
                : (value) => _run(() async {
                    await widget.onWakeChanged(value);
                    if (mounted) setState(() => _wakeEnabled = value);
                  }),
          ),
        ],
      ),
      const Divider(color: AgentTheme.stroke, height: 28),
      _statusLine(
        _isDefault ? 'Default assistant' : 'Default assistant not selected',
        _isDefault,
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (!_isDefault)
            _action(
              'Make default',
              Icons.assistant_rounded,
              () => _run(() async {
                final selected = await widget.onMakeDefault();
                if (mounted) setState(() => _isDefault = selected);
              }),
            ),
          _action(
            'Preview assistant',
            Icons.auto_awesome_rounded,
            () => _run(widget.onPreview),
          ),
        ],
      ),
    ],
  );
  Widget _providerOption(
    String value,
    String title,
    String subtitle,
    IconData icon,
  ) {
    final selected = _provider == value;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _busy
              ? null
              : () => _run(() async {
                  await widget.onProviderChanged(value);
                  if (mounted) setState(() => _provider = value);
                }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? AgentTheme.blue : AgentTheme.stroke,
              ),
              gradient: selected
                  ? const LinearGradient(
                      colors: [Color(0xFF17489B), Color(0xFF0A74C6)],
                    )
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: selected ? Colors.white : AgentTheme.muted,
                ),
                const SizedBox(height: 10),
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: selected
                        ? const Color(0xFFBDDCFF)
                        : AgentTheme.muted,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _messagesCard() => _card(
    section: 1,
    icon: Icons.mark_chat_unread_outlined,
    title: 'Messages',
    subtitle: 'WhatsApp, SMS and RCS notification previews.',
    children: [
      _statusLine(
        _messages['unavailable'] == true
            ? 'Access status unavailable'
            : _messages['enabled'] != true
            ? 'Notification access is off'
            : _messages['connected'] == true
            ? 'Notification access is ready'
            : 'Listener is connecting',
        _messages['connected'] == true,
      ),
      const SizedBox(height: 12),
      const Text(
        'Read new previews or replay saved messages. Reading aloud leaves the original app’s read status unchanged.',
        style: TextStyle(color: AgentTheme.muted, fontSize: 12, height: 1.6),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _action(
            'Manage access',
            Icons.notifications_outlined,
            () => _run(MessageNotificationService.openSettings),
          ),
          _action(
            'Read all saved',
            Icons.volume_up_outlined,
            () => _read('read_messages', {
              'channel': 'all',
              'unread_only': false,
              'read_all': true,
            }),
          ),
        ],
      ),
    ],
  );
  Widget _gmailCard() => _card(
    section: 2,
    icon: Icons.mail_outline_rounded,
    title: 'Gmail',
    subtitle: 'Your inbox, read with an offline phone voice.',
    children: [
      _statusLine(
        _gmail['unavailable'] == true
            ? 'Account status unavailable'
            : _gmail['connected'] == true
            ? (_gmail['email']?.toString() ?? 'Gmail connected')
            : 'No account connected',
        _gmail['connected'] == true,
      ),
      const SizedBox(height: 12),
      const Text(
        'Sender, subject and preview. Read-only access: emails are never marked read or changed.',
        style: TextStyle(color: AgentTheme.muted, fontSize: 12, height: 1.6),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _action(
            'Connect Gmail',
            Icons.link_rounded,
            () => _run(() async {
              final result = await GmailService.connect();
              if (mounted) {
                setState(
                  () => _feedback = result['success'] == true
                      ? 'Gmail is connected.'
                      : result['message']?.toString() ??
                            'Gmail could not connect.',
                );
              }
            }),
          ),
          if (_gmail['connected'] == true)
            _action(
              'Disconnect',
              Icons.link_off_rounded,
              () => _run(() async {
                final result = await GmailService.disconnect();
                if (mounted) {
                  setState(() => _feedback = result['message']?.toString());
                }
              }),
            ),
          _action(
            'Read unread mail',
            Icons.volume_up_outlined,
            () => _read('read_gmail', {}),
          ),
        ],
      ),
    ],
  );
  Widget _mapsCard() => _card(
    section: 3,
    icon: Icons.route_rounded,
    title: 'Maps',
    subtitle: 'Driving directions from your current location.',
    children: [
      _statusLine(
        _maps['unavailable'] == true
            ? 'Maps status unavailable'
            : _maps['installed'] == false
            ? 'Google Maps is not installed'
            : _maps['connected'] == true
            ? 'Maps reader is ready'
            : 'Enable reader for spoken estimates',
        _maps['connected'] == true,
      ),
      const SizedBox(height: 12),
      const Text(
        'Navigate with installed Google Maps. The optional reader speaks the distance and time shown on its screen.',
        style: TextStyle(color: AgentTheme.muted, fontSize: 12, height: 1.6),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _action(
            _maps['connected'] == true
                ? 'Manage Maps reader'
                : 'Enable Maps reader',
            Icons.accessibility_new_rounded,
            () => _run(MapsService.openReaderSettings),
          ),
          _action(
            'Read current route',
            Icons.volume_up_outlined,
            () => _read('get_driving_route', {'read_current': true}),
            enabled: _maps['installed'] != false,
          ),
        ],
      ),
      const SizedBox(height: 14),
      const Text(
        'The reader checks only Maps during your request. If Android blocks access, open App info, then Allow restricted settings.',
        style: TextStyle(color: AgentTheme.muted, fontSize: 11, height: 1.6),
      ),
    ],
  );
  Widget _statusLine(String label, bool ready) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: ready ? AgentTheme.green : AgentTheme.muted,
            shape: BoxShape.circle,
          ),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          label,
          style: TextStyle(
            color: ready ? AgentTheme.green : AgentTheme.muted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            height: 1.4,
          ),
        ),
      ),
    ],
  );
  Widget _action(
    String label,
    IconData icon,
    VoidCallback onPressed, {
    bool enabled = true,
  }) => OutlinedButton.icon(
    onPressed: _busy || !enabled ? null : onPressed,
    icon: Icon(icon, size: 16),
    label: Text(label),
    style: OutlinedButton.styleFrom(
      foregroundColor: AgentTheme.cyan,
      side: const BorderSide(color: AgentTheme.stroke),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      textStyle: const TextStyle(
        fontFamily: 'Roboto',
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
