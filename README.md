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
| Baby II | In-Training | 75K |
| Child | Rookie | 300K |
| Adult | Champion | 1M |
| Perfect | Ultimate | 3M |
| Ultimate | Mega | 8M |

Token spend varies by an order of magnitude between plans, so the curve has a
**growth pace** under the gear: *Light use* halves every threshold, *Heavy use*
triples them. The table above is the default.

Reaching Mega is meant to be the *start* of the game, not the end of it — the
collection and Jogress are the long haul.

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

`tools/build_index.py` regenerates `Sources/DigiTokenBar/Resources/digidex.bin`
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
- **Where your tokens went.** Agents record the directory they were working in,
  so the Usage tab breaks spend down by project. Anything touched today is
  highlighted; the rest is muted history.
- **Launch at login**, growth pace, refresh interval, and every toggle above live
  under the gear in the popover footer.

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
the DigiDex, idle animation, the floating pet, notifications, the collection
screen, and Jogress both between your own partners and across tamers.

Not built yet: localisation — see [TODO.md](TODO.md), which also records what
is deliberately not being built.

## The shop

Currency is billable tokens you already spent working, counted from the day you
installed the app. **Nothing costs real money.** Spending never slows your
partner — growth reads its own total, so the shop is a budget, not a tax.

One rule governs the catalogue: **an item is bought before the outcome is known,
never applied in hindsight.** Digivolution is deterministic precisely so that
relaunching the app cannot reroll a result you disliked; an item that clears a
care mistake or skips a rung would be that same trick with a price tag. So there
is no medicine and no rare candy, however traditional both are.

| Item | Price | What it does |
|---|---|---|
| Streak Freeze | 150K | Covers one idle day. Bought ahead, spent automatically, always shown as frozen. |
| Field Compass | 400K | **Guarantees** the next digivolution lands in one Digital World field. |
| X-Antibody Vial | 1.5M | Settles the X-Antibody roll at the next digivolution. |
| DNA Charge | 1M | One Jogress. Three at most, and they refill on their own as you work. |
| Graded DigiTama | 800K | Your next egg carries an affinity, honoured at its first digivolution that can. |

The freeze is the interesting case. Duolingo's works because you buy it *before*
the lapse — it is insurance, not an undo. The honesty is preserved by making it
visible: your streak reads `12d · 2 frozen`, never a bare 12. Softening a
consequence is fine; hiding that it was softened is not.

A **DNA Charge** is what a Jogress costs. One charge per fusion, three at most,
and the meter refills from **billable tokens — never from the clock**: 2.5M of
work per charge. A meter that refilled overnight would be handing out fusions
for waiting, and waiting is the one thing this app has no way to see you do.
Buying one is still buying ahead of an outcome, since the form a fusion produces
is seeded from both partners and is not known when you pay. While the meter is
full it banks nothing, so charges cannot be stockpiled against a spree.

The charge is checked before anything is consumed. A Jogress attempted on an
empty meter leaves your collection exactly as it was — the message says so, and
a test pins it, because losing a graduated partner to a failed fusion would be
the worst bug in the app.

A compass narrows the candidate pool rather than merely weighting it. Buying a
direction and then watching the roll ignore you would be the worst of both
designs. It is only spent when the rung can actually honour it — many early
stages carry no field data, and a purchase should not evaporate on one of them.

## Limits, and what can honestly be said about them

The question this section exists to answer is "how much have I got left", and
the answer differs by tool because what the tools write down differs.

**Codex writes its own rate-limit state onto every turn** — how much of each
window is used, how long the window is, when it rolls over. That is a reading,
so it is shown as a gauge, with the time the tool wrote it whenever that is more
than a couple of hours ago. A percentage from three weeks ago describes three
weeks ago, and says so.

**Claude Code keeps its own copy of what `/usage` reports** — in `~/.claude.json`
under `cachedUsageUtilization`, with the five-hour and weekly windows as
percentages and their reset times. That is the same figure the CLI prints, so it
is a real gauge and still entirely on this machine.

The catch is freshness: the CLI refreshes that cache when it fetches usage, not
on a timer, so a reading can be days old. Each window carries its own
`resets_at`, so an expired one is **not** shown — a five-hour window from a
fortnight ago describes nothing. The section says how old the reading is and
that asking Claude Code for its usage will refresh it, rather than going quiet
and looking broken.

The transcripts carry one further signal: when a limit actually stops a turn,
Claude Code records the window type and when it clears. While such a refusal is
still in force the pane shows it as the full bar it is.

What is offered instead, for both tools, is a **comparison against your own
record**: this window against the busiest window on file, this week against the
busiest week. It is labelled as a high-water mark rather than a limit, because
that is what it is — something that happened, not something you are entitled to.

