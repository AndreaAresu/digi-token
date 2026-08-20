# TODO

What is known to be missing, why it matters, and what it would take. Kept here
rather than in issues so it travels with the code, and ordered by how much of
the loop it closes rather than by how easy it is.

Nothing on this list is a bug. The bugs get fixed; this is the shape of the
thing that is not built yet. Items leave the list when they ship rather than
accumulating a "done" section — git remembers.

---

Nothing outstanding. The three gaps this file opened with have shipped; when
the next one turns up it goes here, in the same shape — what the gap is, why it
matters, what it would take.

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
