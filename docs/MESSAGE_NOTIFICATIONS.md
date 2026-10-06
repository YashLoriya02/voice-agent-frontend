# Read message notifications

## Setup on the Nothing phone

1. Install the updated frontend and deploy the updated backend for Custom/Groq commands. Deepgram Voice Agent definitions are included in the frontend.
2. Tap the message icon in the app header, then **Open settings**.
3. Enable notification access for **AI Voice Agent messages** and return to the app. The setup dialog reports whether access is enabled and the listener is connected.
4. Unlock the phone and receive a WhatsApp or Messages notification. Enable message previews in the source app if it only posts generic alerts.
5. Say **Any new messages?**, then **Read my WhatsApp messages** or **Read my SMS messages**.

If Android blocks the sideloaded app's notification access with a restricted-settings message, follow the phone's app-info **Allow restricted settings** option if available. Android still requires this special access even for a personal sideloaded app. See [Android's restricted-settings instructions](https://support.google.com/android/answer/12623953).

Readouts use Android's installed offline speech voice in both providers. If an offline English or phone-language voice is unavailable, the assistant reports that it needs one. Download a voice using Android **Text-to-speech output** settings. Message readouts may sound different from the normal assistant voice.

Media volume must be above zero. A muted media stream is reported as an error before speech starts, leaving previews new.

## Commands

| Say | Behavior |
| --- | --- |
| Any new messages? | Reports available new preview counts and senders locally, without reading bodies or marking anything spoken. |
| Read my WhatsApp messages | Reads up to five new WhatsApp/Business previews, newest first. |
| Read my SMS messages | Reads new previews exposed by the supported Messages/default SMS app. |
| Read WhatsApp messages from Yash | Filters by sender or conversation. Similarly named senders are clarified locally. |
| Read the next two messages | Reads two more previews not yet spoken; retains the previous channel/sender when available. |
| Repeat those messages / Read all my WhatsApp messages | Reads all matching saved previews, including ones already spoken, in speech batches. |
| Read all unread messages | Reads all active previews not yet spoken. |
| Read all again button | Replays all saved previews for the displayed channel/sender. The message-access menu also has Read all saved for every supported channel. |
| Stop button | Stops the readout. An interrupted batch is not acknowledged, so it can be read again. |
| Exit | Closes the session when the assistant is listening. |

## What "new" means

New means **not yet spoken by this assistant**, not WhatsApp's or the SMS database's unread flag. This feature does not mark messages read in the original app or dismiss notifications. Direct SMS inbox access and Gmail OAuth are later features.

The listener captures supported message notification previews, including active notifications when access connects. It ignores group summaries, calls, unrelated apps, and identifiable outgoing MessagingStyle messages. Dismissed notifications stop appearing in new-message checks, but their captured previews remain available for replay, including after app restart. Previews older than 24 hours are unavailable and pruned when the inbox is updated or accessed; the cache holds at most 250 previews.

The response shows an introductory sentence followed by numbered message cards with sender, source app, and the full captured preview text. Speech previews are shortened to 240 Unicode characters; read-all requests use multiple bounded speech batches. Only previews in completed batches are acknowledged. If a later batch fails or is stopped, it and subsequent batches remain unspoken. Missing access, a connecting listener for new-message checks, a locked phone, and failed/cancelled speech are reported separately from an empty preview list. Saved history can be replayed while the notification listener reconnects.

Messages already deleted from the old version's cache cannot be recovered. After updating, test with a fresh notification, read it, dismiss it, and use Read all again.

Muted chats, disabled previews, missing notifications, attachments without text, and Android-redacted content can limit what is available. This does not provide a complete WhatsApp/SMS/RCS inbox or past messages without an available notification.

## Message data and voice providers

Captured previews are stored privately on the device and excluded from Android backup and device transfer. Bodies and captured sender summaries are never put into Groq conversation history or Deepgram function responses. Native message speech requires an installed voice that does not require a network connection. Your spoken command still uses the existing cloud speech-recognition/routing pipeline.

## Backend routing smoke test (PowerShell)

```powershell
'{"text":"Read my WhatsApp messages"}' |
    curl.exe -sS --request POST 'https://voice-ai-agent-server.vercel.app/voice-agent/execute' `
        --header 'Content-Type: application/json' --data-binary '@-'
```

Expected response: `success: true`, `type: tool_call`, `tool: read_messages`, with `channel: whatsapp` in arguments. **Any new messages?** should return `check_messages`. Curl checks routing; only the installed app can access the phone's previews and speak them.

## Verification

Run `flutter test` in frontend and `npm test` in backend. Native inbox tests run with `:app:testDebugUnitTest` in the Android Gradle project. Physical-device checks should include one WhatsApp message, multiple messages in a chat, a group message, an SMS/RCS preview, repeated checks before/after reading, read-more/repeat commands, cancelling a batch, dismissing notifications, and revoking/re-enabling access.

Verification covers message-list rendering, both replay buttons, saved-history replay, multi-batch reads, partial failure, archive reload, and remote-result privacy. Real WhatsApp/SMS delivery and installed offline voices still need verification on the Nothing phone.

Android references: [NotificationListenerService](https://developer.android.com/reference/android/service/notification/NotificationListenerService), [MessagingStyle message bundles](https://developer.android.com/reference/android/app/Notification.MessagingStyle.Message), [Android notification-content restrictions](https://developer.android.com/about/versions/15/behavior-changes-all).
