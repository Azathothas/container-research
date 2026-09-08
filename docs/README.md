# docs/ — the methodology this repository is worked under

⛔ **These files are binding, not advisory.** A session that works on this
repository or on `podbox` follows them. They are copied **verbatim** from
[`Azathothas/TEMPLATE`](https://github.com/Azathothas/TEMPLATE) `docs/` so that
this tree is self-contained: a reader with no network and no access to that
repository can still work under the same rules.

They are the reason this corpus is checkable rather than a pile of assertions,
and every one of them exists because something was paid for once already.

| file | binding on |
|---|---|
| [`methodology/references.md`](methodology/references.md) | any task whose verb is **clone, mine, survey or investigate** — how to study somebody else's project, and what a sweep owes |
| [`methodology/experiments.md`](methodology/experiments.md) | any task that produces a **number** — the script in the tree, the pinned inputs, the conditions, the negative result |
| [`methodology/vendoring.md`](methodology/vendoring.md) | any task that **vendors, forks, bundles, copies or patches** third-party source |
| [`methodology/work-todo.md`](methodology/work-todo.md) | the work model: `TODO/INDEX.md`, `TODO/PROGRESS.md`, `TODO/RULES.md`, entries per category |
| [`methodology/authoring.md`](methodology/authoring.md) | how a single entry is written |
| [`methodology/choosing-a-work-model.md`](methodology/choosing-a-work-model.md) | todo model versus stages model, and when each is right |
| [`methodology/work-stages.md`](methodology/work-stages.md) | the other work model, for comparison |
| [`methodology/sessions.md`](methodology/sessions.md) | what a session owes at its boundary: the record, the summary table, the next prompt |
| [`methodology/reviews.md`](methodology/reviews.md) | how a review is run and what it must not become |
| [`methodology/gate.md`](methodology/gate.md) | what must pass before a commit |
| [`methodology/history.md`](methodology/history.md) | where a superseded explanation goes instead of into a reference page |
| [`conventions/prose.md`](conventions/prose.md) | ⛔ no defensive framing, no narrative, the rules on a number |
| [`conventions/code.md`](conventions/code.md) | code conventions |
| [`conventions/forbidden-patterns.md`](conventions/forbidden-patterns.md) | patterns that do not reach a commit |
| [`conventions/shell.md`](conventions/shell.md) | shell conventions |
| [`security/remote-ops.md`](security/remote-ops.md) | ⛔ what may never be written to a remote. Absolute. |

## The four that decide everything else

If a session reads only four, these:

1. **`references.md`** — three reading passes minimum, each asking a different
   question; read the **tracker**, not only the code; **keep the corpus**; every
   reference gets exactly one verdict (adopt / confirms / anti-pattern exhibit /
   filed elsewhere / refused); and *adopt mechanisms, cited at file and line,
   never architectures*.
2. **`experiments.md`** — a measurement that lives only in a transcript is
   re-derived every time; **a negative result is a result and gets committed**;
   measure from **outside** the thing being measured; give the instrument an
   expectation flag and a non-zero exit so it becomes a gate.
3. **`vendoring.md`** — **fix it here, now, in this tree.** Never open anything
   on anybody else's repository. Never write a characterisation of an upstream
   project or its maintainers. Every patch carries the command that reproduces
   the defect it fixes.
4. **`work-todo.md`** — the work order lives in `PROGRESS.md` and nowhere else;
   an entry closes **in place** with its acceptance command actually run;
   **nothing closes as "won't fix" or "out of scope"**; the counts are checked
   by a script, never by hand.

## Local adaptations

Two, both additive. Neither weakens anything above.

- **`[V]` / `[T]` / `[S]` / `[R]`.** `paper_final.md`'s evidence tags are this
  project's application of `experiments.md`'s conditions rule. `[V]` means a
  reader can run it; `[T]` means one observation of a machine they cannot reach.
  They are not interchangeable and the distinction is enforced in review.
- **Resource and liveness guards.** `experiments.md` requires a meaningful exit
  code; this project additionally requires that a script never blocks on input
  and never runs unbounded. See `TOOL.md` §11.3.

## Upstream

Copied on 2026-09-08 from `Azathothas/TEMPLATE`, `main`. To take a newer
revision, re-fetch and reconcile per `methodology/vendoring.md` — by reading,
never by preferring.
