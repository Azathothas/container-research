# choosing-a-work-model.md

Two ways to track work. Pick one at bootstrap, delete the other, and delete
this file once the choice is made.

---

## The two

**Stage.** Work is a sequence of numbered units. Each has its own plan file
written before it starts, each ends with a handoff, and the handoff is the
durable memory between sessions. Order is the numbering.
[`work-stages.md`](work-stages.md).

**Todo.** Work is a set of entries in an index. Each has an id, a priority, a
status and its own acceptance command. One record file carries the baseline and
the work order and is rewritten every session. Order is derived and can be
re-derived. [`work-todo.md`](work-todo.md).

---

## The rule

⭐ **Stage fits a build. Todo fits a backlog.**

**Stage, when nothing exists yet and the work is inherently dependency-ordered.**
The first ten units are strictly sequential because each makes the next layer
possible. There is no meaningful re-prioritisation: you cannot do unit seven
before unit three. Each unit delivers a coherent slice, and the question
"what is the state of the system now" has a per-unit answer worth writing down.
That per-unit handoff is the model's whole value.

**Todo, when a tree already exists and the work is a set of independent items.**
Defects, features and cleanups that could be done in many orders. The valuable
operation is not "what is next in the sequence" but "what matters most now",
and that means one sortable list with counts, re-orderable without renumbering
anything. A per-item handoff would be noise; the entry itself carries its
closure evidence.

---

## The transition, which is the part usually missed

⭐ **Most projects are both, in that order.** Stages until the thing exists,
then todo forever after.

A project that starts greenfield reaches a point where the build is done and
the work becomes a backlog. Continuing to number stages past that point
produces the failure this section exists to warn about: a growing pile of plan
files whose ordering is implicit in their numbers, where inserting work between
two shipped units needs a decimal, and where the answer to "what should I do
next" is spread across the most recent few handoffs instead of being written
anywhere.

⚠ **The signal that it is time is when you start arguing about the number.**
When a new unit is a decimal insert, or when the sequence no longer reflects
what matters most, the sequence has stopped carrying information.

**How to migrate**, and it is cheap because the two models agree on everything
that matters:

1. Create the index and the record from
   [`../templates/`](../templates/).
2. Turn every open item, every known gap, and every deferred finding from the
   existing handoffs into an entry with an id, a priority and an acceptance
   command.
3. Keep the shipped plan files and handoffs where they are. They are the
   history and they are still the evidence; nothing rewrites them.
4. The record's work order replaces the next-stage kickoff.

Nothing about the gate, the reviews, the session rules or the conventions
changes. Only the shape of the record does.

---

## What does not decide it

⚠ **Not project size.** A three-unit build and a thirty-unit build run the same
stage lifecycle, because each unit is planned and consumed one at a time and
the implementing session never holds the whole project in context. Size is not
the axis.

⚠ **Not how well-specified the goal is.** A sharply specified goal can still be
a backlog of independent items, and a vague one can still be a strictly ordered
build. What decides it is whether the work has a forced order.

⚠ **Not which one you used last time.**

---

## When it is genuinely between the two

Ask three questions. Two or more "yes" answers point at stage.

1. **Does unit two depend on unit one existing?** If most of the work is like
   that, the order is not a choice and a sequence is the honest shape.
2. **Does the system's state change enough per unit that a cold session would
   need a written description of it?** If yes, that is a handoff, and handoffs
   are the stage model.
3. **Is there nothing to prioritise, because there is only one path?** If yes,
   an index of priorities has nothing to hold.

If the answers are mixed, ⭐ **start with stage and plan to migrate.** Migrating
from stage to todo is mechanical, described above, and cheap. Going the other
way means inventing a dependency order after the fact for work that was filed
without one, which is neither.

---

## What both models share

Everything except the record's shape. Do not treat the choice as bigger than it
is:

- the three-part gate, [`gate.md`](gate.md);
- the three review lenses, [`reviews.md`](reviews.md);
- what a session owes, [`sessions.md`](sessions.md);
- how a rough idea becomes an approved unit of work, [`authoring.md`](authoring.md);
- every convention and every security rule.

⭐ **Both are authored in one session and implemented in another.** That is not
a property of either model; it is the rule that makes both of them work. See
[`authoring.md`](authoring.md).
