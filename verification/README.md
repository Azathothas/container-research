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

The target runtime is modelled out of **three independent mechanisms**, which can
be switched on separately. That separation is the point of the harness: a
denial observed under two of them tells you nothing about which one caused it.

| Mechanism | `confine` flag | What it is |
|---|---|---|
| **N** — user namespace | `CONFINE_USERNS=1` | a uid/gid map with a single entry; `/proc/self/setgroups` = `deny`; optionally an unmapped supplementary group (`CONFINE_EXTRA_GROUP=42`). `CONFINE_MAP_HOSTID=1000` maps `0 -> 1000` as the target does; `CONFINE_MOUNTNS=1` adds a mount namespace owned by that user namespace, without which `may_mount()` fails and `fsopen`/`fsmount` return `EPERM`. |
| **F** — seccomp filter | `CONFINE_SECCOMP=1` | `SECCOMP_SET_MODE_FILTER` + `PR_SET_NO_NEW_PRIVS`, inherited across `execve`, denying `unshare`, `setns`, `mount`, `umount2`, `pivot_root`, `ptrace`, and with `CONFINE_DENY_PROCESS_VM=1` also `process_vm_readv`/`writev` |
| **M** — path-scoped LSM | `CONFINE_LANDLOCK=/tmp:/dev/shm:...` | a Landlock ruleset handling the filesystem write rights and granting them only beneath the listed paths. Reads stay unrestricted; every mount-topology operation is denied, because landlock's `sb_mount`/`move_mount` hooks refuse whenever any filesystem right is handled. Needs `CONFIG_SECURITY_LANDLOCK`; `confine` refuses loudly when the kernel has none. |

Individual denials can be added or removed — `CONFINE_ALLOW_UNSHARE`,
`CONFINE_ALLOW_MOUNT`, `CONFINE_ALLOW_PTRACE`, `CONFINE_DENY_CLONE_NS`,
`CONFINE_DENY_SETGROUPS`, `CONFINE_DENY_MKNOD`, `CONFINE_DENY_CHOWN_NONZERO`,
`CONFINE_DENY_SETUID_NONZERO` — which is how each ambiguous error is attributed
to the syscall that actually produced it.

To compose the target's own shape in one go, use
[`../experiments/`](../experiments/), which also builds the filesystem topology
and asserts the result.

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
- `probe/` — the operation census (`probe census`), the bogus-argument
  attribution probes (`probe attribute`) and the Go spawn matrix (`probe spawn`).
  Every check that would mutate the caller runs in a freshly forked child.
  `probe check <name>` exits 1 on a denial and **2 when a precondition is
  missing**, so a parent that reads the exit code gets the operation's verdict
  and "could not run" never reads as "denied".
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


## Target-run evidence (`real/`)

The `results/` directory holds captures from the *model* run. `real/` holds captures
from the **target runtime itself** (2026-09-07), where the bare probes run directly:
no confine layer is possible there (confine's own setup needs `setgroups` and an
unshare-style spawn, both denied on the target — see `real/lilipod-stock.txt` for the
equivalent wall in lilipod). What `real/` establishes: the ID maps (`identity.txt`),
the full bare census (`probe-census.txt`, `cprobe.txt`), the spawn and interposition
matrices (`spawn.txt`, `interpose.txt`), the path-scoped write policy
(`writability.txt`), the bwrap differential (`bwrap.txt`), the runimage pacman
configuration (`pacman-conf.txt`), the `/tmp` capacity vs payload fact
(`tmp-enospc.txt`), and the lilipod v2 lifecycle (`lilipod-v2-lifecycle.txt`).

### Three verdict bugs, fixed, with their artefacts

The captures under `real/` predate these fixes and are kept as they were taken.

1. `mount(MS_SLAVE,/) in clone(NEWNS)` reported the child's **exit code**, and the
   child exited 0 regardless of the mount verdict — the row said `OK` directly
   above the grandchild's `FAIL errno=1 EPERM` line. `check` now exits non-zero on
   failure, so the row reports `FAIL exit status 1` where the mount is denied.
   `real/probe-census.txt` still shows the pre-fix `OK`.
2. The chown probes and the compiled C probe both used `/tmp/cprobe`, so running
   the census truncated the C probe to an empty mode-0644 file and the next
   invocation reported `Permission denied`. That is the entire content of
   `real/cprobe.txt`, which therefore **establishes nothing**. The chown target is
   now `/tmp/chown-probe-target`.
3. `write into uid-1000-owned dir` needs a fixture only a process that can `chown`
   can build; when it was absent the probe reported the resulting `ENOENT` as
   though it were a denial. It now reports `SKIP` with the reason.

One capture is mislabelled rather than wrong: `real/lookpath.txt`'s first block is
headed "chroot into an image rootfs" but the target had no docker, so the rootfs was
empty and the block duplicates the second. The §5.5 result comes from the model run
in `results/lookpath.txt`, where the two blocks differ as intended.

## Extended corpus evidence (`real/ext*.txt`, second target session 2026-09-07)

Seven further tools were fetched, built where buildable, and tested at their
claims on the target itself; plus a kernel-feature survey of the surfaces those
tools depend on:

| File | Establishes |
|---|---|
| `extkernel-newapi.txt` | filter-vs-LSM separation by bogus-argument probes; `process_vm_*` added to F's deny list; the new mount API split (fsopen/fsmount/open_tree/mount_setattr OK, `move_mount` EPERM traced to `security_move_mount`, i.e. M — inside a clone(NEWNS) child too); detached mounts creatable but not openable (EACCES); seccomp user-notification + `ADDFD` fd injection works; `/proc/<pid>/mem` read-only works, read-write denied (M) |
| `extkernel-sources.txt` | the v6.18.39 kernel excerpts those attributions rest on: `fsmount`/`move_mount` both start with `may_mount()`; `vfs_move_mount` calls `security_move_mount()`; `do_move_mount` has zero `EPERM` sites; Landlock's v6.18 hook list includes `move_mount`/`sb_mount`/`sb_pivotroot`/`file_open`/`path_*` |
| `ext-udocker.txt` | udocker 1.3.17: pull/create work (ownership-neutral tar by design); P1/P2 dead at ptrace (F); **F1 fakechroot works unpatched** (`--user=0` to clear the no-passwd remap); apk/curl/htop end-to-end in alpine; debian glibc runs, dpkg unpack trips interposer coverage; R1 hangs |
| `ext-dockless.txt` | docker-CLI shim over udocker: installer/guardrails/fail-fast work as documented; engine dead (PRoot/ptrace) and hook contract dead (chown 999 EINVAL, mknod EPERM) |
| `ext-rurima-ruri.txt` | rurima pull dies at the §9.1 unmapped-gid wall (`tar -xpf` as root); `rurima r` works; **ruri 3.9.5 works unpatched** (per-mount warnings, unshare probed-then-refused, apk+curl end-to-end; /dev/null regular-file trap; no resolv.conf install) |
| `ext-treesandbox.txt` | dead before any namespace call (`getpwuid(0)` KeyError, missing `/etc/hostname`); its layer tree is unshare+mount based — F denies both; no fallback path in code |
| `ext-sandlock.txt` | Landlock+seccomp+resource-limit tiers work unpatched; every notif feature that reads child memory degrades — COW/`--dry-run` **fail open with a false "no changes" report**, network ACL fails closed, `--chroot` exec fails (memory writes denied) |
| `ext-pathshim.txt` | `pathshim probe` -> `passthrough` with reason `EPERM` (its `process_vm_readv` leg is F-filtered; `/proc/pid/mem` write leg M-denied); degradation honest, command never retried in another mode |
