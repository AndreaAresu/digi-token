# TODO

What is known to be missing, why it matters, and what it would take. Kept here
rather than in issues so it travels with the code, and ordered by how much of
the loop it closes rather than by how easy it is.

Nothing on this list is a bug. The bugs get fixed; this is the shape of the
thing that is not built yet. Items leave the list when they ship rather than
accumulating a "done" section — git remembers.

---

## 1. No accessibility labels anywhere

**The gap.** `grep -r "setAccessibility" Sources/` returns nothing. An app whose
content is sprites and 7–9pt text is exactly the one a screen reader cannot
read: DigiDex cells are unnamed images, `StatTile` is a number with no context,
`RarityStars` is a row of mute `NSImageView`s (the tooltip serves a mouse, not
VoiceOver).

**What it would take.** `setAccessibilityLabel` on `SpriteView`, `DexCell`,
`StatTile` and `RarityStars` — on the order of thirty lines. The strings already
exist as tooltips in most cases.

This is the only item here that is about someone who cannot use the app today.

## 2. The pricing table fails silently

**The gap.** `ModelPricing.rate(for:)` matches the model id by substring and
falls back to a Sonnet-shaped rate when nothing matches — without telling
anyone. The coach then builds its strongest claim on that number: *"claude-opus-5
is 85% of estimated cost"*. A model id the table has never seen would be priced
as Sonnet, and with enough volume that can change **which** model comes out on
top. The coach would be wrong with a straight face.

**What it would take.** Two things, both in the grain of the project:

- a test asserting every model id in the real logs on this machine matches a
  table pattern — it fails the day a new model ships, which is exactly when you
  want to hear about it;
- a marker in the coach's card when some share of the cost was estimated with
  the fallback rate.

The rule here is that every claim shows its number. This is the crack underneath
one of those numbers.

---

## Not doing, and why

**More coach rules.** The four that exist were calibrated against real logs and
the calibration is documented. A fifth added on intuition is how an app starts
lecturing someone who is already working well.

**Localisation.** Declared missing in the README, and last on the list. Without
full Xcode the `.lproj` bundles are assembled by hand, the strings are inline
throughout, and half the copy in this app is prose written to be read — the
translation is more work than it looks and unlocks nothing for the person
running it.

**Sync between machines.** The app reads local logs and sends nothing anywhere.
A server would trade the one property that makes it comfortable to run.
