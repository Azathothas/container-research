# reviews.md

The deep review pass, which is part (c) of [`gate.md`](gate.md).

At least three passes, and ⛔ **they are three different questions, not one
sweep written up three times.** A single pass finds what you were already
looking for. Every recurring defect class in this methodology was found by a
*different* lens than the one that was looking.

---

## The three lenses

### 1. The door sweep

**"What other door reaches this code?"**

Enumerate every affordance the change adds, then list every caller and every
surface that can reach it. Then ⭐ **grep for the ones you did not enumerate.**
The list you wrote from memory has never been complete.

- Check the **guard**, not just the guarded code. An operation that reads one
  resource and writes another needs **two** authorizations.
- Grep an abstraction's **callers** before believing it is load-bearing.
- A gate on one of several paths into the same action is the single most
  recurring hole there is.

⚠ The task list is never the enumeration. It has never once contained them all.

### 2. The guard mutation

**"Can my new guard actually fail?"**

⛔ **Plant the defect the guard exists to catch, and read the exit code
unpiped.** A guard that has never been seen to refuse is a guard nobody knows
works.

The worked example: a scan reported "no orphans" over the exact orphan it
existed to find, twice, because its model of a reader was too narrow. It was
green, it was trusted, and it was theatre.

Two shapes to test for specifically:

- A test whose **name** claims more than it **checks**.
- A check that passes because a different code path happens to satisfy it.

⚠ This lens caught a defect in this template's own probe. A patch script
asserted only that *something* in the file had changed, so it reported success
while the replacement it was written to make had silently not matched.

### 3. The claim audit

**"Which sentence in what I am about to publish is not backed by an artefact I
can point at?"**

Re-read the handoff, the summary and the documentation against the data, the
tree and the live state. This is the pass that catches:

- a number with the wrong denominator;
- a conclusion drawn from a single sample;
- a novelty claim this project already made somewhere else;
- a measurement quoted without its conditions;
- a file a summary claims was written that is not on disk.

⛔ **A summary is a claim like any other.** Yours, or the harness's. "I wrote X,
I deployed Y, the tests pass" is real only once git, the suite or the live
system confirms it.

---

## More than three, when the change earns it

A fourth and fifth are welcome. Two that pay often:

- **"What did I measure but never verify?"** A number taken and never checked
  against a second source.
- **"What did the driven pass show that the suite could not?"** Naturally
  distinct from the door sweep, because it starts from the user rather than
  from the code.

⛔ **What is not acceptable is three headings over one sweep.** Each pass must
be able to name what it looked at that the others did not, and the handoff says
so per pass.

---

## A pass with no findings

⭐ **A pass that reports nothing means that pass was too shallow.**

Three passes reporting nothing is a weaker result than one pass reporting a
real defect. If a pass genuinely found nothing, the handoff says **what would
have had to be true for it to fire.** That sentence is the evidence the pass
happened at all.

---

## The mechanical half is a script's job

Anything a check can assert should be asserted by a check, not by a reading.
Statuses that disagree between two files, counts that no longer add up, a
reference naming nothing, a dead link, a cited path or line that does not
resolve.

⭐ Doing the mechanical half in one second is what leaves time for the half that
needs reading. A record check of this kind has caught things that had been
wrong for a whole session, in under a second, that two humans had read past.

⛔ **What no check can answer is whether a claim is true.** That is lens 3, and
it stays with the reviewer.

---

## What the review owes the record

- The findings, per pass, with which lens found each.
- The change summary: files touched, lines added and removed.
- What was **fixed** as a result. A listed finding that was not fixed says
  where it is now tracked.
- For any pass with no findings, what would have made it fire.
