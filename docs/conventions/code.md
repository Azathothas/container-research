# code.md

Language-agnostic rules. The project adds its own ecosystem conventions beside
these; these hold regardless of the stack.

[`forbidden-patterns.md`](forbidden-patterns.md) is the table of what must never
appear. This is how to construct so it does not.

---

## One read path, one write path

⭐ **Every consumer of a thing goes through the same code.** Every producer goes
through the same code. When you find yourself copying stream, parsing or IO
logic into a second place, stop and extract it instead.

The failure is not theoretical. Copy-pasted logic becomes N divergent copies,
each acquiring different defects, and a fix in one never reaches the others.

The same rule applied to authorization: **one gate per action.** A control
enforced on one path into an operation and not its siblings is the most
recurring hole there is.

---

## Build to last

Four habits. They are about surviving the day reality shifts, which is a
different axis from scope.

**Assume the worst case per feature.** Where a fact is unknown and being wrong
in one direction costs correctness while the other only costs efficiency,
choose the pessimistic reading. You are then right under both.

The worked example: an external service documented its rate limit ambiguously,
per-resource or per-client-per-resource. Budgeting as though the tighter
reading held is correct either way. The optimistic reading is right only if you
are lucky, and wrong in the direction that causes outages.

Ask of every feature: what is the worst input, the worst ordering, the worst
partial failure, the worst concurrent case. Design for that one.

**Fail loud. Never silently corrupt.** ⛔ The worst outcome is not a crash. It
is quietly producing wrong data, or destroying good data.

- **Validate the shape before trusting it.** Headers or a schema, never
  positions.
- **Verify integrity where loss is possible.** A checksum you can check a piece
  against.
- **A guard that detects a mismatch errors the operation.** ⛔ Never pad, never
  guess, never overwrite.

A loud failure is a defect report. A silent corruption is an incident
discovered weeks later.

**Prefer self-describing, versioned formats over positional ones.** Anything
persisted or exchanged carries a version and enough structure to be parsed
unambiguously and evolved. Old data still reads; new code knows which version
it is looking at.

⭐ **Put the thing most likely to change behind a seam** so a format change is
"add a handler" rather than "rewrite the function". A stored thing's identity
is a stable opaque token, never a value re-parsed out of a mutable name.

**Treat redundancy and integrity as features where the failure is expensive.**
A checksum before trusting a restore. A second recovery path. A sweep that
heals drift the happy path let slip. A guard re-checking an invariant the happy
path already knows. These lines earn their keep the one time they fire.

---

## Right-sized, and how it reconciles with the above

These are different axes and you owe both.

- **Right-sized** forbids machinery for **scale or a consumer you do not have**.
  No multi-tenant framework for three users. No plugin system for one plugin.
  No second implementation of a seam that has exactly one.
- **Build to last** forbids constructing things that **break or corrupt when
  reality shifts**. Version the formats. Validate the inputs. Fail loud. Put
  the volatile part behind a seam.

⛔ **The line is sharp.** Minimalism that removes scope you do not need is good
engineering. Minimalism that removes the validation, the version field, the
fail-loud guard or the seam on the volatile thing, to save a few lines, is an
outage you are pre-writing.

The arithmetic settles it: the cost of a few defensive lines is bounded and
known. The cost of a silent corruption when the format shifts is unbounded and
found in production.

⚠ A little dead code kept as a genuine safety margin, a redundancy, a
validation branch, a version discriminator, backward compatibility for old
data, is acceptable and often correct. Cleverness that trims line count at the
cost of correctness-under-change is not.

⭐ **When a request pushes for the brittle-but-short version, push back.** That
is the "never a yes-machine" rule doing its job.

---

## Style, whatever the language

- **Strict typing on**, and no escape hatch without a comment saying why.
- **Typed errors, converted at the boundary.** Never throw a bare string.
  ⛔ Never swallow an error silently: an empty catch needs a comment justifying
  it.
- **No ad-hoc printing in shipped code.** One levelled logger, gated by
  configuration. Errors always logged with a request or operation identifier.
- ⭐ **Comments state constraints and invariants**, never narration. "Must stay
  under 20 MB: the upstream API caps it there" is worth writing. "Now we loop
  over the chunks" is not.
- **Timestamps stored as ISO 8601 UTC**, formatted at the edge. ⚠ A database's
  own "now" function often produces a format that will never string-compare
  against an ISO column, and the comparison silently returns false forever.
- **Identifiers and tokens from a cryptographic random source.** Never a
  timestamp, never a counter, never a weak generator.
- **Binary units where they are binary.** Do not print a value in one unit and
  label it the other.
- ⚠ **Anything consuming structured output selects by name, never by position.**

---

## Testing

Tiers of trust, in this order:

1. **Real deployment.** The actual system, on the actual platform, driven by a
   real client.
2. **Real services.** The genuine dependencies, end to end.
3. **Local integration.** Real components wired together with local stores.
4. **Mocks.** Deterministic doubles, for the faults reality will not produce on
   demand.
5. **Unit tests.** The fast inner loop for pure logic.

The higher tiers catch what the lower ones cannot. The lower tiers give
determinism and speed. Use both and be honest about which one proved what.

Rules that fall out of it:

- ⭐ **Mocks exist for determinism, not convenience.** The real service cannot
  be made to return a specific error, a rate limit or a truncation on demand,
  so a high-fidelity mock with fault injection is the suite's version of that
  dependency. Reality stays the acceptance gate.
- ⛔ **Test the production default of every injectable seam.** A suite where
  every test injects the double leaves exactly one branch untested: the one
  that ships. The worked example: a helper stored on an instance and called
  through the wrong receiver failed only on the real call, so the suite stayed
  green while the real integration was broken for several units of work.
- ⛔ **A test that cannot fail is not evidence.** Mutation-prove the critical
  guards: delete what they protect and confirm they fail.
- **Every defect found later becomes a named regression test.**
- ⚠ **When a negative test passes suspiciously well, doubt the harness before
  the code.** A wrong key returning correct plaintext is not a weak pass, it is
  an impossible one. The thing under test is probably not the thing answering.
- **Test names describe behaviour**, not the function they call.
