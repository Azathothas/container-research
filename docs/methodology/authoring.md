# authoring.md

How a rough idea becomes an approved unit of work. This is the front door for
every new piece of work, whatever the project's size and whichever work model
it uses.

⛔ **Authoring and implementing are different sessions.** The hard rule: **do
not write implementation code from an intake.** An intake is a request to plan.
Barrelling into code is the mistake this document exists to prevent.

⚠ A unit written and implemented in one sitting is a unit whose premise was
never checked against the code. Projects routinely carry entries whose titles
are known false for exactly that reason.

---

## The intake

What the operator pastes. Anything blank is yours to propose, with a
recommendation rather than silence.

```text
Title:
Type:            bug | feature | refactor | hardening | polish | chore
What and why:    <the problem or the ask, in your words>
Evidence:        <file and line, a screenshot, an error, a report, a URL>
In scope:        <what IS included>
Out of scope:    <what is explicitly NOT included>
Constraints:     <locked decisions, red lines, must-nots>
Size guess:      <you right-size it>
Already decided: <so you do not re-litigate it>
```

---

## 1. Ground first. Never plan in a vacuum

⛔ **Read the code the idea touches before writing a line about it.** Cite file
and line.

⭐ **Audit against what already exists.** Most asks are a delta. Rebuilding
something the tree already does is the most expensive mistake available, and it
is usually invisible in review. Check the existing work list too: the thing
being proposed may already be filed, or already closed.

⚠ **Use the tool that already exists** rather than the general one. A general
tool used where a purpose-built one exists produces answers that are plausible
and wrong, which is the hardest kind to catch. If the project has an indexed
call graph, a state command, a manual of its own command surface, use those.
Before naming a flag, read the project's own manual rather than guessing: a
guessed flag is a plan that proposes something already existing under another
name.

---

## 2. Measure before building, when the plan describes what the code does

⭐ **This is the rule that pays most often.**

A claim that "X does not work" or "Y is unbounded" is a claim about the
program, and the program is on disk. Two entries in one session recommended
work the code had already made unnecessary, and each took one command to check.

⛔ **A premise a measurement disproves keeps its title and gets the correction
written underneath**, never a silent edit of the premise. The title is how the
work has always been referred to, and rewriting it loses the thread.

---

## 3. Challenge the intake

⭐ **This is where the value is, not in the typing.** Propose the better
approach even when it differs from what was asked, with the reason and the
evidence.

Two failure modes, opposite halves of one mistake:

- **Designing a ceiling.** A hardcoded limit or a single-scale assumption is a
  defect. The question is not "is this too big for our use" but ⭐ **"does this
  design a ceiling?"**
- **Building machinery nothing asked for.** A speculative abstraction is the
  other half. A knob with no caller is not smaller for having been made
  configurable.

Where the intake and the better answer differ, say so, then author the better
one under a stated assumption. Where a genuine fork exists, write it as a
**decision with a recommendation** rather than leaving it open, so the operator
rules on one question instead of reading an essay.

⚠ If a request pushes for a brittle-but-short shape, push back.
[`../conventions/code.md`](../conventions/code.md).

---

## 4. Right-size it

| size | what it looks like |
| --- | --- |
| S | under a day. One flag, one check, one fixture. |
| M | a few days. A new seam, or a measurement needing a fixture built first. |
| L | a week. A subsystem, or something needing a ruling before it is workable. |
| XL | longer. ⚠ Almost always two units pretending to be one. |

⚠ A one-file change is not a unit of work. A "quick feature" touching
authentication or the core write path is.

A unit that cannot start without a ruling is honest about it in its status,
carries its recommendation, and states the question. It is not smaller for
being written as though the ruling had happened.

---

## 5. What every unit carries

- **What it is, and what it is NOT.** The delta in one or two sentences, plus
  explicit non-goals, ⭐ **so scope creep is a visible violation rather than a
  judgement call.**
- **Where the idea came from.** Provenance, not necessarily a path a reader can
  open.
- **What already exists**, audited against the tree, with file and line.
- **The premise**, and how it was checked. ⚠ A premise that was read rather than
  measured says so.
- **Decisions**, the genuine forks, ruled, each with the reasoning.
- **Tasks**, one per coherent deliverable, each with the invariant it must hold,
  the one path it reuses rather than forking, and a **prove**.
- **Checkpoints**, where a task needs verifying before the next depends on it.
- **Pitfalls** specific to this unit, plus the recurring classes it re-enters.
- **The acceptance gate**, all three parts. [`gate.md`](gate.md).
- **Self-review questions** answered honestly in the handoff.
- **The items only the operator can do**, with the exact command or click.
  ⛔ The driven pass is not one of these; the agent does it.

---

## 6. The prove, and why it is the hard part

⛔ **A prove with no command is a paragraph.**

"Verify the source is retried" is not an acceptance. A named check, run, exiting
zero, is.

Three rules the acceptance must satisfy:

1. ⛔ **It waits on the condition, never on a guessed duration**, and never
   asserts that the machine cannot fail some other way. Timing assumptions are
   the single most common cause of a red CI job.
2. ⛔ **"Both of these will happen" is the same assumption as "this will happen
   in N seconds."** A fixture with two sources or two workers that asserts each
   did some work is asserting a scheduling outcome it does not control.
   ⭐ Arrange it instead: make each one the only supplier of something, and wait
   on the condition between stages.
3. ⛔ **A comparative claim needs a committed benchmark.** If the unit claims
   something is faster, smaller or fewer, the acceptance names the script that
   produces the number, and if no such script exists, writing it is part of the
   unit.

⚠ Where the acceptance needs a check that does not exist yet, name it at the
path it will live at, so the project's own reference check can resolve it when
the file arrives.

---

## 7. Get it approved

⛔ **A hard checkpoint. Do not skip it.**

Present the spine: the scope in and out, the decisions each with your
recommendation, the task list with its proves, and the size. Use a structured
question flow for the genuine forks so agreeing to all of it costs no edits.

**Wait for an explicit yes.** ⛔ Do not write the file to disk or start
implementing until approved. On "adjust", revise and re-present.

---

## 8. On approval

1. Write the unit's file, with its accepted status and the date.
2. Update the index or the plan if the sequence changed.
3. Update the record to say what was filed and why.
4. Run the project's own record check, unpiped.
5. ⭐ **Print the kickoff prompt in chat.** Never into a file.
   [`sessions.md`](sessions.md) says what it carries.

**The authoring session ends here.** The operator pastes the kickoff into a
fresh session to implement.

---

## 9. What an authoring session does not do

- ⛔ **It does not implement.**
- ⛔ **It does not close anything as "won't fix", "upstream's problem" or "out
  of scope".** A blocked item stays open with the blocker named and what would
  unblock it. Deferring is only real when there is somewhere to defer to.
- ⛔ **It does not touch anybody else's repository.** A unit whose approach is
  "send this upstream" is a unit that has not been authored yet.
  [`../security/remote-ops.md`](../security/remote-ops.md).

---

## Numbering

- **A full new unit** takes the next integer.
- **A small insert between shipped units**, in stage mode, takes a point
  release, so history stays ordered.
- **A tiny fix** uses the same template, trimmed. ⛔ It still gets the full
  three-part gate and a handoff. Do not skip the driven pass or the reviews
  because it is "just a fix": those are where a fix's blast radius is found.
