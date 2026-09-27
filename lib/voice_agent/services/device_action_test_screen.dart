import 'package:flutter/material.dart';

import '../models/contact_match.dart';
import '../services/device_action_service.dart';

class ContactTestScreen extends StatefulWidget {
  const ContactTestScreen({super.key});

  @override
  State<ContactTestScreen> createState() => _ContactTestScreenState();
}

class _ContactTestScreenState extends State<ContactTestScreen> {
  final controller = TextEditingController();

  List<ContactMatch> matches = [];

  String status = 'Enter a contact name';

  bool loading = false;

  Future<void> searchContact() async {
    final query = controller.text.trim();

    if (query.isEmpty) {
      return;
    }

    setState(() {
      loading = true;
      status = 'Searching contacts...';
      matches = [];
    });

    try {
      final permission = await DeviceActionService.requestContactsPermission();

      if (!permission) {
        setState(() {
          status = 'Contacts permission denied';
          loading = false;
        });

        return;
      }

      final result = await DeviceActionService.findContacts(query: query);

      setState(() {
        matches = result;
        loading = false;

        if (result.isEmpty) {
          status = 'No contacts found for "$query"';
        } else {
          status = '${result.length} contact(s) found';
        }
      });
    } catch (e) {
      setState(() {
        status = 'Error: $e';
        loading = false;
      });
    }
  }

  Future<void> dial(ContactMatch contact) async {
    await DeviceActionService.dialNumber(phoneNumber: contact.phoneNumber);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Voice Agent — Contact Test')),

      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Contact name',
                hintText: 'Akruti',
                border: OutlineInputBorder(),
              ),
            ),

            const SizedBox(height: 16),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: loading ? null : searchContact,
                child: const Text('Find Contact'),
              ),
            ),

            const SizedBox(height: 20),

            Text(status),

            const SizedBox(height: 20),

            Expanded(
              child: ListView.builder(
                itemCount: matches.length,
                itemBuilder: (context, index) {
                  final contact = matches[index];

                  return Card(
                    child: ListTile(
                      title: Text(contact.name),

                      subtitle: Text(
                        '${contact.phoneNumber}'
                        '${contact.label != null ? ' • ${contact.label}' : ''}',
                      ),

                      trailing: IconButton(
                        icon: const Icon(Icons.call),

                        onPressed: () {
                          dial(contact);
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
