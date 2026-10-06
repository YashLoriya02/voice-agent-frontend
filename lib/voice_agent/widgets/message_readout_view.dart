import 'package:flutter/material.dart';

import '../models/message_readout.dart';

class MessageReadoutView extends StatelessWidget {
  const MessageReadoutView({
    super.key,
    required this.readout,
    this.onReadAllAgain,
  });
  final MessageReadout readout;
  final VoidCallback? onReadAllAgain;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        readout.intro,
        style: const TextStyle(
          color: Color(0xFFF3F7FF),
          fontSize: 17,
          height: 1.4,
        ),
      ),
      for (var i = 0; i < readout.messages.length; i++)
        Container(
          key: ValueKey('message-row-${readout.messages[i].id}'),
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF0D223A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF193C60)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${i + 1}.',
                style: const TextStyle(
                  color: Color(0xFF66B6FF),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      readout.messages[i].senderLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      readout.messages[i].appName,
                      style: const TextStyle(
                        color: Color(0xFF7E9BB7),
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      readout.messages[i].body,
                      style: const TextStyle(
                        color: Color(0xFFE1EAF5),
                        fontSize: 15,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      if (readout.footer.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            readout.footer,
            style: const TextStyle(color: Color(0xFF96ACC5), height: 1.4),
          ),
        ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: onReadAllAgain,
        icon: const Icon(Icons.replay_rounded, size: 18),
        label: const Text('Read all again'),
      ),
    ],
  );
}
