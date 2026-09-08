# gate.md

What a unit of work passes before it is done. Three parts, none of them
skippable, with commands actually run and output actually inspected.

⭐ **Each part is blind to the class the other two catch. That is why there are
three and not one.** The suite proves the code. The driven pass proves the
product and the platform. The review proves the composition. Skip one and you
ship the class it owns.

If a part cannot pass, that is a **finding recorded in the handoff**, not a
silent omission. A gate you cannot run is a gate you require setup for, never
one you skip or report as passed.

---

## (a) The automated suites, headless

Typecheck, lint, format, the full test suite, and this unit's own acceptance
checks. Green means green: a pre-existing failure is a debt to fix or to raise,
never a line to wave past.

⭐ **Run it with one command, not from memory.** This part is a LIST, and a
list run by hand is run in the order somebody recalls it. One session ran its
gate five times and typed a different subset each time; nothing failed, and it
was simply not the same gate twice.

```bash
sh scripts/common/check-gate.sh
```

⛔ **A skipped check is reported as a skip, never as a pass**, and the runner
prints that on its own line. A tool that is not installed means nothing about
its subject was verified. `--strict` turns a skip into a failure, which is what
a CI job should pass, because there the tools are installed on purpose and a
skip means the install broke.

Two disciplines that catch what a naive pass count hides:

⛔ **Count the test files the runner reports against the files on disk.** A
green "N passed" beside an error line is a file that never ran. Trust the count
and the exit code, not the passed number. A concurrency-heavy suite can starve
its own workers and skip a file while printing success.

⛔ **Grep yourself for the forbidden patterns** before declaring green. See
[`../conventions/forbidden-patterns.md`](../conventions/forbidden-patterns.md).

⛔ **Read every exit code from the process that produced it, unpiped.** A guard
piped into anything reports the pipeline's status, so a guard that failed reads
as green. [`../conventions/shell.md`](../conventions/shell.md) section 2.

**A green suite proves your code and nothing else.** It is blind to the
platform's real behaviour and to every door a user can reach. That is why it is
necessary and not sufficient.

---

## (b) Drive the real thing yourself

⛔ **For every user-facing change, run the actual system and use it as the real
user would. This is not the operator's job to do for you.**

The reason is specific and repeatedly measured. The **one-gated-door** class of
defect, where a control is enforced on one path and not its siblings, or a
read-only state renders as a live action, is invisible to a green suite and has
been caught only by driving the real thing.

The worked example: a read-only user saw a live upload button in the header and
could drag files onto the window. The server refused every one, so every test
was green and every gate was correct. The user learned their permission by
watching an upload tray fill with errors.

Two more traps a suite structurally cannot see:

- **Composition failures.** Each part correct, the assembly wrong.
- **The centrepiece that is dead code.** Tested, documented logic with no
  reachable caller. You find it by trying to do the thing.

**How, concretely.** Establish a repeatable way to reach the running system
without a password, so the pass is something you run rather than something you
ask for. Assert exact state through the accessibility tree, the DOM, the
network log or the API response, not by looking at it. Only the few things a
human genuinely must do stay with the operator.

⛔ **Deferring the pass to a task for the operator is a failed gate, not a
deferral.** There is one exception and it is narrow: if this harness genuinely
cannot reach the running system at all, that is the capability check firing.
Say so, name what is needed, and get it set up. Shipping anyway, as though the
pass happened, is a failed gate wearing a green badge.

⚠ The distinction matters. Punting a pass you *could* have run is offloading.
Reporting one you *cannot* run is honesty. They are not the same and the
handoff must say which.

---

## (c) The deep reviews

At least three, each asking a **different** question. The full specification,
including the three lenses and what makes a pass real, is
[`reviews.md`](reviews.md).

⭐ **A pass reporting nothing was too shallow**, and [`reviews.md`](reviews.md)
argues that in full. Say what each pass swept, and where one genuinely found
nothing, say what would have had to be true for it to fire.

---

## Before you promise a gate: the capability check

Your harness is not guaranteed to have every capability this methodology
assumes. One session gets a shell and nothing else. Another gets a browser, a
deployment path and a real client. Another is sandboxed with no network at all.

⛔ **Establish what you can actually do before committing to a plan whose gates
you cannot pass.**

| capability | which gate needs it |
| --- | --- |
| run the build, the tests, the application | (a), all of it |
| drive the real running system | (b) |
| deploy, or reach the real environment | (b), and every platform-shaped claim |
| a real client for any protocol the project speaks | (b) for that surface |
| outbound network | reference material, real services |
| credentials | usually the operator's; know which you need |

⚠ **A resuming session re-runs this check for itself.** The session that froze
may have had a browser or a deploy path this one lacks, or the reverse. That
changes what this session can prove, and it is surfaced rather than assumed.

Write the inventory, and any gap that blocks a gate, into the first status
update and into the handoff.

---

## Local is not production

⚠ The runtime you test in does not enforce every policy the deployed platform
does. Crypto limits, header rewrites, permission restrictions, memory ceilings:
a local runtime is routinely more permissive.

The worked example: a password hashing rule specified an iteration count the
deployment platform silently caps far below. Local tests passed for six units
of work while the feature returned a server error in production the whole time.

**The suite proves the code. Only a deployed request proves the platform.**
Anything platform-shaped or security-shaped gets a real-environment checkpoint,
and that checkpoint is part of (b).

---

## What "done" means

All three parts pass, with commands actually run and output actually inspected,
never checked off from memory. Then:

- the record is updated in the same change as the work, not after it;
- the documentation that describes the changed behaviour changes with it;
- the handoff is written, including the driven-pass log and the review findings;
- what the reviews surfaced is **fixed**, not just listed.

⛔ A unit of work whose scope grew during implementation re-passes the gate
against its **new** scope. The gate is against what the work is now, not what it
was this morning.
