# sessions.md

What a session owes at its start and at its end, and how one is resumed when it
did not finish.

⭐ **The governing principle: the conversation is not the source of truth. The
tree, the record and the running system are.** A summary, yours or the
harness's, can claim anything. None of it is real until an artefact confirms it.
Trust artefacts, verify claims.

---

## Starting

1. ⭐ **Read the record first.** It is the one file that always carries what
   changed since last time: the baseline, what the last session did, what is in
   progress, and the work order. Everything session-specific lives there.
2. **Run the probe.** [`../../scripts/doctor/`](../../scripts/doctor/). A
   different machine, a different shell, or a tool that moved changes what this
   session can prove. Run it even on a machine you think you know.
3. **Run the capability check** in [`gate.md`](gate.md). What can this harness
   actually do. A gate the plan needs and this session cannot run is surfaced
   now, not discovered at the end.
4. **Re-measure the baseline** rather than trusting the recorded one. Run the
   checks and read what they say today.
5. **Read what the task routes you to**, per the project's own router. Not
   everything, and not less than the routing table names. ⭐ Where a file is
   named as required reading, **read the bytes, end to end**, and see below.
6. **Restate the plan and its decisions in a few bullets** before touching
   anything. This is not ceremony: it reloads the design into working memory
   and catches a misreading before it becomes a wrong build.
7. **Record the start instant, in ISO 8601 UTC.** Everything at the end that
   measures the session reads it from there.

```bash
date -u +%Y-%m-%dT%H:%M:%SZ
```

8. ⭐ **Write the resume file, before doing any work.** Below.

---

## ⛔ Required reading is read, and the receipt is how anyone can tell

⚠ **Agents skip it and then agree that they skipped it.** The observed shape is
consistent: the file is grepped or skimmed, often described as being read "in
parallel" with doing the work, the session proceeds on what it expected the
file to say, and when challenged it opens with agreement and re-reads. The
agreement costs nothing and the wrong work has already been done.

⭐ **The fix is not a stronger instruction. It is a receipt**, because an
instruction cannot be checked and a receipt can.

**Before acting on required reading, report for each file:** its line count,
and the heading of its last section.

```bash
wc -l FILE && grep -c '^#' FILE && grep '^#' FILE | tail -1
```

⚠ **Both halves matter.** A line count alone is available from a listing. The
last heading is not: reaching it means reaching the end of the file, which is
exactly the part a skim drops.

⛔ **A receipt for a file that was not read is a fabricated measurement**, and
that is a more serious defect than skipping the reading. Say "I did not read
this" instead. That is a normal thing to report and it costs one line.

⚠ **This applies to a bootstrap, an adoption and any session whose prompt names
required reading.** It does not apply to routine work: a routine session reads
what its task routes it to, and the routing table is the contract there.

---

## ⭐ The resume file, written at the START

⛔ **A session that dies does not run its ending.** An agent terminated
unexpectedly mid-task and there was no session log, no progress file and no
resume prompt anywhere. The whole session's work was lost and another session
started it again from nothing.

Everything else in this document is written at the end, which is exactly the
moment an interrupted session never reaches. So one artefact is written at the
**start** and refreshed as the session goes.

`RESUME.md`, beside the record, ⛔ **overwritten every session, never
appended to.** It is a dead man's switch, not a history.

What it carries, and nothing else:

| | |
| --- | --- |
| the task | what this session was asked to do, in one or two lines |
| the resume point | the next thing that has not been done |
| in flight | what is half-done right now, and which files are open in it |
| ⚠ the state of the tree | dirty or clean, and which checks were red when this was last written |
| the paste | a short prompt a fresh session can be given verbatim |

⭐ **Refresh it whenever the answer to "what is in flight" changes**, which is
usually a few times a session. A refresh is a rewrite of five lines and it
costs nothing next to losing the session.

⚠ **It is not the record and it is not the work order.** The record holds
those, is tracked, and is read first anyway. This file exists only so that a
session that ended badly still hands over something.

⚠ **Whether it is committed is the project's decision.** Committed, it survives
a machine going away; ignored, it stays out of the history. Either is fine and
the project's rules say which. ⛔ What is not fine is not having one.

---

## Ending

In this order.

1. **Finish or checkpoint the current task.** A half-finished change is
   recorded as partial, with what is done and what is not, never left silent.
2. **Run the gate.** All three parts. [`gate.md`](gate.md).
3. **Update the record in the same change as the work.** ⛔ The record is part
   of the change, not a report about it. A session that fixes something and
   leaves the record saying it is open has not finished; it has made the next
   session read a lie first.
4. **Update the documentation the work changed**, in the same change.
5. **Write the handoff**, in stage mode, or close the entry with its evidence,
   in todo mode.
6. **Print the summary table.** Below.
7. **Print the next prompt.** Below.
8. **Tear down** anything this session created on a remote system.
   [`../security/remote-ops.md`](../security/remote-ops.md).

