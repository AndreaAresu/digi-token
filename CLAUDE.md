# DigiTokenBar — project instructions

A macOS menu bar app that raises a Digimon on the tokens you spend in Claude Code
and Codex. Read `README.md` for what it does and why it is Digimon rather than
Pokémon; this file is only the rules that always apply.

## Build and test

There is **no SwiftPM**. `swift build` does not work on a machine with only the
Command Line Tools installed: CLT ships `BuildServerProtocol.framework` outside
the rpath its own `swift-package` binary searches, and SIP strips the `DYLD_`
override that would fix it. Everything goes through `swiftc` directly.

```bash
./scripts/build-app.sh          # release .app
./scripts/build-app.sh debug
./scripts/test.sh               # headless checks, incl. against real local logs
```

Run both before calling any change done. `test.sh` compiles `Core/` + `Digi/`
only — it must stay free of anything that needs a running `NSApplication`.

## The UI is AppKit, and stays AppKit

On the macOS 26 SDK `@State` is an attached macro backed by a `SwiftUIMacros`
plugin that ships only inside full Xcode. Using SwiftUI would make a 10 GB Xcode
install a hard prerequisite for every contributor. Do not reintroduce SwiftUI,
even for one view. `@Observable` happens to work (ObservationMacros *is* in CLT),
but the stores use plain `onChange` callbacks so nothing depends on a macro.

## Layering

```
Core/   log reading, aggregation, pricing. Knows nothing about Digimon or views.
Digi/   dex, care engine, digivolution. Knows nothing about views.
UI/     AppKit only.
```

Adding a tool means one `UsageProvider` conformance in `Core/Providers/` plus an
entry in `UsageMonitor.init`. **Never** branch on a provider name outside
`Core/Providers/` — not in aggregation, not in the care engine, not in the UI.

## Things that are load-bearing, not incidental

- **Digivolution is deterministic** given seed + current form + care profile.
  Relaunching must never reroll an outcome. Any change that introduces
  unseeded randomness into `Digivolution` is a bug.
- **The evolution graph is canon, not gameplay-complete.** Many forms have no
  recorded route to the next rung. `Digivolution.next` has a fallback chain
  (field → attribute → stage) so nothing dead-ends. Keep it, and keep the test
  that sweeps Child forms for strandings.
- **Growth runs on `billable` tokens**, never `total`. Cache reads are excluded
  so the app cannot reward wasting money.
- **`ScanCache` retains events for 120 days** and folds older ones into a
  `UsageArchive`. All-time totals, active days and session counts must keep
  spanning the archive. Never go back to storing every event forever.
- **Persisted models decode field by field, by hand.** Swift's synthesized
  decoder calls `decode` for every non-optional property and ignores its default
  value, so adding one field makes every existing save undecodable — and a store
  that reads that as "no save" destroys a partner someone raised for weeks. This
  already happened once, to a real partner. `Partner`, `UsageArchive` and
  `ScanCache.FileState` therefore have hand-written `init(from:)` using
  `decodeIfPresent`, and `PartnerStore` copies an unreadable save aside before
  starting over. Any new persisted type must do the same, and
  `testSaveCompatibility` must keep passing.
- **No artwork ships in the binary.** `digidex.bin` is data only (deflated JSON). Images are
  fetched from digi-api.com at runtime and cached per user, as HEIC. The DigiDex
  grid must not fetch artwork for the roster at large — that is both a bandwidth
  fix and the intended game feel. The one exception is forms exactly one
  digivolution from something the tamer has met, which are shown as flattened
  silhouettes; do not widen it. Reference-book text follows the same rule and is
  fetched only when a card is actually opened.

## Calibration changes need evidence

The care engine's numbers were tuned against real logs, not guessed. Two
mistakes already found and fixed, both of which passed a naive reading:

1. Counting idle days over *all* history made a brand-new partner hatch with 30
   care mistakes. Neglect is now judged over a 14-day window with a 4-day grace.
2. Letting neglect alone drive the alignment score made a sporadic-but-efficient
   tamer read as Virus. Virus now needs a second signal (night work or a
   context-heavy style) to win; absence of signal reads Free.

If you retune anything in `CareEngine`, add a test that pins the *behaviour* you
intend, and check it against the real profile the app computes on this machine —
not just against synthetic fixtures.

## Legal posture

Unofficial, non-commercial fan project. Bandai owns Digimon. Do not add bundled
Digimon assets, do not describe the project as official or endorsed, and keep the
disclaimer in `README.md` and `LICENSE` intact.
