# experiments.md

Running your own measurements: the script that takes them, where it lives, and
what a result owes.

⚠ **Not the same job as [`references.md`](references.md).** That is studying
somebody else's code and it owes provenance for work you did not do. This is
producing your own numbers and it owes a command somebody else can re-run. A
project doing real work usually needs both, which is why they are two files.

---

## ⭐ An experiment is a file, not a transcript

⛔ **A measurement that lives only in a session transcript is re-derived every
time somebody wants it.** The number is quoted, the conditions are not, and
nobody can tell whether the difference between two runs is the change or the
machine.

So every measurement worth quoting is taken by a **script in the tree**:

```
experiments/
  10-probe-the-host.sh
  20-build-the-thing.sh
  30-measure-it.sh
  README.md
```

⭐ **Numbered, in the order they were run.** The number is the sequence, not a
priority. A reader landing on `30-` knows two things ran first and can find
them. Two projects built from this template arrived at exactly this layout
independently.

⚠ **A number is not reused when an experiment is replaced.** The old script
stays and the new one gets the next number, because a citation of `30-` in a
write-up has to keep meaning what it meant.

---

## What an experiment script owes

| | |
| --- | --- |
| **a header saying what question it answers** | not what it does. The question is what tells a later session whether it still needs asking. |
| **every input pinned** | a version, a tag, a commit, an image digest. An experiment against `latest` measures a different thing each week and says so nowhere. |
| **the conditions printed on the way out** | host, tool versions, date, sample count, input size |
| **an exit code that means something** | 0 the measurement ran, 1 it ran and the thing failed, 2 it could not run |
| **no dependence on the directory it runs from** | resolve paths from the script's own location |

⛔ **It does not clean up its own output.** The evidence is the point. A script
that deletes what it measured is the mining failure in another costume.

---

## ⛔ A negative result is a result, and it gets committed

**"We tried this and it did not work" is one of the most valuable things this
directory produces**, and it is the thing sessions quietly drop because it does
not look like progress.

Commit it, with the same conditions block as a success. The next session that
has the same idea reads it and moves on, which is the entire return.

⚠ **A dead end with no record is re-attempted.** That is not a hypothetical
cost: it is the ordinary outcome, and it is paid by whoever has the idea next.

---

## ⛔ The rules on a number

Each of these is in [`../conventions/prose.md`](../conventions/prose.md) and
each is broken most often here, where the numbers are actually produced.

- ⛔ **Never a fabricated number.** A dash where the value is unknown.
- ⚠ **A measurement carries its conditions.**
  [`../conventions/prose.md`](../conventions/prose.md) states what that means
  and why an unconditioned rate is worse than no rate at all. Here it is
  concrete: the script prints them, so they cannot be forgotten later.
- ⛔ **Measured, or labelled, never estimated.** An estimate is allowed and it
  is labelled as one, in the same sentence, every time it appears.
- ⚠ **A correlation is not a cause.** Naming a culprit is a claim, and a claim
  needs a control that isolates it.

### ⭐ Run the control twice before you publish the cause

⛔ **One project published eight explanations for one slow operation, one at a
time, and withdrew every one.** The ninth was found only when somebody re-ran
the single control the previous answer rested on and it did not reproduce.

⚠ **A control run once is a coincidence you have not noticed yet.** The cost of
running it again is minutes. The cost of not running it again is a document set
built on it, and everything downstream having to be withdrawn together.

---

## Where the results go

| | |
| --- | --- |
| **the number a reader needs today** | the page that answers that question, once. One fact, one home. |
| **the run that produced it** | the history directory. [`history.md`](history.md). |
| **the script** | `experiments/`, tracked, forever |
| **a withdrawn explanation** | ⛔ the history directory, in its original wording, with the measurement that took it away underneath |

⚠ **Do not write the story into the reference page.** "The allocator takes a
write lock now" is history. "This is measured on one machine and not on your
hardware" is a constraint and it stays.

---

## ⭐ Measure from outside the thing you are measuring

⛔ **A subject's self-report is not a measurement.** Asking a program what it
did, and believing it, is the commonest way a whole set of numbers turns out to
describe nothing. Build the small independent observer instead: a capture
server, a proxy, a counter in the layer below, a reader of the artefact rather
than of the log that claims to describe it.

⚠ **Then check whether observing changed the answer.** A probe that had to
relax one setting to see anything **changed what it was watching**, so the
value it captured was not the value the subject ships. The fix was to capture
that one field passively and write the reason beside the command. ⭐ Ask this
of every instrument you build; it is not an exotic case.

⭐ **Give the instrument an expectation flag and a non-zero exit.** A probe that
can assert becomes a regression check the project keeps, which is the whole
difference between a measurement that decays and one that holds. That is also
how a research artefact stops being a document and becomes a gate.

⚠ **Pick a metric that is stable under changes you do not care about.** A
number that moves for irrelevant reasons trains everybody to ignore it, and
then it cannot report the change that matters.

[`references.md`](references.md) section 5 has the worked example, because a
sweep of somebody else's code has exactly the same obligation.

---

## ⚠ What an experiment cannot tell you

- **That it generalises.** One machine on one day is one machine on one day.
  Say which machine, in the same sentence as the number.
- **That the thing you changed is the thing that mattered**, without a control
  that holds everything else still.
- **That an absence is a zero.** A probe that found nothing may have been
  looking in the wrong place, and the two are distinguishable only by a
  positive control that the probe does find.