---

## The summary table

⛔ **No session ends without one, and it does not depend on the session having
gone well.** A session that ran out of budget after one task still owes it.

It is **for the operator**, and it goes in chat. Prose is not a summary; a wall
of paragraphs is what this rule exists to stop. One markdown table, before and
after, ⛔ **every cell grounded in something you can point at.**

| row | from |
| --- | --- |
| Elapsed | the recorded start instant to now |
| Commits | the git log over this session's range |
| Work | how many assigned items **completed, deferred, failed**. Counted, not described. |
| Changes | files touched, lines added and removed |
| Size | the tree's line count, and the delta |
| Checks | the gate's result, and what it was at the start |
| Cost | if the work spends money or bandwidth, the number, split by what it was spent on |
| Health | debts cleared and introduced, tree clean or dirty, deployed version |

⛔ **It has to be able to say that nothing moved.** A summary that can only
report improvement is fabricated progress with a table around it. "Nothing
moved, and here is what was measured to establish that" is a complete and
honest answer. What is not acceptable is silence, a number with no before, or a
number with no conditions.

⛔ **If you did not measure something, write that you did not.** Never a number
you did not take.

⭐ **Save it as well as printing it**, beside the record, so it survives the
chat scrolling away. The next session reads it as the fastest orientation into
what the last one actually did.

---

## The next prompt

Printed in chat, in a fenced block, ⛔ **never written into a file.**

⚠ **This is not in tension with the resume file above, and the difference is
worth stating because it looks like one.** They are different artefacts with
different lifetimes:

| | the next prompt | ⭐ `RESUME.md` |
| --- | --- | --- |
| written | at a clean end | at the **start**, refreshed as work moves |
| carries | the reading list and the framing for the next unit of work | what is in flight right now |
| lives | in chat | on disk, overwritten each session |
| exists because | a file copy of the work order goes stale | ⛔ a session that dies never reaches its end |

⛔ **Neither one carries the work order.** That is the record's, which is where
it is already correct.

**Which prompt depends on one thing: did this session finish what it was
given?**

| state | print |
| --- | --- |
| finished | the kickoff for the next unit of work |
| not finished, for any reason | ⭐ a **resume** prompt that says what is left and why |
| some done, some not | ⭐ the **resume** prompt. A kickoff printed over unfinished work is how a debt gets silently inherited. |

"Ran out of budget" is a reason. Omitting the prompt is not an option.

### What a kickoff carries, and what it must not

⭐ **It carries a pointer to the record, never a copy of it.**

This is the one place where two defensible practices collide, and the
resolution matters. A prompt that restates the work order is a second copy of
it that goes stale the moment an item closes, and it costs the next session's
budget to read something it is about to read again. But a bare list of paths is
a list that gets skimmed.

Both are true, and they do not actually conflict, because they are about
different things:

- **The reading list is stable**, so it goes in the prompt, ⭐ **with a one-line
  summary of what each file is and why it matters.** A path that says why it
  matters is what gets read.
- **The work order is not stable**, so it stays in the record, which is
  tracked, versioned, and read first anyway.

So the prompt carries only what a reader cannot get from the repository:

- one line on what the project is, because a fresh session has to know that
  before it opens anything;
- what to read, in order, each with its one-line summary;
- whether the session is attended, and what to do when blocked;
- anything the operator has to supply this time;
- any warning carried over from last time.

⛔ It carries **no** item ids, no counts, no check results, no version numbers
and no work order. Those are the record's, which is where they are already
correct.

⚠ Re-rank the reading list for the actual work and add what that work needs.
The list is not boilerplate to copy. It is the session's reading order, and a
wrong order is a wrong session.

### The rework prompt

When the operator's validation fails, they get a prompt listing each issue as
**what I did, what happened, what I expected**, and instructing: reproduce each
one first, fix the root cause with no workarounds, add a regression test per
issue, re-run the full gate, update the handoff.

---

## ⛔ A wall is a routing problem, not a verdict

⛔ **A constraint closes a ROUTE. It does not close the QUESTION.** Confusing
the two is the most expensive mistake available in a session, and it looks like
diligence, which is why forbidding it needs saying rather than implying.

⚠ **This is an incident, not a preference.** A session was told that a runner
has no IPv6 egress, which is true and is not going to change, and stopped: it
recorded the liveness of every IPv6-only host as unknowable. The operator's
answer was that the closed route was one socket, not the question. The project
that came out of it lists five other routes to the same answer, none of which
needs IPv6 from the runner: a public translation gateway, a permitted relay,
correlation with an observer that does have IPv6, evidence from peers, and
checking whether the host is dual-stack after all. ⭐ Told that in writing, the
same session ran for about five more hours, finished the work it had called
impossible, and produced a method that answered several other categories at
once. ⚠ The hours and the outcome are the operator's account of that session,
not a measurement taken here.

