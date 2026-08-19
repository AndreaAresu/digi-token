# DigiTokenBar

Raise a Digimon in your macOS menu bar. It grows on the tokens you actually burn
in Claude Code and Codex — and **how** you work decides what it becomes.

![stage](https://img.shields.io/badge/stage-early-orange) ![platform](https://img.shields.io/badge/macOS-14%2B-black) ![build](https://img.shields.io/badge/build-swiftc%20only-blue)

---

## Why Digimon and not Pokémon

This started as "PokeTokenBar, but Digimon". It turned into something different,
because Digimon's own mechanics fit token usage far better than Pokémon's do.

| | Pokémon | Digimon |
|---|---|---|
| Evolution | a fixed line — Charmander only becomes Charmeleon | a **branching graph with conditions** |
| Stages | 3 | **6** (Baby I → Baby II → Child → Adult → Perfect → Ultimate) |
| Rare variant | shiny, a palette swap | **X-Antibody**, a real canon form with its own artwork |
| Raising | catch it, it is done | **care, weight, discipline, care mistakes** — the original V-Pet loop |
| Fusion | none | **Jogress (DNA Digivolution)** |

The branching graph is the whole point. A Pokémon tracker can only reward *how
many* tokens you spent. DigiTokenBar reads the **shape** of your usage and picks
a different branch because of it:

- **Weight** comes from your cache-read ratio. Re-sending context is overfeeding;
  letting the cache work keeps your partner lean.
- **Discipline** comes from consistency — active days and streaks, not volume.
- **Care mistakes** come from windows you ran into the ground and recent idle
  days (with a grace allowance, because nobody codes seven days a week).
- **Alignment** — Vaccine / Data / Virus / Free — falls out of the above and is
  the strongest input into which branch you take at the next digivolution.

A disciplined, cache-efficient tamer and a nocturnal one who burns windows to
zero will not end up with the same partner, even from the same egg.

Branch selection is **deterministic** for a given seed, form and care profile.
Relaunching the app cannot be used to reroll a result you did not like.

## What it reads

Local log files that Claude Code and Codex already write. No API keys, no
proxy, no account, no network call to collect usage. Specifically:

- `~/.claude/projects/**/*.jsonl` (also `CLAUDE_CONFIG_DIR` and `~/.config/claude`)
- `~/.codex/sessions/**/*.jsonl` (also `CODEX_HOME`)

Scanning is incremental — each refresh reads only the bytes appended since the
last one. A cold scan of ~4,200 events takes about a second; warm scans are free.

The only outbound requests the app ever makes are to `digi-api.com` for artwork,
fetched once per Digimon and then cached on disk. Your usage never leaves the
machine.

## Install

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).
Full Xcode is **not** needed.

```bash
git clone <your-fork> digi-token && cd digi-token && ./scripts/build-app.sh
```

Then:

```bash
cp -R build/DigiTokenBar.app /Applications && open /Applications/DigiTokenBar.app
```

The app is ad-hoc signed. On first launch macOS may ask you to confirm it —
right-click → Open, or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/DigiTokenBar.app
```

## Growth curve

Growth runs on *billable* tokens — input, output and cache writes. Cache reads
are excluded, so the app never rewards you for wasting money.

| Stage | Dub name | Billable tokens |
|---|---|---|
| DigiTama | egg | hatches at 20K |
| Baby I | Fresh | 0 |
| Baby II | In-Training | 120K |
| Child | Rookie | 600K |
| Adult | Champion | 3M |
| Perfect | Ultimate | 12M |
| Ultimate | Mega | 40M |

Roughly: a first digivolution on day one, Mega in about two months of daily use.

At Mega you can **graduate** your partner into the DigiDex and start a fresh
egg. Two graduated partners can be fused with **Jogress** into a form neither
line reached alone.

## Development

```bash
./scripts/test.sh          # headless checks, including against your real logs
./scripts/build-app.sh     # release build
./scripts/build-app.sh debug
DIGITOKENBAR_OPEN=1 ./build/DigiTokenBar.app/Contents/MacOS/DigiTokenBar
```

`tools/build_index.py` regenerates `Sources/DigiTokenBar/Resources/digidex.json`
from digi-api.com. It bundles **data only** — 1,259 Digimon with stages,
attributes, fields and the evolution graph, about 900 KB. No artwork ships in
the binary, which is why the whole app is around 1.3 MB.

### Layout

```
Sources/DigiTokenBar/
  Core/       log readers, aggregation, pricing — no UI, no Digimon
    Providers/  one file per supported tool
  Digi/       the dex, the care engine, the digivolution graph
  UI/         AppKit views
```

Adding a tool means writing one `UsageProvider` conformance and appending it to
`UsageMonitor`. Nothing outside `Core/Providers` should ever branch on a tool
name.

### Why AppKit rather than SwiftUI

On the macOS 26 SDK, `@State` is an attached macro backed by a `SwiftUIMacros`
plugin that ships only inside full Xcode. Building the UI in AppKit means the
project compiles from a bare Command Line Tools install, with `swiftc` and no
package manager — which is a better story for contributors than a 10 GB
prerequisite.

## Living with it

- **Idle animation.** The partner drifts and breathes, in the menu bar and in the
  popover. Core Animation drives the panel and the pet; the menu bar redraws four
  times a second at whole-pixel offsets.
- **Floating desktop pet.** A borderless, non-activating panel that follows you
  across Spaces. Drag it anywhere, right-click for size (64–192 px) or to hide.
  Clicking it never steals focus from what you were typing.
- **Notifications** when your DigiTama hatches and on every digivolution — the
  payoff usually happens while the popover is closed.
- **Launch at login**, refresh interval, and every toggle above live under the
  gear in the popover footer.

### Artwork clean-up

digi-api paints almost every Digimon on a solid white card, which reads as a
white rectangle on a dark panel. Each image is keyed and trimmed once, on
download, then cached.

The key is a **flood fill from the borders**, not a brightness threshold: only
white that is connected to the edge is removed. A threshold would punch holes
through Angemon's wings and Zurumon's eye highlights, which is exactly the case
`scripts/test.sh` pins.

## Status

Early, but the loop is complete. Working today: both providers, incremental
scanning, the full growth ladder, care-driven branching, the X-Antibody roll,
the DigiDex, idle animation, the floating pet, notifications, and Jogress in the
model layer.

Not built yet: a shop, localisation, per-project breakdowns, and a Jogress UI.

## Credits and disclaimer

Digimon data and artwork come from [digi-api.com](https://digi-api.com).

Digimon is a trademark of Bandai. This is an unofficial, non-commercial fan
project with no affiliation with or endorsement by Bandai, Toei Animation, or
any rights holder. No Digimon artwork is redistributed — images are fetched from
digi-api.com at runtime and cached locally on your own machine.

Inspired by [PokeTokenBar](https://github.com/chattymin/PokeTokenBar) by
chattymin, which had the original idea of turning token spend into something you
raise. The code here is an independent implementation.

Code is MIT licensed. See [LICENSE](LICENSE).
