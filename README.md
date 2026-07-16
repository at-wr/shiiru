# Shiiru シール

**Your Telegram stickers, right inside iMessage.**

Shiiru is a native UIKit iOS app that logs into your Telegram account (via
[TDLib](https://core.telegram.org/tdlib), Telegram's official client library),
lets you pick your installed sticker packs, converts them to iMessage-compatible
formats, and serves them through a bundled iMessage extension — with a
Telegram-fluent UI: spring animations, haptics, animated Lottie pack covers,
and a sticker panel that behaves exactly like Apple's own.

*Shiiru (シール) is simply what Japanese calls stickers.*

## How it works

```
┌────────────── Shiiru.app ──────────────┐      ┌── Messages.app ──┐
│ TDLib (MTProto) ── downloads stickers │      │ MessagesExtension │
│ StickerConverter                      │      │ pack tabs + grid  │
│   WEBP → PNG                          │─────▶│ MSStickerView     │
│   TGS  → APNG (Lottie, ≤500 KB)       │ app  │ tap-to-send /     │
│   WEBM → PNG (thumbnail)              │ group│ drag-to-peel      │
│ manifest.json + sticker files         │      │                   │
└───────────────────────────────────────┘      └───────────────────┘
```

- The **app** owns the Telegram session (phone → code → optional 2FA password,
  registration for new numbers is supported too) and syncs the packs you toggle
  on into the shared app-group container.
- The **iMessage extension** reads the manifest and exposes every synced pack
  in a Telegram-style panel. Stickers are native `MSSticker`s, so tapping
  attaches them to the composer and dragging peels them onto any bubble.
  Animated packs are converted to APNG and animate in the conversation.

Your Telegram session never touches any third-party server — TDLib talks to
Telegram directly from the device, and stickers stay on-device.

## Setup

1. **Get Telegram API credentials** (2 minutes):
   - Log in at [my.telegram.org](https://my.telegram.org)
   - Open *API development tools*, create an app (any name)
   - Copy `api_id` and `api_hash` into
     [`App/Sources/Config/TelegramConfig.swift`](App/Sources/Config/TelegramConfig.swift)

   Until you do this, the app boots into a friendly setup screen.

2. **Generate the Xcode project** (requires [XcodeGen](https://github.com/yonaskolb/XcodeGen)):

   ```sh
   xcodegen generate
   open Shiiru.xcodeproj
   ```

3. **Run** the `Shiiru` scheme on an iOS 16+ simulator or device.
   Dependencies (TDLibKit with prebuilt TDLib 1.8.66, Lottie) resolve via SPM.

4. In Messages, open any conversation → **+** → **Shiiru**.
   (On a real device you'll need your own development team + bundle
   identifiers for signing; the app group `group.dev.alany.shiiru` must be
   registered to your team.)

## Sticker conversion

| Telegram format | iMessage output | Notes |
|---|---|---|
| WEBP (static) | PNG 512 px | decoded natively by ImageIO |
| TGS (animated Lottie) | animated APNG | rendered with Lottie at up to 512 px/30 fps; a custom median-cut + Floyd–Steinberg indexed APNG encoder (pngquant-style) keeps files under Apple's 500 KB sticker limit at full quality |
| WEBM (video) | animated APNG | VP9 (+alpha in BlockAdditions) decoded with a vendored libvpx build and a purpose-built WebM demuxer |

## Testing

```sh
xcodebuild -project Shiiru.xcodeproj -scheme Shiiru \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

The unit tests exercise the conversion pipeline with real fixtures: gzip
inflation of TGS, WEBP → PNG compliance (size + dimensions), and TGS → APNG
(multi-frame, non-blank, under 500 KB).

Development notes:

- `TelegramConfig.useTestDC` switches TDLib to Telegram's test datacenter
  (`+99966XYYYY` test numbers). Note that Telegram heavily restricts the
  publicly-documented sample API credentials there — use your own.
- `Scripts/generate_icons.swift` regenerates the app/extension icon sets.

## Project layout

```
project.yml               XcodeGen manifest (targets, entitlements, SPM deps)
App/Sources/Config/       Telegram API credentials
App/Sources/Core/         TelegramService (TDLib), StickerSyncEngine, StickerConverter
App/Sources/UI/           Onboarding, pack list, settings (all UIKit, code-only)
MessagesExtension/        iMessage app: sticker panel with pack tabs
Shared/                   App-group store + manifest, compiled into both targets
Tests/                    Converter unit tests + fixtures
```

## Known limitations

- Extremely complex or long animated stickers may reduce frame rate or fall
  back to a static frame to respect Apple's 500 KB limit.
- Custom-emoji packs are not synced (regular sticker packs only).

## License & acknowledgements

Shiiru is open source, released under the [GNU General Public License
v2.0 or later](LICENSE) (SPDX: GPL-2.0-or-later, Copyright © 2026 Alan Ye). It stands on:

- [TDLib](https://github.com/tdlib/td) — Boost Software License 1.0
- [TDLibKit](https://github.com/Swiftgram/TDLibKit) — MIT
- [Lottie](https://github.com/airbnb/lottie-ios) — Apache 2.0
- [libvpx](https://github.com/webmproject/libvpx) — BSD-3-Clause (vendored VP9 decoder)
- [Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS) — GPL-2.0-or-later (login monkey animations)

Full license texts are shown in-app under Settings → Acknowledgements.

## Privacy

Everything happens on-device; there are no servers, analytics, or tracking.
See [PRIVACY.md](PRIVACY.md) (also shown in-app under Settings → Privacy Policy).
