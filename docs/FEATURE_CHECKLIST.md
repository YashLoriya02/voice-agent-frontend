# Personal Android assistant checklist

Target device: Nothing Phone (3a), Nothing OS 4 / Android 16.

## First implementation

- [x] Sleep / Exit: end the session, stop audio/network activity, close the visible app or native assistant sheet. The selected Android assistant remains able to hear Hey Agent afterward.
- [x] Dynamic installed-app launching: discover launcher labels, prefer exact matches, clarify ambiguous names, retain existing aliases and system-app intents.
- [x] Resolve close speech spellings against installed labels (e.g. septo/Zepto, Upstocks/Upstox, helo/Healo, DGLocker/DigiLocker), asking when similarly close apps exist.
- [x] Torch on/off with camera permission.
- [x] Media, ring, and alarm volume: set percentage, increase/decrease one system step, mute/unmute.
- [x] System brightness: percentage, manual mode, special-access screen when needed. Zero selects minimum visible brightness.
- [x] Speak actual battery percentage and charging state.
- [x] Register capabilities for both custom Groq and Deepgram Voice Agent.
- [ ] Verify microphone handoff, permissions, hardware controls, and wake reactivation on the physical Nothing phone.

Example commands: "Sleep", "Exit", "Open Signal", "Turn the torch on",
"Set media volume to 40 percent", "Turn alarm volume up",
"Set brightness to 60 percent", "What is my battery percentage?".

Volume is rounded to the phone's available system steps. Muting media also
mutes assistant playback; its result remains visible. Camera-in-use or
restricted volume changes can fail and are reported as device errors.
Brightness requires Settings > Special app access > Modify system settings.

The Flutter API defaults to the deployed Vercel backend. Deploy the backend
changes or build with `--dart-define=VOICE_AGENT_API_URL=<your-server-url>`
to use new Groq commands. The Flutter build contains Deepgram tool definitions.

Validation: the Flutter suite covers speech spelling correction, message filtering,
local speech, remote-result privacy, and message-access setup. Native inbox tests
cover notification updates, acknowledgement, dismissal, retention, and cache limits.
The backend routing test runs without an external API call. An ARM64 debug APK builds.
Static analysis reports existing informational deprecations, with no errors.
Run `flutter test` in frontend and `npm test` in backend.

## Message notifications

- [x] Capture WhatsApp and WhatsApp Business message notification previews.
- [x] Capture message notifications from Google Messages, Samsung Messages, and the current default SMS app (including RCS previews exposed by these apps).
- [x] Read previews aloud, check counts/senders, filter by sender/conversation, read more, and repeat available previews.
- [x] Setup button in the header opens Android notification access settings.
- [x] Track previews already spoken after successful local speech. Checking does not acknowledge them; cancellation and speech failure leave the batch new.
- [x] Keep message bodies/sender summaries on-device; use an installed offline Android TTS voice and send only sanitized completion status to the remote voice agent.
- [x] Bound the private cache to 250 previews / 24 hours, exclude it from backup, archive dismissed notifications for replay, and reconcile active status when the listener reconnects.
- [x] Show an intro followed by numbered message cards and provide Read all again / Read all saved controls, including multi-batch replay of previously spoken previews.
- [ ] Verify actual WhatsApp/SMS notification formats, offline voice availability, permissions, and interrupted readouts on the Nothing phone.

See [MESSAGE_NOTIFICATIONS.md](MESSAGE_NOTIFICATIONS.md) for setup and test commands.

## Remaining groups

- [ ] SMS unread-message reading (READ_SMS and installer allowlisting).
- [ ] Gmail unread-message reading with Google OAuth and Gmail API.
- [ ] Current-location driving distance/time with destination resolution and Routes API.
- [ ] Shizuku setup and per-device capability checks.
- [ ] Wi-Fi and internet hotspot on/off.
- [ ] Phone restart with an explicit, expiring confirmation.
- [ ] Airplane on/wait/off executed locally, with restoration checked before cloud reconnection.

Shizuku on an unrooted phone requires restarting after reboot. Privileged
controls must be verified on the actual firmware before claiming support.
