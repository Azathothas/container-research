# history.md

Where the story goes, so it stops being written into the pages that answer
questions.

---

## ⭐ The problem this solves

⛔ **An agent working from this template wrote the project's history into every
document it touched.** Each reference page acquired what had been tried, what
had been believed, which session changed its mind, and why. Nothing was untrue.
The result was unreadable, and a reader looking for one fact had to walk
through a narrative to reach it.

⚠ **The instinct behind it is right, which is why forbidding it does not
work.** A superseded explanation genuinely is worth keeping: it is often the
only record of why a design has its shape, and a session that cannot find it
re-derives it wrongly. [`../conventions/prose.md`](../conventions/prose.md)
already says a superseded rule is moved and never dropped. What it did not say
is **where to**, so it went into the page it was superseding.

⭐ **Two independent projects built from this template invented the same
answer within days of each other**, one at `docs/history/` and one at
`HISTORY/`, with almost the same rules written on the front of each. That is
the evidence for putting it in the template: it is not a preference, it is the
thing adopters keep having to build.

---

## Where it lives

```
docs/history/
  README.md      what is here, and one line on each file
  <topic>.md     the superseded wording, kept verbatim
  references/    what sweeps of other projects found
  reviews/       what each deep review swept, and what it did not
```

⚠ **Under `docs/`, not at the repository root.** The root holds code, tooling
and the entry documents. A capitalised prose directory sitting beside the
source puts prose and code at the same level, and a project that started that
way moved it here deliberately.

---

## The rules on the directory

⛔ **Append, never edit.** A premise a later measurement disproves **keeps its
wording**, and the correction is written underneath it. This is not politeness
about the past: a silently corrected document teaches nobody, and the reader
who needs this directory is the one about to make the same mistake.

⛔ **Moved, not summarised.** A superseded passage arrives here in its original
words. A summary of a retired explanation is a new document about an old one,
and it loses the detail that made it worth keeping.

⛔ **It is not the work order.** The record is, and it is the only file that
carries one. A history page that starts being consulted for "what next" is a
second work order going stale.

⚠ **It is not the changelog either.** The changelog says what shipped and when.
This says what was believed and why that changed.

---

## What belongs here

| | |
| --- | --- |
| a **superseded explanation**, with the measurement that took it away | the main case |
| a **decision that was reversed**, kept verbatim so reversing it back is a restore rather than a rewrite | |
| a **dead end**, with what it cost, so nobody spends that again | |
| a **reference sweep**: what was read, at which commit, what transfers | [`references.md`](references.md) |
| a **deep review**: what it swept, what it found, and what it did not look at | [`reviews.md`](reviews.md) |
| a **session record**, where a session is worth a record at all | [`sessions.md`](sessions.md) |

## ⛔ What does not

| | why |
| --- | --- |
| the current answer to anything | it belongs in the page that answers that question. Two homes, and the reader gets the wrong one. |
| the work order | the record owns it |
| a rule anybody is still expected to follow | if it is live, it is not history |
| a complaint about a person or a project | [`../conventions/prose.md`](../conventions/prose.md), and [`vendoring.md`](vendoring.md) for the vendored case |

---

## ⭐ The test, for a passage you are not sure about

**Does a reader need this to use the thing correctly today?**

- **Yes**: it is a constraint, and it stays on the reference page. "Two lints
  exist because another tool will refuse the file" is a constraint.
- **No**: it is history. "The allocator takes a write lock now" is history.

⚠ That is the same test [`../conventions/prose.md`](../conventions/prose.md)
applies under "what a document is not". This page is where the second answer
goes.

---

## The one thing to put on the front page

⭐ **A list of the claims this project has published and later withdrawn.**

A reader who trusts a document without checking that list trusts sentences that
are wrong. One project keeping this list ended up with five entries, and the
fifth was a correction to the fourth. ⚠ Notice what that costs to catch: the
first four were caught by a review or a later measurement, and the fifth needed
**the same control run a second time**.

That is the argument for [`reviews.md`](reviews.md), and for repeating a
diagnosis before publishing it, in one sentence each.

---

## ⚠ It does not exempt itself from the prose rules

The character set, the marker density and the banned vocabulary apply here as
everywhere. `scripts/common/check-markers.sh` reads this directory like any
other.

⭐ What is exempt is **one fact one home**: a superseded page states things the
live pages now state differently, on purpose. A project whose checks enforce
one-fact-one-home mechanically excludes this directory from that rule alone,
and says so in the check rather than in a comment nobody reads.