**So the standard is: before recording anything as not-doable, name at least
three routes you considered and why each failed.** If you cannot name three,
you have not looked. A route that costs a dependency, a slower path or a
second-hand source is still a route: evaluate it, record the trade, and do not
reject it reflexively.

⛔ **"Blocked" means somebody outside this session must act.** It does not mean
hard, large, slow, unclear, expensive, or easier if somebody decided something.
An unclear item is one you make a defensible call on, record with the rejected
alternatives, and continue.

⚠ **"Unmeasurable" is a statement about what was measured, not permission to
stop.** It is the honest label on the data. It is never the reason an item
closes.

⭐ **A technique that unlocks many items at once is worth more than finishing
any single one, even if you finish none.** Look for the leverage: a method that
answers a class of questions, an instrument that turns a one-off answer into a
standing check, a structural change that makes a class of defect
unrepresentable rather than merely tested for, or a refutation that deletes
work nobody now has to do. When you find one, say so and let it reorder the
work.

### ⛔ Do not write a rule that lobotomises the next session

This applies to what you leave behind as much as to what you do.

⚠ **A limit stated as a fact is inherited as a fact.** "This cannot be
detected", "the polite thing is to identify ourselves", "this is out of scope":
each reads as settled to a session that was not in the room, and each has been
wrong. One of those three was wrong in practice for the opposite reason it was
written: the identifying string it recommended is the one that gets a client
refused.

⭐ **Write the constraint and the evidence, never the conclusion alone.** "No
IPv6 egress from this runner, measured on DATE" is a fact the next session can
route around. "IPv6 liveness cannot be established" is a wall somebody else
built for them.

⚠ **Pivot rather than halt.** A blocker on one item is not a reason to end a
session; it is a reason to work a different one and record on the one you left
what was tried, which routes failed, and what would open it.

---

## Freezing cleanly

⭐ **The best resumption is one the previous session set up.** When a session is
ending, over budget, or interrupted:

1. **Get the tree coherent.** Commit the work in progress, or deliberately
   stash it. ⛔ Never leave a half-edit across the boundary: a broken half-edit
   is worse than nothing, because the next session cannot tell it from
   finished work.
2. **Leave the checks green**, or have the record say exactly which are red and
   why.
3. **Write the partial record** with an honest status and a pointer to the
   resume point, the next unstarted task.
4. **Print the resume prompt.**

---

## Resuming

A unit of work may be picked up by a session with none of the previous one's
context: a fresh session, a summarised history, or a different agent entirely.
The methodology assumes this and never depends on the conversation surviving.

⛔ **Reconstruct from artefacts. Reconcile any mismatch before continuing.**

```bash
git log --oneline -15
```

```bash
git status --short
```

```bash
git diff --stat
```

Then read the record, read the latest handoff end to end, and check the running
system's actual state. Reconcile the three against each other:

| signal | what it means | what to do |
| --- | --- | --- |
| tree clean, checks green, deployment matches the record | a clean stopping point | resume at the next unstarted task |
| the tree has uncommitted work | an edit was mid-flight | read the diff and understand it. Finish it or revert it. ⛔ Never build on work in progress you do not understand. |
| the deployment is **ahead of** the tree | something was deployed and never committed | recover it now. A deployment with no commit cannot be resumed from. |
| the deployment is **behind** the tree | committed, not yet deployed | fine. Note it as pending. |
| the checks are red | the last edit broke something | fix to green first. A session that builds on red compounds the break. |
| a file the summary claims was written is not on disk | the write never landed | redo it. The claim was not real. |

⚠ **Warm and cold resumption differ.** With the conversation still present, you
still verify the durable state, because a summarised turn can drop that a write
failed or a deployment did not land. With the conversation gone, trust nothing
from any prior narrative and rebuild the model entirely from the tree, the
record and the running system.

⚠ **Re-run the capability check for this session.** The session that froze may
have had capabilities this one lacks, or the reverse.

---

## Do not idle

⚠ **Do not end a turn to wait for something.**
[`../conventions/shell.md`](../conventions/shell.md) section 10 says what that
costs and what to do instead.

⛔ **And do not substitute the harness's own scheduler, monitor or wake-up tool
for the wait.** They end the turn by design. A session that finds a foreground
`sleep` blocked and reaches for a built-in that waits has not found a way to
follow this rule; it has found a way to break it that reads like compliance.

⭐ **The best hold has no timer in it.** Block on the work: run the job in the
foreground and let its own output be the tick, or tail its log with the job's
pid so the hold ends when the work does.
[`../conventions/shell.md`](../conventions/shell.md) section 10 has the shapes,
the measured timer alternatives for the case where nothing local can be blocked
on, and the pipeline trap that hangs a turn while looking correct.
