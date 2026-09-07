# container-research

What container tooling does in a Linux environment that presents uid 0 with a full
capability set while refusing most of the kernel operations container runtimes are
built on — and a design for a runtime that survives it without lying about what it
provides.

| Path | Contents |
|---|---|
| [`paper_final.md`](paper_final.md) | The paper. Every empirical claim is tagged verified, source-established, or reported-and-unreproducible. |
| [`verification/`](verification/) | The harness that produces the verified claims. `./verification/run.sh` |
| [`verification/real/`](verification/real/) | Evidence captured **on the target runtime itself** (2026-09-07): identity maps, bare census, spawn/interpose matrices, writability map, bwrap differential, pacman.conf, and the lilipod v2 lifecycle run. |
| [`patches/`](patches/) | `lilipod-restricted-v2.diff` — the published chroot adaptation, revised per this corpus's review. |
| [`references/`](references/) | The earlier manuscripts and reviews this work reconciles, unmodified. |

The harness models the studied runtime as two mechanisms that can be switched on
independently — a user namespace with a partial ID map, and a seccomp filter — so
that each observed denial can be attributed to the one that actually causes it.
That separation is what settles the questions the earlier manuscripts disagreed
about. See [`verification/README.md`](verification/README.md).

```sh
./verification/run.sh                       # all sections
./verification/run.sh census bwrap podman   # selected sections
```

Needs `go`, `gcc`, and a running `docker`; sections whose dependencies are missing
print `SKIP`. Captured output from the run the paper cites is in
`verification/results/`.
