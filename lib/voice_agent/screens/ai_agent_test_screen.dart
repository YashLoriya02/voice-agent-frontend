import 'package:flutter/material.dart';

import '../models/agent_response.dart';
import '../models/contact_match.dart';
import '../models/tool_execution_result.dart';
import '../services/device_action_service.dart';
import '../services/voice_agent_api_service.dart';
import '../tools/tool_executor.dart';

class AiAgentTestScreen extends StatefulWidget {
  const AiAgentTestScreen({super.key});

  @override
  State<AiAgentTestScreen> createState() => _AiAgentTestScreenState();
}

class _AiAgentTestScreenState extends State<AiAgentTestScreen> {
  final TextEditingController _controller = TextEditingController();

  bool _loading = false;

  String _status = 'Enter a command';

  String? _detectedTool;

  Map<String, dynamic>? _detectedArguments;

  List<ContactMatch> _contactMatches = [];

  String? _pendingContactTool;

  Map<String, dynamic> _pendingContactArguments = <String, dynamic>{};

  Future<void> _execute() async {
    final text = _controller.text.trim();

    if (text.isEmpty || _loading) {
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() {
      _loading = true;
      _status = 'Understanding command...';

      _detectedTool = null;

      _detectedArguments = null;

      _contactMatches = [];

      _pendingContactTool = null;

      _pendingContactArguments = <String, dynamic>{};
    });

    try {
      final AgentResponse response = await VoiceAgentApiService.executeCommand(
        text,
      );

      /*
       * LLM needs more information.
       */
      if (response.type == 'ask_user') {
        setState(() {
          _loading = false;

          _status = response.message ?? 'I need more information.';
        });

        return;
      }

      /*
       * LLM knows this isn't supported.
       */
      if (response.type == 'unsupported') {
        setState(() {
          _loading = false;

          _status = response.message ?? 'That action is not supported yet.';
        });

        return;
      }

      /*
       * Unexpected response.
       */
      if (response.type != 'tool_call' || response.tool == null) {
        throw Exception('Invalid agent response.');
      }

      setState(() {
        _status = 'Executing ${response.tool}...';

        _detectedTool = response.tool;

        _detectedArguments = response.arguments;
      });

      final result = await ToolExecutor.execute(
        tool: response.tool!,
        arguments: response.arguments,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;

        _status = result.message;

        if (result.status == ToolExecutionStatus.needsContactSelection) {
          _contactMatches = result.contacts;
          _pendingContactTool = result.pendingContactTool;
          _pendingContactArguments = result.pendingContactArguments;
        }
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;

        _status = 'Error: $e';
      });
    }
  }

  Future<void> _selectContact(ContactMatch contact) async {
    try {
      if (_pendingContactTool == 'send_message') {
        final result = await ToolExecutor.composeMessageToContact(
          contact: contact,
          messageBody:
              _pendingContactArguments['message']?.toString() ?? '',
          channel: _pendingContactArguments['channel']?.toString() ?? '',
        );

        if (!mounted) return;
        setState(() {
          _contactMatches = [];
          _pendingContactTool = null;
          _pendingContactArguments = <String, dynamic>{};
          _status = result.message;
        });
        return;
      }

      await DeviceActionService.dialNumber(phoneNumber: contact.phoneNumber);

      if (!mounted) {
        return;
      }

      setState(() {
        _contactMatches = [];

        _pendingContactTool = null;

        _pendingContactArguments = <String, dynamic>{};

        _status = 'Opening ${contact.name} in the dialer.';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Unable to open dialer: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Healo AI Agent')),

      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),

          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,

            children: [
              TextField(
                controller: _controller,

                textInputAction: TextInputAction.send,

                onSubmitted: (_) => _execute(),

                decoration: const InputDecoration(
                  labelText: 'Command',

                  hintText: 'e.g. Set a timer for 2 minutes',

                  border: OutlineInputBorder(),
                ),
              ),

              const SizedBox(height: 16),

              ElevatedButton.icon(
                onPressed: _loading ? null : _execute,

                icon: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome),

                label: Text(_loading ? 'Processing...' : 'Run command'),
              ),

              const SizedBox(height: 24),

              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),

                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,

                    children: [
                      const Text(
                        'Agent status',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),

                      const SizedBox(height: 8),

                      Text(_status),

                      if (_detectedTool != null) ...[
                        const SizedBox(height: 16),

                        Text('Tool: $_detectedTool'),

                        const SizedBox(height: 4),

                        Text(
                          'Arguments: '
                          '$_detectedArguments',
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              if (_contactMatches.isNotEmpty) ...[
                const SizedBox(height: 20),

                const Text(
                  'Choose contact',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),

                const SizedBox(height: 8),
              ],

              Expanded(
                child: ListView.builder(
                  itemCount: _contactMatches.length,

                  itemBuilder: (context, index) {
                    final contact = _contactMatches[index];

                    return Card(
                      child: ListTile(
                        title: Text(contact.name),

                        subtitle: Text(
                          '${contact.phoneNumber}'
                          '${contact.label != null ? ' • ${contact.label}' : ''}',
                        ),

                        trailing: const Icon(Icons.call),

                        onTap: () => _selectContact(contact),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
