# AI Voice Agent

A personal Android voice assistant built with Flutter, Kotlin and Express. Speak a command to open an installed app, manage everyday phone controls, read message notifications or Gmail, and get driving directions through Google Maps.

The assistant supports two voice engines, an offline **“Hey Agent”** wake phrase, a native assistant panel with an animated screen-edge glow, and a dedicated settings page. The interface uses dark navy surfaces, blue/cyan accents and consistent typography across the app and its setup controls.

## Capabilities

| Capability | Examples and behavior |
| --- | --- |
| Hands-free activation | Say **“Hey Agent”**. Native Vosk detection hands the microphone to the selected voice engine. Selecting the app as Android's default assistant enables the system assistant experience. |
| Installed apps | **“Open Zepto”**, **“Open Upstox”**, **“Open DigiLocker”**. Discovers launcher labels, handles close speech spellings and asks when app names are ambiguous. |
| Contacts and messages | **“Call Yash”** opens the dialer. **“Send Yash a WhatsApp message saying hello”** opens a prefilled composer; the user reviews and sends it. |
| Alarms and timers | **“Set an alarm for 7 AM”**, **“Set a timer for ten minutes”**. Uses Android's installed alarm/timer app. |
| Phone controls | Torch on/off; media, ring and alarm volume; screen brightness; actual battery percentage and charging status. |
| Message previews | **“Read my WhatsApp messages”**, **“Any new messages?”**. Reads captured WhatsApp, WhatsApp Business and supported SMS/RCS notification previews locally. Supports sender filters, read-more requests and saved-message replay. |
| Gmail | **“Read my unread emails”**, **“Read the last email from OpenAI”**, **“Show me one last unread email”**, **“Repeat those emails”**. Reads inbox sender, subject and preview, or reports the unread inbox count. |
| Maps | **“How far is Mumbai airport by car?”** opens driving directions and reads clearly displayed distance/time through the optional Maps reader. **“Navigate to Pune”** requests navigation from Maps' current device location. |
| Conversation | General questions, explanations, calculations and conversational responses. Custom mode supports live web search when enabled and available through the provider. |
| Session controls | **“Sleep”** or **“Exit”** ends the current session and closes the app or native assistant panel. Wake detection follows the saved activation setting. |

Mail and notification results appear as an introductory sentence followed by numbered message cards. Replay controls are available directly on the result.

## Voice options

### Custom / Groq

Deepgram Flux transcribes speech, the Express backend uses Groq to route commands and answer questions, and Deepgram Aura supplies streamed speech. Recognized Gmail/Maps commands are routed directly to phone tools instead of relying on a conversational model to select them.

### Deepgram Voice Agent

A Deepgram Voice Agent connection handles speech recognition, conversation and streamed speech. The configured thinking model is Claude Sonnet 4.6. Device functions execute on the phone; recognized Gmail/Maps requests use the direct local action path.

The preferred voice option and wake setting are saved on Android. The home screen and Settings both expose voice selection.

## Settings and assistant interface

Open the gear icon on the home screen to access **Settings**:

- **Voice & activation:** choose a voice engine, toggle Hey Agent, select the default Android assistant and preview the native interface.
- **Messages:** view notification-listener status, manage notification access and read saved previews.
- **Gmail:** connect/disconnect an account and read unread mail.
- **Maps:** view installed-app/reader status, manage accessibility access and read the displayed route.

The page refreshes access status when returning from Android settings. Connection failures are shown inline. App setup uses a full page; Google consent and Android permission selection remain native system interfaces.

The native Hey Agent panel displays listening, thinking, speaking and action states. A blue/cyan glow traces the screen perimeter, with completion/error colors. The glow is decorative: touches outside the assistant panel remain available to the app underneath. Native animations stop when hidden and honor Android's disabled-animation setting.

## Technology

| Layer | Technology |
| --- | --- |
| App | Flutter, Dart, Material widgets and shared dark-theme colors |
| Android integration | Kotlin, MethodChannel, Android intents, VoiceInteractionService/Session |
| Wake phrase | Vosk Android with bundled `vosk-model-small-en-us-0.15`, JNA |
| Speech | Deepgram Flux, Aura TTS and Deepgram Voice Agent; Android offline TextToSpeech for private readouts |
| Audio | `record` for microphone capture, `audio_stream_player` for PCM playback |
| Backend | Node.js ES modules, Express 5, Groq SDK, dotenv and mathjs |
| Mail | Google Play services AuthorizationClient, Gmail API, `gmail.readonly` scope |
| Maps | Installed Google Maps URLs; Maps-only AccessibilityService for displayed estimates |
| Tests | Flutter widget/unit tests, Kotlin/JUnit tests and Node's built-in test runner |

