# Hebslate

Translate an entire WhatsApp conversation from Hebrew to English from **one screen recording**, with no screenshots taken piece by piece.

Record your screen while you scroll through a chat. Hebslate pulls frames out of the video, reads the bubbles in each frame, removes the overlap between frames, and translates each message once. It then rebuilds the conversation as a WhatsApp-style chat (green bubbles on the right, white on the left, date pills in the middle) that you can scroll up and down.

## How it works

```
screen recording
   │  FrameExtractor: samples every 0.2 s and keeps a frame only after the chat
   │  scrolls about half a screen (row-profile scroll estimation), so frames overlap
   ▼
key frames
   │  Reader (one per frame), one of:
   │   • Apple Vision (on-device), if this iOS version can read Hebrew
   │   • Google Cloud Vision – document text detection with line positions
   │     (Apple Vision and Google both go through the same bubble-color analysis:
   │      green = me, white/gray = them, centered pill = date or system)
   │   • Claude – vision model returns structured JSON for each bubble
   ▼
FrameReading [side, text, time, sender, cut-off-top/bottom] per bubble
   │  ConversationStitcher: fuzzy-aligns each frame against the chat so far,
   │  merges duplicates, completes cut-off bubbles, appends new messages at the
   │  bottom and prepends at the top (you can scroll either way), and adds a
   │  "messages may be missing" marker when two frames don't overlap
   ▼
de-duplicated conversation
   │  Only messages with no translation yet are sent to the translator:
   │   • Google Translate – Cloud Translation API, batches of 100
   │   • Claude – batches of 40 with the earlier messages as context
   │   • Apple Translate – fully on-device (Translation framework)
   ▼
ConversationView: a scrollable WhatsApp-style chat in English
```

Features:

* The chat appears while it's processed, and each bubble fills in with its translation as it arrives.
* Tap a bubble to see the original Hebrew. You can also turn on Hebrew under every bubble from the ⋯ menu.
* Long-press a bubble to copy the translation or the Hebrew, or to delete junk (for example text picked up from Control Center at the start of a recording).
* Share or copy the whole translation as a text transcript.
* Translated chats are saved on the device under **Recent translations**.
* Light and dark mode both use WhatsApp's colors.

## Project layout

```
HebslateCore/                 Swift package: platform-independent logic + unit tests
  Sources/HebslateCore/
    Models.swift              FrameMessage, FrameReading, ChatMessage, Conversation
    ConversationStitcher.swift  frame-to-frame alignment, de-dup, merge
    TextSimilarity.swift      Hebrew-aware normalization + fuzzy matching
    LineGrouper.swift         OCR lines → bubbles (color, geometry, time stamps)
    ScrollEstimator.swift     scroll-distance estimation for picking key frames
  Tests/HebslateCoreTests/
App/Hebslate/                 iOS app (SwiftUI, iOS 18+)
  Pipeline/                   FrameExtractor, VisionReader (+ BubbleAnalyzer), GoogleCloudClient,
                              ClaudeClient, TranslationJob
  Views/                      Home, live job screen, WhatsApp-style chat, settings
  Services/                   settings, Keychain, conversation storage
project.yml                   XcodeGen project spec
```

## Build and run

You need a Mac with Xcode 16 or later, and an iPhone on iOS 18 or later.

```bash
brew install xcodegen
xcodegen                 # generates Hebslate.xcodeproj from project.yml
open Hebslate.xcodeproj
```

In Xcode, pick your team under **Signing & Capabilities** (or set `DEVELOPMENT_TEAM` in `project.yml`), then run on your iPhone.

To run the core unit tests:

```bash
cd HebslateCore && swift test
```

## Engines and privacy

The **Settings** screen shows which engines this iPhone supports.

| Step      | On-device (free, private)                                    | Google Cloud (API key)                         | Claude (API key)                                   |
|-----------|---------------------------------------------------------------|------------------------------------------------|----------------------------------------------------|
| Read text | Apple Vision, only if this iOS version can read Hebrew        | Cloud Vision document text detection           | Claude reads each key frame and returns JSON       |
| Translate | Apple Translate, only if it offers Hebrew → English           | Cloud Translation (Google Translate)           | Translates with the conversation as context        |

At the time of writing, Apple's on-device engines don't handle Hebrew, so in practice you need a Google Cloud key or a Claude key.

**Automatic**, the default, reads on-device when possible, then with Google, then with Claude. It translates with Google when a Google key is set, then Claude, then Apple Translate. You can pick each engine explicitly in Settings.

### Setting up Google Cloud

1. Go to <https://console.cloud.google.com>, create a project and turn on billing. Google's free tier currently covers about 1,000 frames and 500,000 translated characters a month.
2. Under **APIs & Services › Library**, enable **Cloud Vision API** and **Cloud Translation API**.
3. Under **APIs & Services › Credentials**, choose **Create credentials › API key**. You can restrict the key to the iOS app `com.hebslate.app` and to those two APIs.
4. Paste the key in Hebslate under **Settings › Google Cloud**. It is stored only in the iOS Keychain on this device.

To use Claude, create an API key at <https://console.anthropic.com>, then paste it in **Settings › Claude**. The key is stored only in the iOS Keychain on this device. Frames and text go to Anthropic only while a Claude engine is in use. The default model is Claude Opus 5.5. You can switch to Sonnet 5.5 or Haiku 5.5 for lower cost. Requests on Opus 5.5 and Sonnet 5.5 turn on server-side refusal fallbacks (`fallbacks: "default"`).

## Recording tips

* Scroll **slowly and steadily**. If a fling skips past content, Hebslate marks the spot with a yellow "messages may be missing" pill.
* You can scroll up or down. Hebslate works out the direction.
* Keep the chat full-screen and the keyboard closed.
* If the on-device reader picks up the contact header or the typing bar as messages, adjust **Settings › WhatsApp layout**.

## Known limitations

* Voice notes, photos and stickers come through as placeholders like `[Photo]` with the Claude reader. The Apple and Google readers skip them because they contain no text.
* The gray quoted preview in a reply is left out. Only the reply text is translated.
* In group chats, sender names are picked up by the Claude reader only.
* Google Translate translates each message on its own. Claude sees the surrounding conversation, so it handles slang and short replies better.
