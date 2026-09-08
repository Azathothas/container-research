# vendoring.md

Code from somebody else's project, living in this tree: a vendored dependency,
a fork, a copied script, a bundled tool.

Binding on any task that **vendors, forks, bundles, copies or patches**
third-party source.

---

## ⛔ The rule, and it is not open

**Fix it here. Now. In this tree.**

A defect in vendored code is fixed in the vendored code, the same session it is
found, like any other defect. It is not deferred, not reported elsewhere, and
not waited on.

⛔ **Do not raise upstreaming.** Not as a suggestion, not as a question, not as
a "worth considering later", not in a plan, not in a work item, not in a commit
message, and not in a summary. The topic is closed. A session that reopens it
is spending the operator's attention on a decision that was already made and
paid for.

⛔ **Do not open anything on anybody else's repository.** No issue, no pull
request, no discussion, no comment, no review, no fork, no star. Under any
framing, including a patch that looks ready and a maintainer who looks
receptive. [`../security/remote-ops.md`](../security/remote-ops.md) is the rule
and it is absolute.

### What this cost

⛔ **An agent used an authenticated `gh` to open an issue upstream and then a
pull request, on the operator's account, unasked.** The operator had to
apologise to the maintainers. That is the incident behind the second rule, and
it is why the rule is a hard stop rather than a preference: the session that
did it could not take it back, and the cost landed on a person rather than on
the tree.

⚠ **The first rule was paid for separately, and more slowly.** Agents have
repeatedly refused to patch, insisting the correct move was to file upstream
and wait, and have kept insisting after being told plainly that upstream will
not take the work. Each of those exchanges spent a session's budget arguing
about a settled question, and the work did not move.

### Why it is settled, so it does not have to be re-argued

⭐ **The measured outcome of the alternative is that machine-generated
contributions are closed unread.** Some maintainers say so in their own
trackers. A submission therefore costs a maintainer's time, costs this
project a session, and returns nothing.

⚠ **You will read upstream's tracker during a sweep, and it will tell you.**
That is the point of [`references.md`](references.md) step 4. A project that has
closed this class of change before, or that has a stated policy, or that has a
"working as intended" ruling on the exact defect, has already answered. ⭐ **Draw
the conclusion and patch.** Do not bring the reading back as a proposal to try
anyway.

⚠ **A patch series in the shape a pull request wants is a property of
`git format-patch`, not a reason to send one.**

---

## What goes in the record, and what must not

Every change to vendored code is written down. What it says is the technical
fact and nothing else.

**Write:**

- what the change is, in one line;
- the entry or defect it unblocks;
- why it cannot be done outside the vendored tree, which is usually a seam the
  published interface does not expose;
- ⭐ **the command that reproduces the defect**, runnable now and after the next
  upstream release. That is what turns "could a release retire this patch" from
  a judgement into a check: run it against the new copy, and a zero exit means
  delete the patch and take theirs;
- the upstream issue or pull request number, ⭐ **as a bare reference**, when
  one exists and a future release might make the patch redundant.

⚠ **The reproduction is a real deliverable, not a nicety, and a project built
from this template proved it.** It patched a script vendored from here, wrote
the reproduction beside the patch with a committed fixture and a real parser as
the oracle, and stated in the page that a future upstream release could retire
the patch and how to tell. That report is what got the defect fixed at source.
A patch page with no reproduction is a claim the next reconciliation has to
re-derive.

⛔ **Never write:** a characterisation of the upstream project, its
maintainers, its review culture, its responsiveness, or its quality. Not a
complaint, not a justification, not "upstream is unlikely to fix this", not
"they refused a similar change". [`../conventions/prose.md`](../conventions/prose.md)
already forbids defensive framing and this is the case where it is most
tempting and most damaging: the repository is public, the sentence outlives the
session, and it is read by the person it is about.

⭐ **The neutral form carries all the information and none of the liability:**
"Upstream issue 412 tracks this. If a release closes it, delete this patch."