## Project layout

```text
ai-voice-agent/
├── README.md
├── frontend/
│   ├── android/              # Native assistant, device actions and bundled Vosk model
│   ├── lib/voice_agent/
│   │   ├── models/
│   │   ├── screens/
│   │   ├── services/
│   │   ├── theme/
│   │   ├── tools/
│   │   └── widgets/
│   ├── test/
│   └── pubspec.yaml
└── backend/
    ├── index.js
    ├── services/
    ├── tests/
    ├── .env.example
    └── package.json
```

## Requirements

- Flutter compatible with the project's Dart SDK constraint (`^3.13.2`).
- Android SDK and Java 17 for Android builds.
- Node.js 18.17 or newer and npm.
- An Android phone with microphone access; Google Play services for Gmail authorization.
- Groq and Deepgram credentials for the existing cloud voice engines.
- Installed Google Maps for directions/navigation.

The Android integration is designed for personal use. The app package is `com.example.frontend`.

## Environment configuration

Create `backend/.env` from [backend/.env.example](backend/.env.example):

```env
GROQ_API_KEY=your_groq_api_key
DEEPGRAM_API_KEY=your_deepgram_api_key

# Optional: disable Custom mode's live web search.
ENABLE_WEB_SEARCH=false
```

| Variable | Purpose |
| --- | --- |
| `GROQ_API_KEY` | Custom mode's command routing, conversational answers and enabled web search. |
| `DEEPGRAM_API_KEY` | Backend generation of temporary Deepgram tokens and Custom mode's streamed TTS. |
| `ENABLE_WEB_SEARCH` | Optional. The literal value `false` disables live web search; it is enabled when unset. |
| `VOICE_AGENT_API_URL` | Optional Flutter build define for the backend URL. Defaults to `https://voice-ai-agent-server.vercel.app`. |

Keep provider API keys on the backend and out of Git. The frontend has no API-key `.env` file. Gmail authorization is native and does not use a client secret, web client ID or `google-services.json`.

Maps uses the installed application and requires no Maps API key, client token, Places API or Routes API. The backend contains no paid routing proxy. Older `ENABLE_PAID_MAPS`, `GOOGLE_MAPS_API_KEY` and `MAPS_CLIENT_TOKEN` values have no effect on this version.

Gmail can use an unbilled Google Cloud project. Groq and Deepgram voice usage follows the connected accounts' quotas and pricing; this project does not claim those external voice services are unlimited or free.

## Run and build

### Backend

```bash
cd backend
npm ci
cp .env.example .env
# Fill in your provider keys in .env.
npm start
```

The server listens on port `8080`. For hosted use, configure the provider variables in the hosting platform's environment settings and deploy the backend directory.

### Android app

```bash
cd frontend
flutter pub get
flutter run --dart-define=VOICE_AGENT_API_URL=https://your-backend.example
```

For a physical phone connecting to a local backend, use the computer's reachable LAN address instead of `localhost`. An Android emulator can reach the host through `10.0.2.2:8080`.

```bash
flutter build apk --debug --target-platform android-arm64
```

The Flutter build exports `frontend/build/app/outputs/flutter-apk/app-debug.apk`. The current release configuration also signs with the local debug certificate. Gmail OAuth registration must match the certificate used for the installed APK.

## Android setup

### Voice and device access

1. Install the APK and allow microphone access.
2. Open **Settings → Voice & activation** to choose the voice engine and Hey Agent setting.
3. Use **Make default** and select AI Voice Agent in Android's digital-assistant settings for the native invocation interface.
4. Grant contacts access for contact lookup, camera access for torch control, and **Modify system settings** access for brightness when prompted.
5. Install an offline voice under Android's **Text-to-speech output** settings for mail/message/Maps readouts. Keep media volume above zero.

### Message notifications

1. In **Settings → Messages**, tap **Manage access**.
2. Enable notification access for **AI Voice Agent messages**.
3. Enable notification previews in the source messaging apps.

