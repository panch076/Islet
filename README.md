# Islet

A free, open notch / Dynamic Island app for macOS 15+. On Macs without a notch it shows as a floating pill.

## Build

```sh
./build.sh            # builds the app, the Islet Audio driver, and embeds both → build/Islet.app
open build/Islet.app
python3 scripts/localize.py   # regenerate translations after editing them
```

Move `build/Islet.app` to `/Applications` for Launch at Login. The app is ad-hoc signed, so after each rebuild macOS may ask again for permissions (Accessibility in particular).

Settings live in their own window: the gear in the island, the menu bar icon, or reopen Islet from Finder/Spotlight.

## Features

| Area | What it does |
| --- | --- |
| Island | Notch or pill, Black or Liquid Glass (interactive), bouncy/smooth/snappy animation, custom width/height with live preview, target display, pill offset, hide in full-screen apps, hide from screen capture |
| Peek & idle | Mini player on a quick hover; idle clock, weather, breathing dot, or your own Lottie animation |
| Live activities | Calls, agents, shell commands, Pomodoro (with a mascot), music, privacy dots, HUDs; two at once |
| Now Playing | From Lyrical: Apple Music, Spotify, Kaset, YouTube Music in Chrome/Safari, Shazam for anything else; album-colour glow, karaoke lyric line, glass transport, scrubbing, full-screen lyrics |
| Lyrics | LRCLIB with fuzzy matching, Apple Music-style rolling lyrics, click a line to seek, sync offset |
| Sound | Output switching, volume, mic mute (⌃⌥M), 3-band EQ via the Islet Audio driver, AirPods/Bluetooth, mouse/keyboard/trackpad batteries, live FFT spectrum |
| Displays & HUDs | Replace the system volume/brightness HUD; island, edge-bar or gauge style; DDC brightness for external monitors; keyboard backlight; hide the notch |
| Alerts | Downloads, screenshots → Shelf, drives, Caps Lock, keystrokes, Focus, full charge, low battery, iMessage island, notification mirror |
| Clipboard | History with images + OCR, smart actions (open link, email, call, colour, pretty JSON, maths, web search) |
| Shelf | Drop files, drag out, AirDrop, zip/unzip, image conversion |
| Notes | Quick notes, snippets, Apple Reminders |
| Pomodoro | Drift-free timer, long breaks, auto-chaining, streaks, 7-day chart, mascots, stopwatch with laps |
| Knock | Single/double/triple knocks via microphone (any Mac), accelerometer (Apple Silicon MacBooks), or double-tap a modifier key |
| Widgets | Weather (Open-Meteo), stocks, desktop widgets, menu bar calendar, menu bar icon hiding, detach into the menu bar |
| Tools | App launcher, colour eyedropper, Apple Shortcuts, drive eject, translate, teleprompter, camera mirror, keyboard cleaning lock |
| AI usage | Claude Code (tokens, cost, 5-hour window), Codex, Copilot quotas (via `gh`), Cursor; alerts |
| Developer | Local API, agent activity, agent approvals from the island, shell activity, command palette (⌃⌥K) with search, translate and maths |
| Other | Terminal (SwiftTerm), stats, calendar, window snapping, face presence, Keep Awake, 8 languages |

### Notchy-parity settings

- **Island:** Smooth / Snappy / Bouncy motion, animation speed, collapse delay (incl. instant), invisible until hover, hide if menus overlap, double-click to open, pill height, clock (time/date/both, 5 date formats, seconds), typography, monochrome, glass translucency, custom pill/panel colours and gradients, black-out screen corners, tab visibility and default tab, configurable Home cards
- **Now Playing:** island on/off, hide when paused, announce new tracks, media keys → current app, default player, scrolling titles, square art, ±10/15/30 s skips, shuffle/repeat, browser playback speed, listening history, desktop lyrics
- **Clipboard & Shelf:** history limit, pause, keep after quit, auto-clear (1 h, 1 day, lock, sleep), ignore list, copy sound, tracking-parameter stripping, paste as plain text (⌃⌥V), independent shelf copies, shelf cleanup, image compression to a target size
- **Focus:** focus sounds (rain, brown noise, wind, waves — generated live), 20-20-20 break reminders, countdown timer with repeat, menu bar timer
- **Displays:** software dimming, colour temperature, refresh-rate switcher, cursor ripples/halo/spotlight, clean screen
- **Widgets & calendar:** world clock, stock price alerts, meeting countdown with Join links, full-screen meeting alert, next meeting in the menu bar, quick-add events, custom search engines
- **Other:** Ask AI tab (your Anthropic key, stored in Keychain), always-allow rules for agent approvals, screen time, network data usage, top processes, listening ports with "free port", launcher wheel (⌃⌥W), ⌥Space to show the island, settings search, export/import

## Islet Audio driver (equalizer)

The EQ routes system audio through a virtual device so there's no echo. Install it from Settings → Sound (asks for your password), or:

```sh
cd Driver && ./build.sh && sudo ./install.sh     # sudo ./uninstall.sh to remove
```

## Local API

Off by default; Settings → Developer. Listens on `127.0.0.1:47219` only.

```
GET  /status
GET  /notify?text=Hi&icon=bell.fill&seconds=3
GET  /agent?agent=Claude&state=working|waiting|done
GET  /shell?state=start|end&id=…&cmd=…&code=…
POST /approve?agent=Claude      (Claude Code hook JSON; answers when you click Allow/Deny)
GET  /play-pause  /next  /previous  /keep-awake  /pomodoro  /mic
```

Settings → Developer has copy buttons for the Claude Code hooks, the Codex notify line, and the zsh snippet.

## Not included

- **Virtual pet, iCloud sync, Google/Outlook/CalDAV accounts, Todoist, battery charge limit, Face Unlock typing your password** — not built (accounts and sync need server credentials; the charge limit needs a root SMC helper; storing your password isn't safe).

- **Lock Screen widgets** — third-party apps can't draw on the macOS lock screen.
- **Per-app Sound Mixer** — needs per-process audio taps alongside the driver; not built yet.
- **Automatic updates** — Islet is built from source; rebuild to update.
- **Face Unlock** — replaced by Face presence (lock when away, wake on return). Unlocking would require storing your password.