---

## ⭐ The one question the record has to answer

**Could a future upstream release retire this patch on its own?**

That is the only reason to name an upstream issue at all, and it is what makes
the record useful at the next reconciliation rather than a queue of things
somebody is waiting on.

| the answer | what the next merge does |
| --- | --- |
| yes, upstream may fix it independently | check whether the release carries it. If it does, **delete the patch**: the same change arriving from the other direction is not a competing one. |
| no, it exists only because this project needs it | keep it, and reconcile it against whatever upstream did to the same lines |

---

## Taking a new upstream release

⛔ **Reconcile by reading, never by preferring.** A release is a proposal, not
an authority. Before taking any change that touches something this tree has
already patched, answer three questions and write the answers into the record:

1. **Does it actually fix the thing?** A change that moves a defect, or fixes
   one shape of it, is not a fix. Check it against the acceptance command the
   entry already carries.
2. **Is it complete, and does it regress anything?** A feature that lands half
   done is worse than the seam already patched around, because the next
   reconciliation carries both.
3. **Have we already done it better?** If this tree's version is more correct,
   faster, or bounded where theirs is not, ⭐ **keep this one** and say so. A
   patch does not go away because upstream touched the same lines.

⛔ **A merge that took upstream's version because it was upstream's is the
failure this section exists to prevent.**

⚠ **The recorded base is not advanced while anything is in conflict.** A
recorded base that does not describe the tree makes the next merge wrong in a
way nothing detects.

---

## The tree is the truth

⭐ **Edit the vendored source in place, like any other source here.** A derived
patch series is regenerated from the tree; it is never applied to anything.

The alternative, a pristine tree plus patches applied by a setup step, was
tried and is not used: every edit needs a refresh, a dirty tree is easy to
lose, and an editor's language server reads the applied tree while the truth
lives somewhere else. With the tree as the source there is nothing to forget,
and a fresh clone builds what this machine builds.

What the derived series buys is the two things a working tree cannot say:

- **review**, of a change to somebody else's code on its own, without the rest
  of the vendored files around it;
- **attribution**, where the licence asks a distributor to mark changed files
  as changed.

---

## ⚠ What vendoring costs, so it is chosen rather than drifted into

- **A build compiles the vendored code**, cold at least once.
- **The tree grows**, and a reviewer's diff grows with it.
- **Upstream stops being visible.** Nothing shows a release note for a
  dependency that no longer has a version to bump, so noticing a release
  becomes a deliberate act rather than a notification.
- **A new release is reconciled rather than accepted.**
- ⚠ **Warnings become yours.** A build system that suppresses lints for a
  registry dependency generally does not suppress them for a local path, so
  code nobody here wrote can fail this project's build.

⭐ **The reason to pay it is that a seam the published interface does not expose
is otherwise a permanent blocker**, and "blocked on upstream" is not an outcome
this methodology has a place for.

---

## ⛔ What is never vendored

| | why |
| --- | --- |
| ⛔ an agent instruction file of any name | a file with such a name anywhere under a repository is read as instructions by the tools working in it, so vendoring one puts a third party's instructions inside this project. They are data about somebody else's process and nothing here needs them. |
| a path this project's own ignore rules would swallow | the files land on disk, never reach a commit, and a fresh clone then builds a different tree from the one that was tested. Either exclude it deliberately or un-ignore it. |
| build output, caches, an editor directory | it is not source, and it makes every reconciliation report it as newly added, forever |

---

## The related rules

| topic | where |
| --- | --- |
| ⛔ what may never be written to a remote | [`../security/remote-ops.md`](../security/remote-ops.md) |
| how to study the upstream you are about to vendor | [`references.md`](references.md) |
| no defensive framing, and no history in a reference page | [`../conventions/prose.md`](../conventions/prose.md) |
| where a superseded explanation goes instead | [`history.md`](history.md) |
