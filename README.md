# container-research

What container tooling does in a Linux environment that presents uid 0 with a full
capability set while refusing most of the kernel operations container runtimes are
built on — and a design for a runtime that survives it without lying about what it
provides.

| Path | Contents |
|---|---|
| [`paper_final.md`](paper_final.md) | **The paper.** Every empirical claim is tagged: reproduced here **[V]**, observed on the target **[T]**, established from source **[S]**, or reported-and-unreproducible **[R]**. |
| [`TOOL.md`](TOOL.md) | **The build order for `podbox`**, the runtime the paper specifies. Written for an implementer with no prior context: the language decision, the component specs, the milestone tests, and the reference corpus with verdicts. |
| [`experiments/`](experiments/) | The reconstruction: rebuilds the studied runtime's identity, mount topology and filter in a container on an ordinary host, and **asserts** every attribution row. Also the language comparison and the interpose-tier measurement. |
| [`verification/`](verification/) | The model harness that produces the **[V]** claims. `./verification/run.sh` |
| [`verification/real/`](verification/real/) | Captures from the target runtime itself (2026-09-07) — one session, not repeatable. Everything here is **[T]**. |
| [`patches/`](patches/) | `lilipod-restricted-v2.diff` — a prior Go adaptation. Read for its lessons; `TOOL.md` §3 says why it is not the seed. |
| [`references/`](references/) | The earlier manuscripts this work reconciles, unmodified. |

The runtime is modelled as three mechanisms that can be switched on independently — a
user namespace with a partial ID map, a seccomp filter, and a path-scoped LSM — so
that each observed denial can be attributed to the one that actually causes it. That
separation is what settles the questions the earlier manuscripts disagreed about.

```sh
./verification/run.sh                       # the model harness, all sections
./verification/run.sh census bwrap podman   # selected sections

./experiments/10-build-target-image.sh      # the reconstruction
./experiments/20-enter-target.sh            # a shell inside the reconstructed runtime
./experiments/30-attribution-census.sh      # every attribution row, asserted
```

Needs `go`, `gcc`, and a running `docker`; sections and scripts whose dependencies
are missing print `SKIP` and exit 2 rather than passing. The reconstruction needs a
kernel with Landlock to reproduce the third mechanism, and says so when it does not
have one.
