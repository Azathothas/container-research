# work-todo.md

The todo model. Work is a set of entries in an index; one record file carries
the baseline and the work order and is rewritten every session.

[`choosing-a-work-model.md`](choosing-a-work-model.md) says when this is the
right shape. [`authoring.md`](authoring.md) says how an entry is written.
[`work-stages.md`](work-stages.md) is the other model.

---

## The shape

```
TODO/
  PROGRESS.md       ⭐ the record. What the last session did, the measured
                    baseline, and the work order. Rewritten every session,
                    carries no history.
  INDEX.md          every entry, one line each, sorted by id, with the counts
                    and the argument behind the current ordering.
  RULES.md          how this repository is worked on, rule by rule.
  <category>.md     the entries themselves, grouped by area.
```

⭐ **The split is deliberate and it is the model's whole design.**

| file | answers | carries history? |
| --- | --- | --- |
| `PROGRESS.md` | where am I, what is next | no. Rewritten each time. |
| `INDEX.md` | what exists, and how much of it | no. It is a list, not a log. |
| the entry | what this one item is, and how it closes | yes, including corrections |

⛔ **The work order lives in `PROGRESS.md` and nowhere else.** Not in the index,
which carries the list rather than the order. Not in the kickoff prompt, which
would be a second copy going stale the moment an entry closes.

---

## An entry

Authored per [`authoring.md`](authoring.md). Its fields are not decoration:

- **Source.** Where the idea came from. ⚠ Provenance, not a path a reader must
  be able to open. "The operator", "found while measuring T-184", or a citation.
- **Category, priority, effort, status**, as the index defines them.
- **Problem.** What is wrong, in terms of what a user or a script sees.
- **Premise.** What is believed, and how it was checked. ⚠ A premise that was
  read rather than measured says so.
- **Approach.** What to do, with the seam named at file and line.
- **Decision.** Where a fork exists, with a recommendation and the reason the
  alternative lost.
- ⭐ **Prove.** The acceptance, and it is a command.

An entry closes **in place**, with its acceptance command actually run and the
output recorded.

⛔ **A disproved premise keeps its title**, per
[`authoring.md`](authoring.md), and gets the correction
written underneath.** Never a silent edit of the premise. The title is how the
entry has always been referred to.

---

## The counts have to agree with the rows

⭐ **This is the model's one mechanical hazard and it is worth automating.**

Closing one entry moves several numbers: the index's total line, the open and
done figures beside it, one row of the priority table, that row's total, the
overall row, and the record's own count lines.

⛔ **Do not do that arithmetic by hand.** Two scripts, and both:

- **A writer** that moves a status and re-derives every count from the rows.
- **A reader** that asserts, independently, that the counts agree with the
  rows, that no status disagrees between the index and the entry, that no row
  names a missing entry and no entry lacks a row, that every reference resolves,
  and that every cited path and line exists.

⭐ **The reader runs as a gate.** A count that disagrees with the rows then
cannot reach a commit.

**What it cost to learn.** A session closed two high-priority entries, wrote it
into the entries, the index and the record, and pushed. It then rewrote a
fourth file and never pushed again. The published state said those entries were
open, beside entries saying done, for the whole of the next session. Nothing was
wrong with any single file. What was missing was anything that compared two of
them.

⚠ **A file that quotes a number another file measures has to be checkable.**
Write it as a fixed line the checker already parses rather than as prose that
reads better. The prose version is the one that goes stale silently.

---

## The record is part of the change

⛔ **`PROGRESS.md`, `INDEX.md` and the entry are edited in the same change as
the work, never after it.**

A session that fixes something and leaves the record saying it is open has not
finished the change. It has made the next session read a lie first.

---

## No deferral

⛔ **Nothing closes as "won't fix", "upstream's problem" or "out of scope".**

A blocked item stays open with the blocker named and what would unblock it.

⚠ **"It is in somebody else's code" is a reason to look at why you cannot
change it, not a place to send the work.** Deferring is only real when there is
somewhere to defer to. Leaving a residual bound is allowed only when it is
measured, named with a file and a line, and carried as its own open entry.

---

## Priorities and effort

Define them once, in the index, and mean them:

| priority | means |
| --- | --- |
| P0 | breaks correctness, loses data, or takes the process down |
| P1 | a documented capability does not work, or a flag does nothing |
| P2 | worth doing; nothing is wrong without it |
| P3 | worth recording so it is not rediscovered |

Effort as in [`authoring.md`](authoring.md): S under a day, M a few days, L a
week, XL almost always two entries pretending to be one.

⭐ **The ordering is derived, and the argument that produced it is written
down** in the index. That is what makes it possible to re-derive rather than
re-argue.

---

## What replaces the handoff

The entry itself carries the closure evidence, so there is no per-item handoff.
What still has to exist at every session boundary:

- ⭐ **`PROGRESS.md` rewritten**, carrying the state line with the start
  instant, the measured baseline, the counts, what this session did, what is in
  progress, the work order, and open questions for the operator.
- **The summary table**, in chat and saved.
- **The next prompt**, in chat only.

[`sessions.md`](sessions.md) is the full specification of all three.

⚠ Because the record carries no history, the history is the git log and the
entries. Do not add a "previous sessions" section to it; that is the drift this
model avoids.