“New” means a captured preview that this assistant has not successfully spoken. It does not mean the source app's unread database flag. Reading does not dismiss notifications or mark source messages read. Saved previews are bounded to 250 items and 24 hours, and are excluded from Android backup/device transfer.

### Gmail

1. Create/select an **unbilled** project in [Google Cloud Console](https://console.cloud.google.com/) and enable **Gmail API**.
2. Configure Google Auth Platform branding, External audience and Testing mode; add your Gmail address as a test user.
3. Add `https://www.googleapis.com/auth/gmail.readonly` to Data Access.
4. Create an **Android OAuth client** for `com.example.frontend`, with your APK signing certificate's SHA-1.
5. In the app's **Settings → Gmail**, tap **Connect Gmail** and grant read-only access.

Inspect the signing certificate from the Android project:

```powershell
cd frontend/android
.\gradlew.bat signingReport
```

On macOS/Linux, the equivalent Gradle command is `./gradlew signingReport`. This reports the certificate used to build Android; the app itself is Android-only.

Gmail reads INBOX sender, subject and snippet, defaulting to five unread emails with a maximum of ten. “Last/latest email” selects one matching inbox email and includes already-read mail unless unread is specified. Full bodies and attachments are not downloaded. Reading aloud leaves Gmail's unread state unchanged.

Replay holds the last fetched mail list in memory. Restarting or disconnecting clears it. Disconnect clears local account/token state; revoke Google's grant through [Google Account connections](https://myaccount.google.com/connections).

### Maps

1. Install/enable Google Maps and allow its location access.
2. Navigation commands work through the installed app without the agent's accessibility reader.
3. To speak displayed distance/time, open **Settings → Maps → Enable Maps reader** and enable **AI Voice Agent Maps reader** in Android Accessibility settings.

If Android restricts special access for a sideloaded app, use **App info → Allow restricted settings** where available, then enable the relevant access.

Maps determines its own current-location origin. The agent does not request GPS coordinates, upload a custom origin to Express, or contact community routing services. Maps can show a preview/destination selection if location is unavailable or the destination is ambiguous. The reader checks only visible Maps summaries during an explicit request; it does not press navigation controls or save screenshots. Displayed estimates depend on Maps' accessibility labels and language, with English labels as the primary target.

## Data flow and privacy

- Vosk wake detection runs locally with the bundled model.
- Spoken commands use the selected cloud speech/conversation provider.
- Device actions execute natively on Android.
- Gmail tokens stay in native memory/Google Play services. Mail requests go directly from the phone to Gmail.
- Captured notification bodies and Gmail previews are read with an offline Android voice. Their contents are excluded from remote function responses and conversation history.
- The microphone upload is paused during private readouts. The app shows permission, network, lock-state and offline-voice failures rather than inventing data.
- Mail/message/route readouts require an unlocked phone. Google Maps handles its location/search/navigation through its own app settings.

## Backend endpoints

| Method | Endpoint | Purpose |
| --- | --- | --- |
| GET | `/` | Health response |
| GET | `/deepgram/token` | Short-lived Deepgram access token |
| POST | `/deepgram/tts` | Stream PCM16 mono speech at 24 kHz |
| POST | `/voice-agent/execute` | Route a voice command; phone tools execute in the app |

Example routing check:

```bash
curl --request POST http://localhost:8080/voice-agent/execute \
  --header 'Content-Type: application/json' \
  --data '{"text":"Navigate to Pune from my current location"}'
```

The response identifies `get_driving_route` with `start_navigation: true`. Curl verifies routing; the installed Android app performs the phone action.

## Tests

```bash
cd backend
npm test
```

```bash
cd frontend
flutter analyze
flutter test
```

```powershell
cd frontend/android
.\gradlew.bat :app:testDebugUnitTest
```

Tests cover installed-app matching, device command validation, message capture/replay, private result handling, Gmail/Maps command routing, navigation URLs, displayed-route parsing and settings interactions. Native integrations depend on the installed apps, Android access settings and available speech voices.

## References and model attribution

- [Android authorization](https://developer.android.com/identity/authorization)
- [Google Maps URLs](https://developers.google.com/maps/documentation/urls/get-started)
- [Android notification access](https://developer.android.com/reference/android/service/notification/NotificationListenerService)
- [Android voice interaction sessions](https://developer.android.com/reference/android/service/voice/VoiceInteractionSession)
- [Vosk model source and license](frontend/android/app/src/main/assets/model-en-us/MODEL_SOURCE.md)