The alternative was to guess a quota from the plan tier and show a confident
bar against it. Every number in this app is one you can check; a bar against an
invented ceiling is not.

Nothing is fetched over the network for any of this. The documented Anthropic
usage API answers a different question — it reports API-organisation spend and
needs an admin key, not a subscription's rate-limit utilisation — and the
endpoint the CLI itself calls is internal and authenticates as you. Reading the
file the tool already wrote costs nothing and keeps the promise in the footer.

Readings are kept in the scan cache. Scanning is incremental, so a refresh that
finds no new bytes reads no records, and the tool's last reading is still its
last reading. When the cache has never seen one — an app that only just learned
to look — each provider reads the tail of its most recent logs once to catch up.

## The coach

A section in the Usage tab that reads the same events the partner grows on and
says where the money is going. Four rules, each gated on a measurement that is
shown alongside it:

| Rule | Fires when |
|---|---|
| Cache reuse | Under 60% of what you send comes back off the cache. |
| Cache amortisation | Fewer than 2 reads per write, and writes are a quarter of the bill. |
| Session overhead | Median session under 50K billable *and* mostly setup cost. |
| Model mix | One model is over 70% of estimated cost while cheaper configured ones handle under 15% of tokens. |

**No rule fires without its number, and the number is always displayed.** Advice
that cannot point at a figure is a horoscope, and an app that lectures you about
habits it has not measured is worse than one that says nothing. When nothing
fires, the section says so and still shows the basis it judged on.

The report is **per tool**, and its heading names which one — it follows the
same picker as the totals above it. All four rules describe a setup rather than
a person: cache behaviour, session length and which models are in the mix are
configured separately for each agent, so a figure measured on one says nothing
about the other. Pooling them is worse than useless, because the tool used well
masks the one that is not: on the reference machine the combined report is
silent about a second tool re-sending all of its context.

The thresholds were calibrated against real logs rather than picked for
roundness, because the failure mode that matters is nagging someone who is
already working well. The reference profile — 97% cache share, 43× amortisation,
a 336K median session — comes out with everything silent except the model split.
`testCoach` pins that silence so a later retune cannot quietly start crying wolf.

The model rule deliberately stops at reporting the split. Whether a given task
needed the larger model is not in the logs, and the coach does not pretend
otherwise.

It also stops when it cannot price what it is looking at. Costs here are
estimates against published API prices, and a model id the table has never seen
is charged at a fallback rate — fine for a rough total, not fine for a claim
about *which* model is carrying the bill, since a guessed rate on enough tokens
can change the answer. So the coach measures how much of your spend it could not
price, says so when that is more than 1%, and **withholds the model-mix claim
entirely** when it is more than 10% or when the top model itself is the
unpriced one. The other three rules read token counts rather than money and keep
running regardless.

A test asserts that every model id in the real logs on this machine is in the
table. It fails the day a new model ships, which is exactly when you want to
hear about it.

## Tamer cards and Jogress between tamers

A **Tamer Card** is a short string describing you and your current partner:

```
DTB1.eyJhdHRyaWJ1dGUiOiJWYWNjaW5lIiwi….3f2a91c4
```

Copy it, paste it to a friend, and they can Jogress one of *their* graduated
partners with yours. The card is the only thing in this app that ever leaves the
machine, and it leaves only when you copy it yourself. It carries the partner's
identity and a handful of figures worth showing off — no logs, no project names,
no timings, no paths. A test asserts the payload contains nothing else.

There is no account and no server. The transport is whatever you already use to
talk to each other, so the format is built for a chat window: it survives being
wrapped across lines, and a checksum means a truncated paste is *refused* rather
than silently decoding into a different partner.

## Your partners, and fusing two of them

Graduating a partner moves it into **Your partners** on the Tamer tab: sprite,
stage, what it cost to raise, and its whole lineage in the tooltip. It is the
only screen where a retired partner can be looked at, which is the point — weeks
of raising should not end in a counter.

Picking two of them fuses them. Both are spent, the result takes their place,
and it costs a DNA Charge. What they become is **not previewed**: the form is
settled from both seeds at the moment it happens, and showing it first would
turn a choice into a lookup. Every way the fusion can refuse — no charge, no
route, the same partner twice, one no longer held — is checked before anything
is consumed.

Fusing across tamers costs a **DNA Charge** and spends one of your own retired
partners; the visitor is left untouched — their card is a photograph, not a
transfer of custody, and nothing here reaches their machine. The outcome is
seeded from both partners, so re-importing a card is not a way to reroll a form
you did not like.

## The DigiDex

Three states, and the difference between them is deliberate:

- **Met** — full artwork, and clicking opens a card.
- **One step away** — a flattened silhouette. These are the only unmet forms
  whose artwork is fetched.
