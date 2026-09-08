# work-stages.md

The stage model. Work is a numbered sequence; each unit has a plan written
before it starts and a handoff written when it ends.

[`choosing-a-work-model.md`](choosing-a-work-model.md) says when this is the
right shape. [`authoring.md`](authoring.md) says how a plan is written.
[`work-todo.md`](work-todo.md) is the other model.

---

## The shape

```
plans/
  ROADMAP.md              the locked decisions, the architecture in brief,
                          the stage table with status
  stage-TEMPLATE.md       the skeleton every plan is authored from
  stage-01-<slug>.md      one per unit. Normative: decisions and proves,
  stage-02-<slug>.md      not narration.
  executions/
    HANDOFF-stage-01.md   one per completed unit. The durable memory.
    HANDOFF-stage-02.md
```

⭐ **This scales because each plan file is self-contained and consumed one at a
time.** The implementing session never holds the whole project in context. It
reads the technical reference, the conventions, the one plan file and the
latest handoff. That is why a three-stage project and a thirty-stage one run an
identical lifecycle, and why a fresh session can pick up any single stage
without having lived through the other twenty-nine.

⛔ **Do not read all the plan files at once.** They are written to be consumed
one at a time, and reading ahead costs budget for a design that may change.

---

## A plan file is normative

It encodes decisions and proves. ⚠ It is not a narrative of how the thinking
went. Match the density of a specification, not of a design document.

Its status flips from draft to accepted only after the operator signs off, and
the accepted version carries the date.

---

## The handoff

Every unit ends with one, written for the **next** session, which may be a
different context with none of this one's memory.

⭐ **The governing principle: the conversation is not the source of truth. The
tree, the handoff and the running system are.** A summary can claim "I wrote X,
I deployed Y, the tests pass". None of it is real until an artefact confirms it.

What a handoff carries:

| section | what goes in it |
| --- | --- |
| Status | complete, or partial with a pointer to the resume point |
| ⭐ Operator items, at the top | the only things this unit needs a human for |
| What was built | with file and line |
| The gate's results | the actual commands and their trimmed output, including the file count against disk |
| ⭐ The driven-pass log | what you actually did with the running system, and what it showed |
| ⭐ The review findings | per lens, with what was fixed |
| The change summary | files touched, lines added and removed |
| Deviations | what differed from the plan, and why |
| Known gaps | and where each is now tracked |
| Self-review | answered honestly |
| ⭐ **How to verify the current state from scratch** | the exact commands a cold session runs to confirm everything still works |

⛔ **A handoff missing the driven-pass or the review findings is incomplete.**
Those are gate parts, not colour.

⭐ **The verify-from-scratch section is what pays for the whole file.** It is
the runbook a resuming session runs verbatim, which is why it is not optional.

---

## Numbering

- A full new unit takes the next integer.
- ⭐ **A small insert between shipped units takes a point release**, so history
  stays ordered rather than being renumbered.
- A tiny fix uses the same template, trimmed, with its own handoff and the full
  gate.

⚠ **When you start arguing about the number, the sequence has stopped carrying
information.** That is the signal to migrate to the todo model. See
[`choosing-a-work-model.md`](choosing-a-work-model.md).

---

## Multi-phase units

A unit large enough to ship in phases gets a handoff **per phase** and a
kickoff per phase, because the boundaries between phases are session boundaries
too.

⚠ Do not let phasing become a way to avoid re-scoping. If phase two turns out
to be a different unit of work, it is one.

---

## What the record still owes

⚠ Even in stage mode, ⭐ **one file is what a session reads first**, and it is
not the plan file. Something has to answer "where am I, and what is next"
without reading every handoff.

Keep a short status at the top of the roadmap, or a record file beside it,
carrying: the current unit, its status, the baseline as last measured, and what
the last session left. The handoffs are the history; this is the pointer.

⛔ **Do not put the work order in the kickoff prompt.** A prompt that restates
it is a second copy that goes stale the moment a unit closes.
[`sessions.md`](sessions.md).
