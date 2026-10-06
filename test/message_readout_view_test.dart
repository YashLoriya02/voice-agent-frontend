import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/voice_agent/models/message_readout.dart';
import 'package:frontend/voice_agent/widgets/message_readout_view.dart';

void main() {
  testWidgets(
    'readout shows intro then numbered message cards with a working replay button',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const readout = MessageReadout(
        intro: 'Reading 2 saved messages.',
        channel: 'whatsapp',
        messages: [
          NotificationMessage(
            id: 'one',
            sender: 'User1',
            body: 'Hello!\nHow are you?',
            appName: 'WhatsApp',
          ),
          NotificationMessage(
            id: 'two',
            sender: 'User2',
            body: 'A new message',
            appName: 'WhatsApp',
          ),
        ],
      );
      var replayed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: const Color(0xFF07111F),
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: MessageReadoutView(
                readout: readout,
                onReadAllAgain: () => replayed = true,
              ),
            ),
          ),
        ),
      );
      expect(find.text('1.'), findsOneWidget);
      expect(find.text('2.'), findsOneWidget);
      expect(find.text('User1'), findsOneWidget);
      expect(find.text('Hello!\nHow are you?'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Reading 2 saved messages.')).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('message-row-one'))).dy,
        ),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('message-row-one'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('message-row-two'))).dy,
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Read all again'));
      expect(replayed, isTrue);
      expect(readout.replayArguments, {
        'channel': 'whatsapp',
        'unread_only': false,
        'read_all': true,
      });
    },
  );
}