- **Everything else** — a dashed mark whose image is never requested.

Silhouetting the whole roster would mean pulling 1,259 images from digi-api the
first time the tab is opened (34 MB cached, and 1,259 requests to a free API).
A form you could reach next is a tease; the other thousand are a spoiler. Names
stay visible in every state, so search still works across the roster.

The card shows what the shipped index already knows — stage, attribute, type,
field, X-Antibody, and where the form digivolves to — plus a **rarity** read off
the evolution graph rather than invented:

| Label | Stars | Routes in | Share of roster |
|---|---|---|---|
| Off the graph | ◆ | 0 | 116 |
| Rare | ★★★ | 1–2 | 202 |
| Uncommon | ★★☆ | 3–6 | 279 |
| Common | ★☆☆ | 7+ | 662 |

The exact route count is always printed beside the label, so the claim can be
checked. The stars are a second reading of that same count — they cannot say
anything it does not, and a test pins that they never rise as it rises. They
appear on the card and on met cells in the grid, never under a silhouette:
printing them there would say which of the unmet forms are worth chasing, which
is the one thing the three states exist to withhold.

"Off the graph" means no recorded line digivolves into that form at all — you
meet it through a fallback branch or a Jogress. It gets a diamond rather than a
fourth star on purpose: it is a different claim, not a higher one.

### The X-Antibody is not a rarity tier

It looks like one, so it is worth stating what the data says. Measured across
the shipped index, X forms are **easier** to route to than the roster at large:

| | Median routes in | Share that are Common |
|---|---|---|
| X-Antibody forms (161) | 9 | 62% |
| Whole roster (1,259) | 7 | 53% |

The graph records the X variant as reachable from most of the lines its base
form is, so on that axis it is unremarkable. What makes an X form hard to get is
the **roll at the digivolution**: 1 in 128 at the floor, rising with discipline
to about 1 in 50, or settled outright by a vial. That is a different axis from
the graph, so the stars stay off it and the card prints the odds instead — your
own odds, from your own care profile.

The reference-book text, attacks and release year are fetched from digi-api the
first time a card is opened and cached from then on. They are **not** in
`digidex.bin`: the descriptions alone are 442 KB of prose, which would add 165 KB
compressed to an app that is 756 KB in total. Artwork already works this way, so
the text follows it — you pay for the forms you actually look at.

Sprites are cached as HEIC. Measured across 86 real sprites that averages 28 KB
against 79 KB for the equivalent PNG, so a full roster projects to 34 MB rather
than 94 MB. Alpha survives exactly, which matters: these are cut-outs, and a
format that flattened them would paint the white card back on.

## Screen readers

Everything the app draws rather than writes carries an accessibility label: the
sprites, the stat tiles, the DigiDex cells, the rarity stars, the bars and the
window histogram. Views that are a picture of one fact — a tile, a dex cell, a
graduated partner — fold their children away and speak once, so VoiceOver reads
"Weight, 12, cache-efficient" rather than three unrelated fragments.

`smoke-ui.sh` walks the accessibility tree and fails if any drawn view is
reachable without a label, so a new one cannot quietly arrive mute.

## Attribution and licensing

This project is licensed in two parts, because the code and the Digimon data do
not come from the same place.

**Code** — everything under `Sources/`, `Tests/`, `scripts/` and `tools/` — is
MIT licensed. See [LICENSE](LICENSE).

**Digimon data** — `Sources/DigiTokenBar/Resources/digidex.bin` — is derived
from [digi-api.com](https://digi-api.com), which publishes under
[CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/) and draws mainly
on [Wikimon](https://wikimon.net). That file is therefore **also CC BY-SA 3.0**,
and so is anything derived from it.

*Changes made:* the source records were filtered to the six main evolution
stages, reduced to the fields this app uses (name, stage, attribute, type, field,
evolution edges, skills, English description, image URL), edges pointing outside
the retained set were dropped, and the result was compacted into a single JSON
index. `tools/build_index.py` performs and documents the transformation.

**Artwork** is not covered by either licence and is **not redistributed**. The
CC BY-SA licence covers digi-api's database, not Bandai's images — Wikimon hosts
those under its own fair-use rationale. This app ships no artwork: it fetches
each image at runtime and caches it on the end user's own machine.

### Disclaimer

Digimon and Digital Monsters are trademarks of Bandai. This is an **unofficial,
non-commercial fan project** with no affiliation with, sponsorship by, or
endorsement from Bandai, Bandai Namco, Toei Animation, or any other rights
holder.

Inspired by [PokeTokenBar](https://github.com/chattymin/PokeTokenBar) by
chattymin, which had the original idea of turning token spend into something you
raise. The code here is an independent implementation.
