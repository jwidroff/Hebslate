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
   │  GoogleClient: Cloud Vision (DOCUMENT_TEXT_DETECTION) finds the text lines;
   │  bubble-color sampling (green = me, white/gray = them, centered pill = date
   │  or system) turns them into bubbles
   ▼
FrameReading [side, text, time, sender, cut-off-top/bottom] per bubble
   │  ConversationStitcher: fuzzy-aligns each frame against the chat so far,
   │  merges duplicates, completes cut-off bubbles, appends new messages at the
   │  bottom and prepends at the top (you can scroll either way), and adds a
   │  "messages may be missing" marker when two frames don't overlap
   ▼
de-duplicated conversation
   │  Only messages with no translation yet are sent to Cloud Translation (v2),
   │  in batches of 40
   ▼
ConversationView: a scrollable WhatsApp-style chat in English
```

Features:

* The chat appears while it's processed, and each bubble fills in with its translation as it arrives.
* Tap a bubble to see the original Hebrew. You can also turn on Hebrew under every bubble from the ⋯ menu.
* Long-press a bubble to copy the translation or the Hebrew, or to delete junk (for example text picked up from Control Center at the start of a recording).
* Share or copy the whole translation as a text transcript.
* Translated chats are saved on the device under **Recent translations**.
* **⋯ › View frames used** shows every key frame the recording was read from, in order, so if a message looks wrong, scrambled or missing you can check what the recording actually showed at that point.
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
  Pipeline/                   FrameExtractor, GoogleClient, BubbleLineAssembler, TranslationJob
  Views/                      Home, live job screen, WhatsApp-style chat, settings
  Services/                   settings, conversation storage, default API key
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

## Engine and privacy

Hebslate reads and translates every recording with Google Cloud: Cloud Vision (`DOCUMENT_TEXT_DETECTION`) finds the text lines, and Cloud Translation (v2) translates each message on its own (it has no conversation context, so slang and ambiguous pronouns translate less reliably than a model with full context would).

There is no API key field in the app. The Google Cloud API key is baked into the build at compile time:

1. Create an API key in Google Cloud Console with the **Cloud Vision API** and **Cloud Translation API** enabled.
2. Copy `App/Hebslate/Services/DefaultAPIKeys.swift.example` to `App/Hebslate/Services/DefaultAPIKeys.swift` (gitignored) and fill in the key.
3. Build and run. Every recording on that build uses this key; frames and text go to Google only.

Anyone who extracts the built app (device backup, `.ipa`, decompile) can read the key back out, so only bake in a key for a personal build you won't distribute.

## Recording tips

* Scroll **slowly and steadily**. If a fling skips past content, Hebslate marks the spot with a yellow "messages may be missing" pill.
* You can scroll up or down. Hebslate works out the direction.
* Keep the chat full-screen and the keyboard closed.
* If reading picks up the contact header or the typing bar as messages, adjust **Settings › WhatsApp layout**.

## Known limitations

* Voice notes and stickers aren't transcribed — Cloud Vision only finds text, so these bubbles are skipped.
* A photo bubble with Hebrew text baked into it (a meme, a screenshot) is shown as the original photo with each line's English translation in a white tag over the Hebrew. The photo's bounds are detected from pixel contrast around the text, so the crop can be a little off on busy or low-contrast photos. A plain photo with no text isn't shown at all.
* The gray quoted preview in a reply is left out. Only the reply text is translated.
* Cloud Translation has no conversation context, so slang, idioms and ambiguous pronouns translate less reliably than a context-aware model would.
