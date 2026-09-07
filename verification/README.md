# Verification harness

Everything empirical in [`../paper_final.md`](../paper_final.md) is produced by
`./run.sh`. Results from the run that the paper cites are checked in under
`results/`.

```sh
./run.sh                       # all sections
./run.sh census bwrap podman   # selected sections
```

Requires `go`, `gcc` and a running `docker`; sections whose dependencies are
missing print `SKIP` and the rest continue. `dockerd` may need starting by hand.

## What it does

The target runtime is modelled out of **two independent mechanisms**, which can
be switched on separately. That separation is the point of the harness: a
denial observed under both tells you nothing about which one caused it.

| Mechanism | `confine` flag | What it is |
|---|---|---|
| User namespace | `CONFINE_USERNS=1` | uid/gid maps covering only `0 -> 0`; `/proc/self/setgroups` = `deny`; optionally holding an unmapped supplementary group (`CONFINE_EXTRA_GROUP=42`) |
| Seccomp filter | `CONFINE_SECCOMP=1` | `SECCOMP_SET_MODE_FILTER` + `PR_SET_NO_NEW_PRIVS`, inherited across `execve`, denying `unshare`, `setns`, `mount`, `umount2`, `pivot_root`, `ptrace` |

Individual denials can be added or removed — `CONFINE_ALLOW_UNSHARE`,
`CONFINE_ALLOW_MOUNT`, `CONFINE_ALLOW_PTRACE`, `CONFINE_DENY_CLONE_NS`,
`CONFINE_DENY_SETGROUPS`, `CONFINE_DENY_MKNOD`, `CONFINE_DENY_CHOWN_NONZERO`,
`CONFINE_DENY_SETUID_NONZERO` — which is how each ambiguous error is attributed
to the syscall that actually produced it.

## Sections

| Section | Question it answers |
|---|---|
| `census` | Which mechanism produces which row of the runtime table |
| `spawn` | Which `SysProcAttr` shapes make Go's `os/exec` call `setgroups` |
| `bwrap` | Does bubblewrap's message distinguish a refused clone from a refused mount |
| `tar` | Does GNU tar's ownership failure need a filter rule, or just an unmapped gid |
| `libarchive` | What `-20` in `short write: -20 != N` is, and what errno underlies it |
| `lilipod` | Is stock lilipod's failure one wall or two, and which syscall causes it |
| `podman` | How far podman gets, and what actually stops it |
| `interpose` | Whether `LD_PRELOAD` reaches Go's `lchown` (with and without cgo) |
| `lookpath` | How Go resolves program paths across a `chroot` |
| `sources` | The upstream source lines the paper's claims rest on |
| `arithmetic` | Unit and size conversions |

## Components

- `confine/` — the model runtime described above.
- `probe/` — the operation census and the Go spawn matrix. Every check that
  would mutate the caller runs in a freshly forked child.
- `cprobe/` — a single-threaded C probe. Go cannot probe
  `unshare(CLONE_NEWUSER)`: the kernel refuses it for any multithreaded process
  with `EINVAL` regardless of policy, so a Go verdict on that flag is an
  artifact of the prober.
- `libarchive/short_write.c` — calls `archive_write_data` into a full
  filesystem through the same option set dwarfs' extractor uses.
- `interpose/shim.c` — an `LD_PRELOAD` interposer on `chown`/`lchown`/`open`.

## Limits

The model reproduces the reported runtime's observable behaviour; it is not
that runtime. It cannot confirm the reported wall-clock timings, the lilipod
patch (never published), the runimage payload, or the onelf bundle. Where the
paper relies on those, it says so.
