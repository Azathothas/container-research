# Containers in a Restricted Runtime

### Attributing container-tool failures to unmapped IDs and denied mounts, and a design for a runtime that degrades honestly

**2026-09-07**

---

## Abstract

A class of Linux environments — agent sandboxes, hardened CI executors, locked-down
HPC login nodes — presents a process with uid 0 and a full capability set while
refusing most of the kernel operations container runtimes are built on. We
characterize one such runtime and evaluate four container tools against it:
**lilipod**, **Podman**, **Apptainer** and **runimage**. A second session on the
same runtime class extends the corpus to seven further tools — udocker, dockless,
rurima, ruri, treesandbox, sandlock and pathshim — and sharpens the mechanism
model with the new mount API and seccomp user-notification surfaces (§3.7a, §11a).

The central finding is one of attribution. The runtime is not "a seccomp filter that
denies namespaces". It is **two mechanisms with different signatures**: a user
namespace whose ID maps cover almost nothing, and a seccomp filter that denies a
short list of syscalls. Separating them explains failures that neither mechanism
explains alone, and it inverts two conclusions that a single-mechanism reading
produces. `clone(2)` with `CLONE_NEWNS` is *not* denied — only `unshare(2)` and
`mount(2)` are, so a process can hold a private mount namespace and still be unable
to mount anything in it. And the `EINVAL` that stops GNU tar, Apptainer's Go
unpacker and containers/storage's layer applier alike is not a filter rule at all: it
is `chown` to a **gid that is not mapped in the current user namespace**.

Every empirical claim below is reproduced by a harness (`verification/`) that models
the runtime from those two mechanisms and switches each independently. Under that
model we reproduce the reported identity block byte for byte, including
`groups=0,65534` and a capability mask with more bits than the host root process
holds; lilipod's image ID `ff727edbcbe60df2bd6a89cf65d6db2b`; GNU tar's exact
ownership failure; `apk-tools 3.0.6-r0` running from an image rootfs entered by
`chroot`; and a full Arch Linux userspace installing signed packages from live
repositories — once two preconditions that no prior account identified are met.

We close with an implementable specification (§10) for a runtime that probes the
operations it needs rather than the privileges that usually imply them, reports the
mode it actually achieved, and never presents path virtualization as isolation.

**Evidence convention.** Every claim is tagged: **[V]** verified by the harness in
this document; **[S]** established by reading a named upstream source at a named
revision; **[R]** reported from the original experiment record and *not* reproducible
here. Section 3.6 says exactly what [R] covers and why.

---

## 1. Introduction

The container stack assumes a set of kernel affordances: user and mount namespaces,
`mount(2)`/`pivot_root(2)`, `/dev/fuse` for the FUSE-based alternatives, and the
ability to change process credentials. When an environment withholds them, tools
fail — but they fail with errors that misdirect, because the errors surface at the
libc or language-runtime boundary, several layers above the kernel decision.

Two properties of such an environment make diagnosis unusually treacherous:

1. **The process looks maximally privileged.** It is uid 0 with every capability bit
   set. Nothing in `id` or `/proc/self/status` suggests a restriction, so denials
   read as bugs.
2. **Two different mechanisms produce overlapping symptoms.** A seccomp filter and a
   user namespace with a narrow ID map both return `EPERM` and `EINVAL` from
   operations a privileged process expects to succeed. Attributing a denial to the
   wrong one leads to fixes that cannot work and to conclusions that invert.

This paper does the attribution. Section 3 characterizes the runtime as a
two-mechanism model and shows which mechanism produces which denial. Sections 5–8
walk each tool to its actual wall. Section 9 collects the four walls that recur
across every tool. Section 10 turns them into a specification.

**Scope.** In this environment the security boundary is *outside* the process under
study. "Container" here means a disposable, image-derived userspace, not an
isolation boundary. None of the working configurations in this paper add isolation,
and §10 is explicit that they must never be presented as if they do. `chroot(2)`
requires `CAP_SYS_CHROOT` and is not a sandbox.

---

## 2. Summary of findings

| # | Finding | Evidence |
|---|---|---|
| F1 | The runtime is a **user namespace with a partial ID map** *plus* a seccomp filter. The namespace alone accounts for the `mount`, `mknod`, `setuid`, `setgroups` and `chown` denials and for the unwritable directories; the filter is needed only for `unshare`, `ptrace`, and `mount` inside a namespace the process owns. | [V] §3.3 |
| F2 | `clone(2)` with `CLONE_NEWNS` **succeeds**. The resource these tools cannot get is not the namespace, it is the mount. | [V] §3.4, §8.1 |
| F3 | The `EINVAL` wall shared by GNU tar, Apptainer and containers/storage is `chown`/`lchown` to an **unmapped gid**, not a filter rule. It reproduces with no filter installed at all. | [V] §9.1 |
| F4 | Go's `os/exec` calls `setgroups` in the child for a non-nil `Credential` unless `NoSetGroups` is set. This one field, not dropping `Credential`, is the correct fix. | [V][S] §9.2 |
| F5 | Stock lilipod at uid 0 fails **once**, in `EnsureFakeRoot`'s re-exec, and the cause is `setgroups` — reproducible with the namespace alone, no filter involved. | [V][S] §5 |
| F6 | Podman's default overlay driver fails at `mount(2)`, but `--storage-driver vfs` **initializes successfully**. Its real wall is layer application, which peels back through `unshare` → `mount` → the same unmapped-gid `lchown`. | [V] §6 |
| F7 | `-20` in dwarfs' `short write: -20 != N` is libarchive's `ARCHIVE_WARN`, not an errno; the underlying `archive_errno` is `ENOSPC` (28). Reproduced through the same API and option set. | [V][S] §8.2 |
| F8 | A libc `LD_PRELOAD` shim cannot see Go's `lchown` — **with or without cgo**. Go's `os` package issues it as a direct syscall. | [V] §9.3 |
| F9 | A real Arch rootfs entered by plain `chroot` installs **signed** packages from live repositories under this runtime, but only after (a) disabling pacman's `DownloadUser`, which chowns to an unmapped uid, and (b) initializing the keyring. Neither precondition appears in any prior account. | [V] §8.3 |
| F10 | `/etc/mtab` is **not** required by pacman. It is read only when `CheckSpace` is enabled, which Arch's shipped `pacman.conf` leaves commented out. | [V] §8.3 |
| F11 | Several probes in common use are non-discriminating: `mknod(S_IFCHR, 0)` creates a whiteout and never tests `CAP_MKNOD`; `unshare(CLONE_NEWUSER)` from any Go program returns `EINVAL` regardless of policy. | [V] §3.5 |
| F12 | onelf refuses a bundle symlink whose target is **absolute** or climbs above the package root. A relative target that stays inside the bundle is accepted even when it dangles. | [S] §8.4 |
| F13 | The new mount API splits cleanly: `fsopen`/`fsmount`/`open_tree(CLONE)`/`mount_setattr` are permitted (so `may_mount()` provably passes), while `move_mount` attach is denied by the **LSM M** (`security_move_mount`), not by the filter — it returns `ENOENT` for a bogus destination, which seccomp cannot produce. Detached mounts are creatable but not openable (`openat` on them → `EACCES`). | [V] §3.7a |
| F14 | The filter also denies `process_vm_readv`/`process_vm_writev` (EPERM for a bogus pid, which the kernel would answer `ESRCH`); `ptrace(2)`, `process_vm_*` are all F, while `pidfd_getfd`/`process_madvise`/`kcmp` execute. But **`/proc/<pid>/mem` of a child opens read-only and reads correctly**, and seccomp user-notification with `SECCOMP_IOCTL_NOTIF_ADDFD` fd injection works. A notif-supervisor tier is therefore viable if it reads arguments via `/proc/<pid>/mem`. | [V] §3.7a |
| F15 | Unpatched third-party tools now span the §10 mode ladder: **udocker 1.3.17's F1 fakechroot engine runs containers** (pull → apk install → curl HTTPS, all in-image) via libc interposition, and **ruri 3.9.5 runs a chroot container** with per-mount failure warnings and a probed refusal of unshare mode. Of the rest: sandlock's Landlock+seccomp tiers confine unpatched while its notif tier degrades (dry-run fails open with a false "no changes" report; network fails closed), and the others die at walls this paper already names. | [V] §11a |

---

## 3. The runtime

### 3.1 What the process sees

```text
uid=0 gid=0 groups=0,65534
CapPrm: 000001ffffffffff
CapEff: 000001ffffffffff
CapBnd: 000001ffffffffff
Seccomp: 2
Seccomp_filters: 1
```

Kernel `6.18.39-gentoo-dist-bin`, x86-64, AMD Ryzen 7 7700. **[R]**

Read carefully, this block already names the mechanism.

- `000001ffffffffff` is bits 0–40 — the **complete** capability set for a kernel whose
  `CAP_LAST_CAP` is 40 (`CAP_CHECKPOINT_RESTORE`). A process that is root in a *new
  user namespace* receives the full set by construction, regardless of what its
  parent held. On our test host, real root holds `000001fffeffffff` (40 bits; bit 24,
  `CAP_SYS_RESOURCE`, is dropped) while a child in a fresh user namespace holds all
  41. **[V]**
- `groups=0,65534` is the tell. 65534 is `/proc/sys/kernel/overflowgid`, which is what
  `getgroups(2)` returns for a supplementary group that has no mapping in the
  caller's user namespace. **[V]**
- `Seccomp: 2` states that a filter is installed. It says nothing about what the
  filter contains.

Running the harness in a user namespace that maps only `0 -> 0`, with
`/proc/self/setgroups` set to `deny` and one unmapped supplementary group held,
reproduces the block exactly, with **no filter installed**:

```text
$ CONFINE_USERNS=1 CONFINE_EXTRA_GROUP=42 ./confine /usr/bin/id
uid=0(root) gid=0(root) groups=0(root),65534(nogroup)

$ CONFINE_USERNS=1 CONFINE_EXTRA_GROUP=42 ./confine ./probe id
CapPrm: 000001ffffffffff
CapEff: 000001ffffffffff
CapBnd: 000001ffffffffff
/proc/self/uid_map: 0          0          1
/proc/self/gid_map: 0          0          1
/proc/self/setgroups: deny
```

**[V]** (`verification/results/census.txt`)

**Settled on the target.** The one read §12 asks for now exists
(`verification/real/identity.txt`, 2026-09-07):

```text
$ cat /proc/self/uid_map /proc/self/gid_map /proc/self/setgroups
         0       1000          1
         0       1000          1
deny
$ ls -l /proc/self/ns/user /proc/1/ns/user
... user:[4026533335]   (identical: the target init shares this user namespace)
```

The target is a user namespace mapping **only `0 -> 1000`** (not `0 -> 0` as in our
model), with `setgroups` denied, shared with the sandbox init. The model's
attribution table is thereby confirmed in mechanism and corrected in detail: the
unmapped id that produces `EINVAL` from `setuid`/`chown` is any id other than 0 —
including 1000, which the model had mapped. The bare census
(`verification/real/probe-census.txt`, `cprobe.txt`) reproduces every row of §3.3's
N+F column on the target itself, with one exception and one addition, both recorded
in §3.3 and §3.7.

### 3.2 The model

We model the runtime as two mechanisms that can be switched on independently:

| | Mechanism | Contents |
|---|---|---|
| **N** | User namespace | uid/gid maps covering only `0 -> 0`; `setgroups` denied; an unmapped supplementary group held from before entry |
| **F** | Seccomp filter | `SECCOMP_SET_MODE_FILTER` with `PR_SET_NO_NEW_PRIVS`, inherited across `execve`, denying `unshare`, `setns`, `mount`, `umount2`, `pivot_root`, `ptrace` — and nothing else. (On the target, §3.7a adds `process_vm_readv`/`writev` to the verified deny list; the model was not updated because no experiment below depends on the difference.) |

Note what **F** does not contain: no rule for `clone`, `setuid`, `setgroups`,
`chown`, `lchown` or `mknod`. Those denials all fall out of **N**.

### 3.3 Attribution

Each operation runs in a freshly forked child, so a probe that succeeds cannot leak
its effect into the next one. **[V]** (`verification/results/census.txt`)

The last column names the mechanism that is *sufficient* to produce the denial; where
both would, **N** is listed because it acts first and needs no filter rule.

| Operation | Unconfined | **N** only | **N + F** | Sufficient cause |
|---|---|---|---|---|
| `unshare(CLONE_NEWNS)` | OK | **OK** | `EPERM` | **F** |
| `unshare(CLONE_NEWUSER)` (1 thread) | OK | **OK** | `EPERM` | **F** |
| `clone(CLONE_NEWNS)` | OK | OK | **OK** | not denied |
| `clone(CLONE_NEWUTS\|NEWNS)` | OK | OK | **OK** | not denied |
| `clone(CLONE_NEWUSER)` | OK | OK | **OK** | not denied |
| `mount(tmpfs, /mnt)` | OK | `EPERM` | `EPERM` | **N** |
| `mount(MS_SLAVE, /)` in the initial mount ns | OK | `EPERM` | `EPERM` | **N** |
| `mount(MS_SLAVE, /)` inside `clone(CLONE_NEWNS)` | OK | **OK** | `EPERM` | **F** |
| `pivot_root` | `EBUSY` (bad args) | `EPERM` | `EPERM` | **N** |
| `ptrace(PTRACE_TRACEME)` | OK | **OK** | `EPERM` | **F** |
| `mknod(S_IFCHR, 1:3)` | OK | `EPERM` | `EPERM` | **N** |
| `mknod(S_IFCHR, 0:0)` — a whiteout | OK | **OK** | **OK** | not denied (see §3.5) |
| `setuid(1000)` | OK | `EINVAL` | `EINVAL` | **N** |
| `setuid(0)`, `setgid(0)` | OK | OK | OK | — |
| `setgroups(0, NULL)` | OK | `EPERM` | `EPERM` | **N** |
| `chown(f, 0, 0)` | OK | OK | OK | — |
| `chown(f, 0, 42)` | OK | `EINVAL` | `EINVAL` | **N** |
| `lchown(f, 0, 42)` | OK | `EINVAL` | `EINVAL` | **N** |
| `chown(f, 1000, 0)` | OK | `EINVAL` | `EINVAL` | **N** |
| `chroot(/tmp)` | OK | OK | OK | — |
| `memfd_create`, and exec from it | OK | OK | OK | — |
| `setsid`, `prctl(PR_SET_PDEATHSIG)` | OK | OK | OK | — |
| exec from `/tmp` | OK | OK | OK | — |
| write into a **uid-1000-owned** directory | OK | `EACCES` | `EACCES` | **N** (model) / **M** (target, §3.7) |

Two rows carry most of the weight.

**`mount(MS_SLAVE, /)` inside a mount namespace the process just created.** Under
**N** alone this succeeds: a process that is root in a user namespace *does* own a
mount namespace it creates and *can* change propagation in it. It fails only under
**F**. Any account that explains the mount denials purely by namespace ownership
predicts that bubblewrap succeeds here — and it does (§8.1). The filter is
independently necessary.

**Writing into a uid-1000-owned directory.** A seccomp filter *cannot* produce this.
Filters see the syscall number and the six argument registers; they cannot
dereference pointers, so no filter can make `openat` fail for one pathname and
succeed for another. The observation that `/` and `/etc` reject writes while `/tmp`
and `/workspace` accept them therefore rules out seccomp as the cause on its own.
The user namespace explains it exactly: `CAP_DAC_OVERRIDE` is checked by
`capable_wrt_inode_uidgid()`, which requires the inode's owner to be **mapped** in
the caller's user namespace. An unmapped owner means the capability does not apply,
and the write returns `EACCES` even though `CapEff` shows every bit set. **[V]**

**Correction from the target (2026-09-07).** On the target, `/` and `/tmp` are both
tmpfs mounts created with `uid=1000,gid=1000` — in a namespace whose only mapping is
`0 -> 1000`, both owners are *mapped*, and both mounts are `rw`. Yet `/` rejects
writes (`mkdir /run` → `EACCES`) and `/tmp` accepts them (`verification/real/writability.txt`,
`mountinfo.txt`). Mapping therefore cannot be the discriminator there; a **third
mechanism, a path-scoped write policy (M)**, is: writable exactly `{/tmp,
/dev/shm, /workspace, /state}`, denied everywhere else. A filter cannot implement
it (same pointer argument), so it is an LSM-class restriction (Landlock-style
allowlist). The model's N-explanation of this row stands for the model; on the
target, M is what acts. §3.7 records this.

### 3.4 The consequential asymmetry

`unshare(2)` is denied while `clone(2)` with `CLONE_NEWNS` is not. This is
syscall-shaped, not capability-shaped, and it does not partition the way container
tooling assumes. A tool can obtain a private mount namespace and still be unable to
mount anything into it.

The asymmetry is easy to get backwards because the natural witness is ambiguous. A
Go program that sets namespace clone flags **and** `SysProcAttr.Credential` on one
spawn cannot distinguish them: `clone` runs first, `setgroups` runs in the child
before `execve`, and either failure surfaces as the identical string
`fork/exec <path>: operation not permitted`. Our spawn matrix shows both halves of
that ambiguity directly (§9.2), and §8.1 supplies the witness that resolves it.

### 3.5 Two probes that measure nothing

**`mknod` with `dev = 0`.** `mknod(path, S_IFCHR|0600, 0)` does not test `CAP_MKNOD`.
`makedev(0, 0)` is `WHITEOUT_DEV`, and `vfs_mknod` exempts whiteouts from the
capability check. Under **N** it succeeds while `mknod(S_IFCHR, makedev(1,3))`
returns `EPERM`. A device-node probe must use a real device number. **[V]**

**`unshare(CLONE_NEWUSER)` from Go.** The kernel refuses this for any multithreaded
caller. The Go runtime is always multithreaded, so a Go probe returns `EINVAL` on a
completely unrestricted host:

```text
# unconfined, Go probe:  unshare(CLONE_NEWUSER)  FAIL errno=22 EINVAL
# unconfined, C probe:   unshare(CLONE_NEWUSER) [1 thread]  OK
```

**[V]** Any verdict on user-namespace availability taken from a Go process is an
artifact of the prober. It must come from a single-threaded helper or from a
`clone(2)` instead. There is a second, subtler hazard: `syscall.Unshare` in Go
affects only the calling *thread*, so even a successful probe leaves the process
half-transitioned. Probes belong in disposable children.

### 3.6 Filesystem shape, and what is reported rather than verified

The runtime is described as a Gentoo userspace with no `/etc/passwd`, `/etc/mtab`,
`/etc/containers`, `/run` or `/var`; `mkdir /run` and `touch /etc/probe` fail; there
is no `/dev/fuse`; `/` is a 16 GB tmpfs owned by uid 1000, `/tmp` is a 64 MB tmpfs,
and the only large writable non-tmpfs path is `/workspace` (ZFS). Available: Go
1.26.4, GCC 15.3, Python 3.14.6, GNU tar 1.35, zstd. Not available: Rust, musl-gcc,
a working host package manager. `max_user_namespaces` is 2147483647. **[R]**

The unwritable-directory observations are consistent with §3.3's unmapped-owner
mechanism and need no other explanation. The absence of `/etc/passwd` is consistent
with the reported failure of `getpwuid(0)`.

The following are **[R]** throughout and cannot be reproduced here, because the
artifacts were never published: the 93-file experiment log, the lilipod patch, the
extracted runimage payload, the onelf bundle, and every wall-clock timing (0.088 s
warm launch, ~40 s extraction, ~12 s pack, 3.8 s fresh-extraction launch). Sizes
quoted from tool output (298 MB, 603.7 MB, 213.6 MB, 225,641,729 bytes) are
similarly **[R]**; only their arithmetic is checkable, and §8.4 checks it. No timing
in this paper should be read as a benchmark: the numbers lack repetition counts,
variance, cache controls and a defined boundary, and they measure different
operations.

### 3.7 Target deltas from the 2026-09-07 verification

Everything above was modelled. The target run
(`verification/real/`) confirms the attribution and adds four facts:

1. **The map is `0 -> 1000`, `setgroups` denied, shared with init** (§3.1).
2. **Clone flags are permitted, mounts are not — confirmed bare on the target**
   (`probe-census.txt`): `clone(CLONE_NEWNS)`, `clone(CLONE_NEWUSER)`,
   `clone(CLONE_NEWUTS|NEWNS)` all spawn; every `mount` shape, `pivot_root`,
   `unshare`, `setns` and `ptrace` fails with `EPERM`; `chown`/`lchown` to unmapped
   ids fail with `EINVAL`; the whiteout `mknod` succeeds while a real device number
   fails. §9.4's conclusion stands.
3. **A third mechanism M scopes writes by path** (§3.3 correction): the model's
   two mechanisms do not explain `/` vs `/tmp` on the target.
4. **A UTS namespace is obtainable and hostnames with it.** A child spawned with
   `clone(CLONE_NEWUTS)` sets its hostname successfully on the target — the one
   namespace-shaped capability this runtime keeps in usable form. Neither earlier
   account records it; §5.4's adaptation now uses it.

One harness caveat found while verifying: `probe`'s
`mount(MS_SLAVE,/) in clone(NEWNS)` row reports the child's *exit code*, and the
child exits 0 whether the mount fails or not — the row prints `OK` directly above
the grandchild's `FAIL errno=1 EPERM` line, in `results/census.txt` and on the
target alike. The bwrap differential, not that row, is what carries §3.4's
conclusion, and it holds.

### 3.7a Second-session extensions (2026-09-07, same runtime class)

A second target session, held to test seven further tools at their claims
(`verification/real/ext*.txt`), sharpened the mechanism model itself:

1. **F's deny list grows by two.** `process_vm_readv`/`process_vm_writev`
   return `EPERM` even for a nonexistent pid (the kernel would answer
   `ESRCH`), so they are filtered pre-execution like `ptrace`. `pidfd_getfd`,
   `process_madvise` and `kcmp` return argument-shaped errnos for bogus
   inputs — executed, not filtered.
2. **The new mount API is half-open (F13).** `fsopen`, `fsconfig(CREATE)`,
   `fsmount` and `open_tree(OPEN_TREE_CLONE)` succeed — and since 6.18's
   `fsmount` opens with the same `may_mount()` check `move_mount` and
   `unshare(CLONE_NEWNS)` use, their success proves the capability check
   passes on this runtime. `mount_setattr` succeeds too (propagation changes
   included). `move_mount` returns `ENOENT` for a nonexistent destination —
   proof the syscall executes and the filter does not name it — and `EPERM`
   for real ones. Kernel source attribution: `move_mount`'s only pre-LSM
   `EPERM` is `may_mount()`, which provably passes, and `do_move_mount()`
   contains no `EPERM` site; the denial is the LSM hook `security_move_mount()`.
   The same `EPERM` appears inside a `clone(CLONE_NEWNS)` child we own. M
   therefore denies *attach*, not mount-namespace operations: §9.4's
   "available namespace, unusable mount" gains its exact split.
3. **Detached mounts are creatable but unusable.** `openat` on a detached
   tmpfs or procfs fd fails `EACCES` (fstat shows a root-owned, sticky,
   world-writable directory — DAC would allow);
   an LSM resolving paths cannot resolve a detached mount, so every handled
   access is denied. Landlock in 6.18 hooks exactly the right set
   (`file_open`, `path_*`, `sb_mount`, `move_mount`, `sb_pivotroot`, …) for
   one ruleset to explain every M observation to date.
4. **The notif-supervisor surface is open (F14).** Installing a further
   seccomp filter with `SECCOMP_FILTER_FLAG_NEW_LISTENER` works, the
   notification round-trip works, and `SECCOMP_IOCTL_NOTIF_ADDFD` injects a
   supervisor-opened fd into the trapped child (verified end-to-end).
   `/proc/<pid>/mem` of a child opens and reads correctly — but not for
   writing (`EACCES`, the write allowlist again). Combined with F's
   `process_vm_*` denial this yields a precise viability statement for the
   supervisor tier of §10.3: **intercept, read arguments, and inject fds —
   yes; write child memory — no.** pathshim and sandlock (§11a) are field
   measurements of exactly that boundary.

---

## 4. Method


The harness (`verification/`) builds the model of §3.2 and runs each experiment under
selectable configurations. Its design principle is that **a denial observed under
both mechanisms tells you nothing about which caused it**, so every ambiguous error
is re-run with one denial removed at a time.

```sh
./verification/run.sh                       # all sections
./verification/run.sh census bwrap podman   # selected
```

Individual toggles — `CONFINE_ALLOW_UNSHARE`, `CONFINE_ALLOW_MOUNT`,
`CONFINE_ALLOW_PTRACE`, `CONFINE_DENY_CLONE_NS`, `CONFINE_DENY_SETGROUPS`,
`CONFINE_DENY_MKNOD`, `CONFINE_DENY_CHOWN_NONZERO`, `CONFINE_DENY_SETUID_NONZERO` —
add or remove one rule at a time. Captured output is in `verification/results/`.

Tool revisions used for **[S]** claims and for the reproductions:

| Tool | Revision | How obtained |
|---|---|---|
| lilipod | `872755a7cef33c238ea2d11b2310b3116944eb48` | built from source, `CGO_ENABLED=0`, vendored |
| bubblewrap | 0.8.0 | `debian:bookworm` package |
| podman | 4.3.1 | `debian:bookworm` package |
| libarchive | 3.6.2-1+deb12u5 | `debian:bookworm` package |
| Go | 1.24.7 | toolchain in use |
| Apptainer | `6099bb1e979b0c424d923c2dcef9c4ea05732cce` | source, for the `proot` question |
| onelf, dwarfs, runimage | repository `HEAD` at 2026-09-07 | source only |
| `archlinux:latest`, `alpine:latest` | digests as pulled 2026-09-07 | registry |

The model is not the runtime. It reproduces the runtime's observable behaviour on
every operation we can check, which is what licenses the attributions in §3.3 and
the differentials in §5–§8. It cannot authenticate the **[R]** material.

---

## 5. lilipod

lilipod is a small Go container manager: it pulls OCI images, unpacks layers by
shelling out to system `tar`, and starts containers by re-exec'ing itself with
`CLONE_NEWUTS|CLONE_NEWNS` (plus a user namespace and ID maps for rootless keep-id),
then `pivot_root(2)`. **[S]** (`container_utils.go`, `rootfs_utils.go:601`,
`file_utils.go:409`)

### 5.1 A dependency check before any syscall wall

Before any subcommand runs — including `pull` — lilipod requires `getsubids`,
`newuidmap` and `newgidmap` on `PATH`. This check is unconditional and applies even
as root. **[S]** (`pkg/utils/utils.go:194`) An environment without shadow-utils stops
lilipod ahead of every wall discussed below; ours supplies stubs.

### 5.2 Pull works

The registry client is ordinary HTTPS and file I/O:

```text
$ lilipod-stock pull alpine:latest
...
ff727edbcbe60df2bd6a89cf65d6db2b
```

The image ID reproduces byte for byte. **[V]**

### 5.3 One wall, not two

At uid 0, `main.go:94` defaults `ROOTFUL` to true. `EnsureFakeRoot` then re-execs
lilipod before any container work, with:

```go
cmd.SysProcAttr = &syscall.SysProcAttr{
        Credential:                 &syscall.Credential{Uid: 0, Gid: 0},
        Cloneflags:                 syscall.CLONE_NEWNS,
        GidMappingsEnableSetgroups: true,
        Setsid:     true,
        Pdeathsig:  syscall.SIGTERM,
}
```

**[S]** (`pkg/procutils/proc_utils.go:48`)

Plain `run` and `ROOTFUL=true run` therefore take the *same* path. Running the
differential:

```text
## model (clone allowed)
proc_utils.go:74 [debug] executing [.../lilipod-stock --log-level debug run --rm alpine:latest /bin/echo hi]
proc_utils.go:79 [debug] error: fork/exec .../lilipod-stock: operation not permitted

## model + clone(CLONE_NEW*) additionally denied      -> identical
## userns only, no filter at all                      -> identical
## model, ROOTFUL=true                                -> identical
```

**[V]** (`verification/results/lilipod.txt`)

Three things follow. The failing spawn is `EnsureFakeRoot`'s re-exec, not the
enter-child spawn, which is never reached. Denying `clone` changes nothing, so the
error cannot be evidence about `clone`. And the failure reproduces with **no filter
installed** — the user namespace's `setgroups=deny` is sufficient on its own.

With that first spawn short-circuited (`UNSHARED=true`), the next wall is layer
extraction:

```text
exit status 2: tar: etc/shadow: Cannot change ownership to uid 0, gid 42: Invalid argument
tar: Exiting with failure status due to previous errors
```

**[V]** — byte-identical to the reported transcript, and again produced by the
namespace alone (§9.1).

### 5.4 The chroot adaptation

An adaptation that replaces lilipod's namespace machinery with `chroot(2)` is
reported to support `pull`, `run`, `create`, detached `start`, `ps`, `stop`, `rm`,
`logs` and copy-in volumes, while `exec` and PTY allocation remained broken. **[R]**
The v1 patch was unpublished at review time; **as of 2026-09-07 the v2 patch is
published** (`patches/lilipod-restricted-v2.diff`, 532 insertions across 5 files; v2.2 adds per-layer OCI whiteout application, v2.3 adopts docker's always-install-host-resolv.conf semantics)
and its lifecycle results are reproduced on the target
(`verification/real/lilipod-v2-lifecycle.txt`): with the v2 corrections below,
`exec` **works**, and per-container hostnames work through `clone(CLONE_NEWUTS)`.
PTY allocation remains unavailable. Two components of the v1 patch were wrong or
incomplete, as this review predicted:

- **`Credential` need not be dropped.** `Credential.NoSetGroups = true` suppresses the
  `setgroups` call and nothing else; it is a no-op on unrestricted hosts, where
  dropping `Credential` entirely changes behaviour. §9.2 verifies both.
- **The mode detector must not probe `unshare`.** A detector defined as "uid 0 and
  `unshare(CLONE_NEWNS)` fails" is testing the wrong operation for two reasons: it
  does not establish that `chroot` works, and in this runtime `clone(CLONE_NEWNS)`
  *succeeds* while `unshare` does not, so it also mischaracterizes the namespace
  situation. §10.2 gives a probe protocol that tests what it needs.
  **v2 implements it** (`pkg/sandbox/restricted.go`): the probe now spawns
  disposable children — one with `clone(CLONE_NEWNS)` that attempts a tmpfs mount
  (the operation the normal path actually needs), one with `clone(CLONE_NEWUTS)`
  that attempts `sethostname` — and the enter spawn keeps `CLONE_NEWUTS` when that
  probe succeeds, which on the target it does. Container hostname isolation,
  reported lost by both manuscripts, is thereby restored.

Two further claims in the adaptation's description deserve correction. Extraction
with `--no-same-owner` does not merely lose "metadata that the runtime would refuse
anyway" — it produces a rootfs whose ownership differs from the image's, which
changes the behaviour of anything that checks it (§9.1). And running-state detection
by scanning `/proc/*/root/run/.containerenv` is a heuristic over other processes'
root links: it races, it can be spoofed by any writable marker path, and it is not a
membership guarantee. §10.6 replaces it.

### 5.5 The residual `exec` failure

The reported failure is `exec.LookPath("/bin/sh")` returning
`stat /bin/sh: no such file or directory` after a chroot into a rootfs where that
path resolves. **[R]** — and now **resolved on the target** (2026-09-07). The
lookup was resolving against the wrong root, exactly as hypothesized below, but
the wrong root was *fabricated*: the v1 adaptation's `exec` path built the enter
child with `cmd.Env = config.Env`, which strips `LILIPOD_HOME`/`HOME`; the child
then recomputed the store location from an empty environment, resolved a
**relative** store path, `MkdirAll`-ed a fresh *empty* rootfs tree under its
working directory, and chrooted into *that*. The fix (v2) inherits the parent
environment for the enter child — `RunContainer` applies the container env itself
before `exec` — and `exec` now works end to end
(`verification/real/lilipod-v2-lifecycle.txt`). Two mechanisms were worth
separating, and both were checked:

First, it is not a `PATH` problem. Go's `LookPath` stats a name containing `/`
directly and never consults `PATH`. **[S]** (`os/exec/lp_unix.go:61`)

Second, the message shape is exactly what a lookup **against the wrong root**
produces:

```text
$ lookprobe /tmp/emptyroot          # a root with no /bin/sh
B. LookPath("/bin/sh") AFTER chroot = exec: "/bin/sh": stat /bin/sh: no such file or directory
```

whereas the same probe against a real rootfs returns nil. **[V]** So the diagnosis
is not "a config bug somewhere in `cmd/exec.go`": the lookup is resolving in a
process, or at a moment, where the intended root is not in effect. That is a
localization, and §10.5 says how to make it structurally impossible.

A distinct trap sits immediately behind it and is worth documenting because it will
be hit next:

```text
C. exec.Command built AFTER chroot, Run = open /dev/null: no such file or directory
```

**[V]** An `exec.Cmd` with nil `Stdin`/`Stdout`/`Stderr` opens `/dev/null`, which an
extracted image rootfs does not have. A supervisor entering a rootfs by `chroot` must
supply explicit descriptors or populate `/dev` first.

---

## 6. Podman

The reported diagnostics are `podman info` and `podman unshare echo ok` both failing
with `Error: no such file or directory`, attributed to missing `/run`, `/var` and
`/etc/containers`. **[R]** That attribution is untested — the diagnostic does not name
a path — and the conclusion drawn from it, that "no path exists on this runtime", is
too strong. Redirecting storage was tried and did not help, but storage paths are not
the only configurable dimension. We tested the question directly.

**Rootless is foreclosed before any namespace question.** No process here can acquire
a non-root uid:

```text
$ setpriv --reuid=1000 --regid=1000 --clear-groups /bin/true
setpriv: setresuid failed: Invalid argument
```

**[V]** `setuid` to an unmapped id returns `EINVAL` (§3.3). "Rootless" requires a
non-root uid, so the mode is unreachable by definition, independent of `unshare`.

**Rootful initialization is not architecturally impossible; the default storage
driver is.** With defaults, `podman info` fails at a mount:

```text
Error: mount /var/lib/containers/storage/overlay:/var/lib/containers/storage/overlay,
flags: 0x1000: operation not permitted
```

With the graph driver switched to one that needs no mount, initialization
**succeeds**:

```text
$ podman --root /w/store --runroot /w/run --storage-driver vfs info --format '...'
OCIRuntime=crun driver=vfs
```

**[V]** This corrects both the "missing directories" diagnosis and the "no path
exists" verdict.

**The real wall is layer application, and it peels back to the ownership wall.**
Loading a local image (no registry, no network) under successively weaker models:

| Model | Failure |
|---|---|
| **N + F** | `creating mount namespace before pivot: operation not permitted` |
| **N + F**, `unshare` allowed | `remount /, flags: 0x44000: operation not permitted` |
| **N + F**, `unshare` and `mount` allowed | `lchown /etc/shadow: invalid argument` |
| **N** only, no filter | `lchown /etc/shadow: invalid argument` |

**[V]** (`verification/results/podman.txt`) containers/storage applies each layer
inside a fresh mount namespace with `pivot_root` for path safety; strip that
requirement and it lands on the same unmapped-gid `chown` that stops GNU tar and
Apptainer. Podman's own diagnostic names the cause: *"potentially insufficient UIDs
or GIDs available in user namespace (requested 0:42 for /etc/shadow)"*.

**Verdict.** Rootless: unreachable, by `setuid`. Rootful: initializes with `vfs`;
image ingest fails in layer application; container start is never reached because
there is no image. Nothing here depends on missing directories.

---

## 7. Apptainer

### 7.1 Getting Apptainer to run at all

The reported setup unpacks the `.deb` into a prepared chroot with a synthesized
`/etc/passwd` and `/etc/nsswitch.conf`, the host loader and libraries, a CA bundle,
and — because `/proc` cannot be mounted — a **static `/proc/self/mountinfo`**. A
verbatim copy of the host's mount table fails, because Apptainer cross-checks
directories' `st_dev` against it:

```text
FATAL: ... unable to create new build: failed to find mount point for /tmp:
       no parent mount point found
```

A synthetic two-line table naming the extraction filesystem's real device clears the
stage. **[R]**

This is a genuine technique with a narrow scope. It satisfies a program that only
*reads* a mount table; it does not mount procfs and supplies no live kernel view.
The device numbers in such a table are local to the setup that produced them and are
not portable configuration. It got one tool past one stage, and should be described
that way.

### 7.2 The stopping point

```text
FATAL: ... while unpacking layer sha256:55afa1e...: unpack entry: etc/shadow:
       apply hdr metadata: restore chown metadata:
       lchown .../rootfs/etc/shadow: invalid argument
```

**[R]** — the ownership wall again, at a Go `lchown` to gid 42. The supported result
is **OCI retrieval and SIF conversion proceed; ownership restoration fails before
any SIF is produced.** No completed build and no container execution are
demonstrated. Any claim of "a full SIF build" contradicts this transcript.

The failure is not interposable at the libc boundary — Go's `os` package issues
`lchown` as a direct syscall — and §9.3 verifies that this holds with cgo enabled
too. It does not follow that the unpacker cannot be fixed: a source change, an
unpacker option, or ownership-neutral extraction all remain open. What is closed is
the `LD_PRELOAD` route.

### 7.3 Runtime paths, stated correctly

Apptainer's unprivileged runtime paths are the setuid kernel mount and user
namespaces with FUSE. `mount(2)` is denied here, `/dev/fuse` is absent and
uncreatable (`mknod` fails, §3.3), and no path to `CLONE_NEWUSER` yields a usable
rootless setup because `setuid` to a non-root id is refused.

One correction to the record: **`proot` is not one of Apptainer's runtime paths.**
Across the tree, `proot` is invoked in exactly one place —
`internal/pkg/image/packer/squashfs.go:100`, wrapping `mksquashfs` during image
*building*. **[S]** The file's own comment observes that "proot relies on ptrace,
which can be unavailable because of a seccomp filter", which supports the broader
point but not its placement in the runtime. Apptainer's fakeroot feature combines
root-mapped user namespaces (`fakeroot.UnshareRootMapped`), `/etc/subuid` mappings,
and the external `fakeroot` command (`fakeroot.FindFake`). **[S]**

Since no execution was reached, the runtime barriers are *expected*, not *observed*.
That distinction is kept in §11's table.

---

## 8. runimage, chroot and single-file packaging

runimage distributes an Arch Linux rootfs in a DwarFS image, launched by static
bubblewrap and normally mounted via FUSE from unprivileged user namespaces.

### 8.1 The normal launcher, and what its failure proves

```text
$ TMPDIR=/workspace/tmp RIM_ALLOW_ROOT=1 RIM_NO_NVIDIA_CHECK=1 \
      ./runimage-x86_64 bash -c 'echo inside-runimage'
runimage-x86_64: failed to utilize FUSE during startup!
0%...100%
bwrap: Failed to make / slave: Operation not permitted
```

**[R]** (`RIM_ALLOW_ROOT=1` is needed because runimage refuses to run as uid 0 on
**any** host — `Run.sh:2205` — not because of anything specific to this runtime. **[S]**)

That last line is the witness that settles §3.4. Bubblewrap's clone flags
unconditionally include `CLONE_NEWNS` (`bubblewrap.c:3034`); a refused clone dies at
`bubblewrap.c:3106` with `Creating new namespace failed`; the `MS_SLAVE` mount at
`bubblewrap.c:3257` is reachable only after the clone succeeded. **[S]** The
differential confirms the messages discriminate:

```text
## unconfined                                   bwrap-ok
## model (clone allowed, mount denied)          bwrap: Failed to make / slave: Operation not permitted
## clone(CLONE_NEW*) additionally denied        bwrap: Creating new namespace failed: Operation not permitted
## userns only, no filter                       bwrap-ok
## model, with --unshare-user-try               bwrap: Failed to make / slave: Operation not permitted
```

**[V]** (`verification/results/bwrap.txt`)

Three conclusions. The observed message implies `clone(CLONE_NEWNS)` **succeeded**.
The result does not depend on whether runimage passes `--unshare-user-try`. And the
"userns only" row shows the filter is independently necessary: a user namespace alone
lets bubblewrap through.

### 8.2 `short write: -20` is not an errno

With `TMPDIR` left at a 64 MB `/tmp`, extraction reports thousands of
`dwarfs ... archive_error: short write: -20 != N`. **[R]**

`-20` is `ARCHIVE_WARN` in `libarchive/archive.h`. **[S]** dwarfs formats the return
value of `archive_write_data` verbatim and throws when it differs from the requested
size (`src/utility/filesystem_extractor.cpp:552`); `check_result` logs `ARCHIVE_WARN`
via `archive_error_string` and returns without throwing
(`filesystem_extractor.cpp:386`). **[S]** Calling `archive_write_data` through the
same option set dwarfs uses, into a filesystem without room:

```text
ARCHIVE_OK=0 ARCHIVE_RETRY=-10 ARCHIVE_WARN=-20 ARCHIVE_FAILED=-25 ARCHIVE_FATAL=-30
archive_write_header -> 0
archive_write_data(33554432) -> -20
dwarfs would now throw: archive_error: short write: -20 != 33554432
archive_errno        -> 28
archive_error_string -> Write failed
```

and with room, the same call returns the full byte count. **[V]**
(`verification/results/libarchive.txt`)

So: `-20` is a status code, not errno 20 (`ENOTDIR`) and certainly not 19
(`ENODEV`). The underlying errno is `ENOSPC`, and a 298 MB payload into a 64 MiB
`/tmp` overshoots by 4.4×. **[V]**

Two precisions matter for anyone debugging this. The status code identifies only the
*class* — a failed write reported as a partial success — so `-20` alone does not
distinguish `ENOSPC` from `EIO` or `EDQUOT`; the discriminating information is in
the `ARCHIVE_WARN` line that `check_result` logs just before. And the lesson is about
the **size** of the temporary directory, not about tmpfs semantics: pointing
`TMPDIR` at any filesystem with room fixes it, tmpfs included.

### 8.3 A distribution rootfs through plain chroot

The payload is a conventional rootfs, and only runimage's launcher requires
bubblewrap, so the rootfs can be entered directly. We tested this end to end with a
real `archlinux:latest` rootfs under the model of §3.2 — no `/proc`, no `/sys`, no
device nodes, plain `chroot`. **[V]** (`verification/results/arch.txt`)

**It runs.**

```text
NAME="Arch Linux"
PRETTY_NAME="Arch Linux"
uid=0(root) gid=0(root) groups=0(root),65534(nobody)
137                                   # pacman -Q | wc -l
```

The same holds for an Alpine image rootfs, which reports `apk-tools 3.0.6-r0` —
matching the reported figure. **[V]**

**Package management works, after two preconditions that no prior account
identified.**

*Precondition 1 — `DownloadUser`.* As shipped, `pacman -Sy` fails:

```text
error: failed to chown temporary download directory /var/lib/pacman/sync/download-XXXXXX: Invalid argument
error: failed to synchronize all databases (failed to initialize download)
```

`pacman.conf` sets `DownloadUser = alpm` (uid/gid 979), and pacman chowns its
download directory to that id, which is unmapped. This is the ownership wall of §9.1
appearing in a fourth tool. Commenting the directive out clears it and the databases
download. **[V]**

*Precondition 2 — the keyring.* With signatures enforced
(`SigLevel = Required DatabaseOptional`) and no initialized keyring, installation
fails at `error: GPGME error: Invalid crypto engine` / `error: tree: missing required
signature`. After `pacman-key --init` and `pacman-key --populate archlinux`, both of
which succeed under the model, the same install completes with verification active:

```text
checking keyring...
checking package integrity...
installing tree...
$ tree --version
tree v2.3.2 (c) 1996 - 2026 by ...
```

**[V]**

This substantiates the claim that signed package installation from live repositories
works — with the preconditions stated, and with the mechanism named. Availability of
`getrandom(2)` is *not* the reason it works; TLS and signature verification are
separate concerns, and the failure mode above was neither.

**Ten distros, one harness (2026-09-07).** The target now carries ten
end-to-end PoCs (`verification/real/poc-note.md`, captures `poc*.txt`): alpine,
debian, almalinux, arch, void-musl, ubuntu 26.04, opensuse leap 16.0,
rockylinux 9, rockylinux 9-minimal and fedora 44, each installing a C toolchain
through its native package manager and building+running a project. The matrix
of fixups is itself a finding:

| Manager | Fixup required | Status |
|---|---|---|
| apk | none | works |
| apt/dpkg (debian, ubuntu) | https sources, host CA, `APT::Sandbox::User=root` | works |
| dnf (almalinux) | epel-release in a separate transaction | works |
| microdnf / dnf5 (rocky-minimal, fedora) | host resolv.conf (image bakes `192.168.122.1`) | works |
| pacman (arch) | comment `DownloadUser = alpm` | works |
| xbps (void-musl) | pin mirror, host CA, **OCI whiteout handling** | works |
| zypper (leap) | http→https in the **RIS index** — zypper regenerates `repos.d` from `/usr/share/zypp/local/service/`, overwriting naive seds | works |

Three of these generalize beyond the distro: **(a)** plain `tar -x` ignores
OCI `.wh.` whiteouts, and void's image ships a self-referential
`/var/cache/xbps` symlink that a later layer whiteouts — without whiteout
processing, xbps dies with `Symbolic link loop` (§10.4's requirement now has a
live failure case; the adaptation gained `ApplyOCIWhiteouts`). **(b)** images
bake unreachable resolvers (rocky: the libvirt NAT gateway `192.168.122.1`);
docker semantics — never use the image's resolv.conf — subsume both this and
the empty-placeholder case. **(c)** every repo-protocol fixup traces to the
same tcp/80 egress failure.

**Reconciled with the reported payload (2026-09-07).** The reported runimage
rootfs's `pacman.conf` ships with **`CheckSpace` enabled and no `DownloadUser`
directive at all** (`verification/real/pacman-conf.txt`). That is why the original
account hit the `/etc/mtab` error (its rootfs *does* consult it) and never hit the
`DownloadUser` wall, and why its installs worked without either precondition being
touched. Both [V] results are correct for their respective configurations; the
preconditions are properties of `pacman.conf`, as §12 anticipated. The runimage
rootfs's keyring also ships initialized, matching the second precondition.

**`/etc/mtab` is not required.** Installs succeed with the shipped dangling symlink
in place and with no `/etc/mtab` at all (137 → 140 packages across three installs).
pacman reads it only under `CheckSpace`, which Arch's `pacman.conf` ships commented
out:

| `CheckSpace` | `/etc/mtab` | Result |
|---|---|---|
| off (default) | dangling symlink | installs **[V]** |
| off (default) | absent | installs **[V]** |
| on | absent | `error: could not open file: /etc/mtab: No such file or directory` / `could not determine filesystem mount points` **[V]** |
| on | static one-line file | `checking available disk space...` then installs **[V]** |

So the static `mtab` fixture is a valid workaround for exactly one configuration, not
a general prerequisite.

**Preparing the rootfs correctly.** The obvious preparation is wrong in a way that
matters:

```sh
printf '...' > "$R/etc/mtab"      # WRONG
```

`/etc/mtab` is a symlink. Redirection follows it. If the target is relative
(`../proc/self/mounts`) it resolves inside the rootfs to a path that does not exist
and the write fails with `ENOENT`; if it is absolute — which is what a real Arch
rootfs ships, `/etc/mtab -> /proc/mounts` **[V]** — it resolves against the **outer**
root and the write escapes the tree entirely. Remove the link first:

```sh
set -eu
R=/workspace/runimage/RunDir/rootfs
test -d "$R/etc" && test ! -L "$R/etc"

rm -f -- "$R/etc/resolv.conf"
cp -- /etc/resolv.conf "$R/etc/resolv.conf"

# only needed if the rootfs enables pacman's CheckSpace
rm -f -- "$R/etc/mtab"
printf 'none / none rw 0 0\n' > "$R/etc/mtab"

# pacman drops privileges for downloads to an id this runtime cannot map
sed -i 's/^DownloadUser/#DownloadUser/' "$R/etc/pacman.conf"

chroot "$R" /bin/bash
```

**What it costs.** The rootfs has no live `/proc` or `/sys`, no device nodes, no
working PTY, one uid and one gid, no `mount`, no `ptrace`, and shares the outer
network, PID and UTS namespaces. Anything that needs those fails. This is a usable
image-derived userspace; it is not a container.

### 8.4 Single-file packaging

onelf packs a directory tree into one executable whose runtime tries, in order:
memfd → FUSE → ephemeral tmpfs → private run directory → persistent cache. **[S]**
(`crates/onelf-rt/src/main.rs`) On this runtime the upper rungs fail as the model
predicts:

```text
fusermount3: fuse device /dev/fuse not found. Kernel module not loaded?
onelf-rt: fuse: mount failed: fusermount3 exited with exit status: 1
onelf-rt: tmpfs: enter_namespace failed: unshare: Operation not permitted (os error 1)
```

**[R]** The message is consistent with source: `enter_namespace` calls
`unshare(CLONE_NEWUSER|CLONE_NEWNS)` (`crates/onelf-rt/src/fuse/mount.rs:35`) **[S]**,
which is exactly what **F** denies. The memfd rung requires a `MEMFD_ELIGIBLE`
entrypoint — a static, dependency-free binary **[S]** — so a shell entrypoint skips
it and the ladder lands on the run-directory rung.

**The symlink rule.** onelf refuses a bundle symlink whose target is empty, **absolute**,
or whose `..` components climb above the package root
(`crates/onelf-format/src/manifest.rs:19`, with unit tests asserting exactly that).
**[S]** So `etc/mtab -> ../proc/self/mounts` would be *accepted* — it stays inside
the bundle, even though it dangles — while the real Arch form,
`/etc/mtab -> /proc/mounts`, is refused for being absolute. A measured
`archlinux:latest` rootfs (137 packages) holds 1,326 symlinks, 6 of them absolute.
**[V]** The reported bundle (210 packages) held, per the original sanitizer's own
output, **0 absolute and 1,558 in-bundle relative links, with 26 escaping or
dangling-relative links dropped** — the reported figure of "26 absolute" was a
misreading of that log **[R]**; the manifest was never published, so the
transformation remains unauditable. Rewriting or dropping absolute links changes the userspace's behaviour
after chroot, where those links would have been correct, so the transformation is
exactly the thing that needs recording.

**Sizes.** The reported artifact is 225,641,729 bytes = **215.1887 MiB** =
**225.6417 MB**. **[V]** onelf's displayed `Output: 215.2 MB` is therefore MiB, and
calling the result "215 MB" conflates the units; the byte count is the only
unambiguous figure. The remaining reported numbers — 298 MB rootfs, 603.7 MB packed
content, 12.3 MB dedup, 213.6 MB payload — come from different tools with unstated
conventions and no file manifest, and the difference between 298 and 603.7 cannot be
assigned to a cause without one. Their internal arithmetic is consistent
(213.6 + ~1.6 ≈ 215.2; 603.7 / 215.2 ≈ 2.81). **[V]**

**Persistence.** In cache mode, an install performed through the packaged executable
is reported to be visible to a later invocation. **[R]** That demonstrates reuse of an
extracted tree between invocations. It does not show that the *executable* changes,
that a copy of it carries the install, or that concurrent writers and interrupted
updates are handled safely.

**What the artifact is.** Single-file distribution of a userspace, with external
dependencies: the reported shell entrypoint needs an outer `/bin/sh`, a `chroot`
utility, `CAP_SYS_CHROOT`, and writable storage with room. No kernel and no isolation
boundary are bundled.

---

## 9. The four walls

Every tool in this study stops at one of four places. They are worth naming
separately because each has a different fix.

### 9.1 Ownership: `chown`/`lchown` to an unmapped ID

The single most consequential wall, and the one that misleads hardest, because it
returns `EINVAL` where a permission problem is expected.

```text
## userns only — no filter rule for chown anywhere
/usr/bin/tar: etc/shadow: Cannot change ownership to uid 0, gid 42: Invalid argument
/usr/bin/tar: etc: Cannot change ownership to uid 0, gid 42: Invalid argument
/usr/bin/tar: Exiting with failure status due to previous errors
rc=2
## same, with --no-same-owner
rc=0
resulting ownership:
-rw-r--r-- 1 0 0 7 ... shadow
```

**[V]** In a user namespace, an ID with no mapping translates to `INVALID_UID` /
`INVALID_GID`, and the kernel reports that as `EINVAL`. It is not a policy against
"nonzero owners" — it is a policy about *which* IDs exist. The same wall stops:

| Tool | Where | Message |
|---|---|---|
| GNU tar (lilipod's unpacker) | layer extraction | `Cannot change ownership to uid 0, gid 42: Invalid argument` **[V]** |
| Apptainer's Go unpacker | SIF conversion | `lchown .../etc/shadow: invalid argument` **[R]** |
| containers/storage `ApplyLayer` | `podman load` | `lchown /etc/shadow: invalid argument` **[V]** |
| pacman | `-Sy` download dir | `failed to chown temporary download directory ...: Invalid argument` **[V]** |

`/etc/shadow` is the usual first casualty because it is `root:shadow`, gid 42.

The mitigation — extract ownership-neutrally — is not free. It produces a tree whose
ownership differs from the image's, which changes the behaviour of anything that
checks it. §10.4 keeps the intended metadata instead of discarding it.

### 9.2 Credentials: Go's `setgroups` on every privileged spawn

Go's `os/exec` issues `setgroups` in the child whenever `SysProcAttr.Credential` is
non-nil, subject to one guard:

```go
if !(sys.GidMappings != nil && !sys.GidMappingsEnableSetgroups && ngroups == 0) && !cred.NoSetGroups {
        _, _, err1 = RawSyscall(_SYS_setgroups, ngroups, groups, 0)
```

**[S]** (`syscall/exec_linux.go:494`, Go 1.24.7)

The matrix, under a runtime where `setgroups` is denied:

| `SysProcAttr` | Result |
|---|---|
| `nil` | OK |
| `{}` — no `Credential` | OK |
| `Credential{0,0}` | **EPERM** |
| `Credential{0,0}` + `GidMappingsEnableSetgroups: true` | **EPERM** |
| `Credential{0,0, NoSetGroups: true}` | OK |
| `Credential{0,0, NoSetGroups: true}` + `Pdeathsig` | OK |
| `GidMappings` set, `EnableSetgroups` false | OK |
| `Cloneflags: CLONE_NEWNS` | OK |
| `Cloneflags: CLONE_NEWUTS\|CLONE_NEWNS` | OK |
| `Cloneflags: CLONE_NEWNS` + `Credential{0,0}` | **EPERM** |

**[V]** (`verification/results/spawn.txt`; identical whether the denial comes from
**N** or from **F**)

Three things follow. Setting `GidMappingsEnableSetgroups: true` without any
`GidMappings` — precisely what lilipod does — does **not** take the guard's exit;
the first conjunct is false because `GidMappings` is nil. `NoSetGroups: true` is a
one-field fix that is a no-op on unrestricted hosts. And the last two rows are the
ambiguity of §3.4 in isolation: `Cloneflags` alone passes, `Credential` alone fails,
and a spawn setting both reports the same string either way.

Note also that suppressing `setgroups` **retains** the process's supplementary
groups, including the unmapped one displayed as 65534. Identity is not cleaned up; it
is left alone.

### 9.3 Interposition reach: `LD_PRELOAD` does not see Go

```text
## dynamically linked C, under an LD_PRELOAD shim on lchown
shim: intercepted lchown("/tmp/shimtarget")
c lchown() rc=0

## Go, CGO_ENABLED=0, same shim
go os.Lchown -> <nil>

## Go, CGO_ENABLED=1, same shim
go os.Lchown -> <nil>
```

**[V]** Go's `os` package issues these as direct syscalls; enabling cgo does not
change it. Any design that relies on libc interposition must treat Go binaries,
static binaries, and any dynamically linked program that issues raw syscalls as
out of scope — and must be able to *say so* rather than failing opaquely (§10.3).
The same lesson repeats one tier down on seccomp-notif supervisors: the runtime's
filter denies `process_vm_readv`/`writev`, so a supervisor cannot read path
arguments that way — `/proc/<pid>/mem` read-only is the surviving channel — and a
supervisor that falls back silently instead of saying so produces false safety
reports (§3.7a, §11a: pathshim vs. sandlock).

### 9.4 Mounts: available namespace, unusable mount

`clone(CLONE_NEWNS)` succeeds and `mount(2)` fails, in the fresh namespace as well as
the initial one. **[V]** Every mount-shaped requirement is therefore unsatisfiable
regardless of namespace acrobatics: bubblewrap's `MS_SLAVE`, podman's overlay driver
and its `ApplyLayer` remount, Apptainer's image mount, `pivot_root`'s mount-point
requirement, and FUSE (which additionally needs `/dev/fuse`, uncreatable because
`mknod` needs `CAP_MKNOD` in the **initial** user namespace, §3.3).

---

## 10. Design: a runtime that degrades honestly

The results specify a runtime rather than merely motivating one. This section is
written to be implemented. It is a design, not an implementation, and nothing in it
is benchmarked.

### 10.1 The one non-negotiable principle

**Report the mode you achieved, and never let a weaker mode satisfy a stronger
request.** A user who believes they have namespaces when they have a `chroot` is
worse off than one who is told the truth. Isolation modes and compatibility modes
must be separately requestable, and a workload that requires isolation must fail
when isolation is unavailable — never silently degrade.

| Mode | Requires | Provides | Never claims |
|---|---|---|---|
| `namespace` | a working combination of namespace creation, mounts, ID maps and the requested controls | isolation as configured | — |
| `chroot` | `CAP_SYS_CHROOT`, a prepared rootfs, payload syscalls permitted | path-root change inside the outer environment | process, network, IPC or mount isolation |
| `interpose` | dynamically linked payloads, sufficient libc coverage | path and metadata emulation for cooperative programs | any security property |
| `unsupported` | — | a diagnostic naming the unmet requirement | — |

### 10.2 Probe protocol

Probing is where the prior accounts went wrong, so the protocol is specified
tightly.

1. **Probe the operation you need, never the privilege that usually implies it.**
   `unshare(CLONE_NEWNS)` failing does not mean `chroot` works, and
   `clone(CLONE_NEWNS)` succeeding does not mean you can mount (§3.4). Each mode's
   prerequisites get their own probe.
2. **Run every probe in a disposable child.** A successful `unshare`, `chroot` or
   `setuid` mutates the prober. In Go, `syscall.Unshare` mutates only the calling
   *thread*, leaving the process inconsistent — worse than either outcome.
3. **Never probe `unshare(CLONE_NEWUSER)` from a multithreaded process.** It returns
   `EINVAL` unconditionally. Use a single-threaded helper or `clone(2)` (§3.5).
4. **Use discriminating arguments.** `mknod(S_IFCHR, makedev(0,0))` is a whiteout and
   tests nothing; use a real device number (§3.5).
5. **Record the errno, not a boolean.** `EPERM` and `EINVAL` from the same call mean
   different things: `EINVAL` from `setuid`/`chown` points at an unmapped ID and
   therefore at a *mapping* fix; `EPERM` points at a policy.
6. **Read the mapping directly when it is available.** `/proc/self/uid_map`,
   `/proc/self/gid_map` and `/proc/self/setgroups` answer in one read what a dozen
   probes infer. Their contents belong in the diagnostic.

Minimum probe set, each in its own child:

```
clone(CLONE_NEWNS) | clone(CLONE_NEWUSER) | unshare(CLONE_NEWNS) [1 thread]
mount(tmpfs) in the current ns | mount(tmpfs) inside clone(CLONE_NEWNS)
pivot_root | chroot | mknod(S_IFCHR, makedev(1,3)) | ptrace(PTRACE_TRACEME)
setuid(nonzero) | setgroups(0,NULL) | chown(f, 0, <a gid the image uses>)
memfd_create + exec from it | write into a directory owned by an unmapped id
```

### 10.3 Payload classification

Before selecting `interpose`, classify the payload, and treat classification as
advisory rather than a guarantee.

- `PT_INTERP` present → dynamically linked; interposition *may* reach it.
- `PT_INTERP` absent → static; interposition cannot reach it.
- Go build markers present → treat as unreachable regardless of linkage, with or
  without cgo (§9.3).
- Any other program may still issue raw syscalls. There is no ELF property that
  proves interposition coverage.

Where classification says "unreachable", the runtime must decline the mode with a
named reason rather than starting and failing later, deeper, and less legibly.
`ptrace`-based interception (the PRoot approach) is a separate tier that requires a
usable `ptrace`, which this runtime denies.

### 10.4 Image extraction

Extraction is the component with the most exposure and the least room for shortcuts.

**Do the extraction in-process, over a vetted library.** Shelling out to system `tar`
inherits its ownership semantics, its exit codes, and its behaviour on paths.

**Never restore ownership by default.** Instead, record intended metadata in a
sidecar keyed by path, and apply it only where the target ID is mapped:

```json
{"path": "etc/shadow", "uid": 0, "gid": 42, "mode": "0640",
 "applied": {"uid": 0, "gid": 0}, "reason": "gid 42 unmapped"}
```

The sidecar makes three things possible that `--no-same-owner` alone does not:
faithful re-export, an honest answer to a workload that asks who owns a file, and a
diagnostic that names the gap. It does **not** change kernel permission checks, and
must never be presented as if it does.

**The rest of the OCI layer contract still applies**, and dropping ownership does not
discharge it: apply layers in order; interpret `.wh.` whiteouts and
`.wh..wh..opq` opaque directories; preserve hard links and symlinks; and refuse any
entry whose resolved path leaves the destination, including through a symlink
created by an earlier entry in the same layer.

**Choose the extraction destination by free space, and check it.** A payload that
overshoots the default temporary directory produces the failure of §8.2, whose error
text names neither space nor the directory. Check `statvfs` for both blocks and
inodes before extracting, and name the destination in the error if it fails.

### 10.5 Entering the rootfs

```
1. resolve the rootfs path and refuse it if it is a symlink
2. open every file descriptor the child needs while the outer root is still current
   (stdio, log sinks, a PTY master/slave pair, any host device the config exposes)
3. chroot(rootfs); chdir("/")
4. resolve the program path — now, inside the new root, in this process
5. exec
```

Step 2 matters because a chroot cuts off every path outside the new root; a
descriptor opened before the change keeps working. This is what makes a PTY possible
at all in `chroot` mode: allocate the pair outside, pass the descriptors in, and set
the controlling terminal in the child. It also avoids the `open /dev/null` failure of
§5.5 for any `exec.Cmd` with nil streams. It does not help a payload that reopens
`/dev/pts/N` by name — that case needs a populated `/dev` or is unsupported.

Step 4 matters because it is where the reported `exec` failure lives (§5.5). Resolve
the program in the process that has already changed root, never in the parent, and
never at `exec.Command` construction time.

### 10.6 Process supervision

Track children the runtime itself created, in the runtime itself. Do not infer
membership from the filesystem: scanning `/proc/*/root/<marker>` races against
process exit, depends on the readability of other processes' root links, and trusts
a path any writable payload can create.

- Hold a **pidfd** per direct child; use `SIGCHLD` and `waitid` for exit status.
- `PR_SET_PDEATHSIG` fires when the creating **thread** exits, not on any ancestor's
  death. In a threaded supervisor this produces surprising early exits; a wrapper
  such as `timeout(1)` around the launcher is enough to kill a detached child. Lock
  the spawning thread or do not rely on the signal.
- A pidfd addresses one process. It does not contain descendants and it is not a PID
  namespace. Grandchildren that reparent are outside the runtime's reach; say so
  rather than implying containment.
- `exec`-into-a-running-container re-enters by the §10.5 sequence against the same
  rootfs. It is a fresh chroot, not `setns`, and it shares nothing with the original
  process beyond the filesystem tree.

### 10.7 Honest semantics for everything that cannot be provided

- **Volumes.** If the implementation copies, call it a copy, document when it
  synchronizes, and **reject** `:ro` rather than accepting a flag that is not
  enforced.
- **`/proc` and `/sys`.** A static fixture can satisfy a program that only reads a
  mount table (§7.1) and nothing more. Generate it from the real topology where
  possible, never ship someone else's device numbers, and fail loudly for anything
  that needs a live interface.
- **Devices.** With no `mknod` and no mounts, device access in `chroot` mode is
  limited to descriptors passed in at step 2 of §10.5. Path rewriting to an outer
  absolute path does not survive the root change.
- **Identity.** Reporting a fake uid through a shim changes no kernel check, and
  suppressing `setgroups` leaves the process's real supplementary groups in place.
  Both facts belong in the mode report.
- **Isolation.** In `chroot` and `interpose` modes there is none. The correct framing
  is environment reproducibility for contexts whose security boundary is already
  exterior.

### 10.8 Diagnostics

Every failure should name the operation, the errno, the mechanism, and the remedy —
because in this environment the errno alone is actively misleading:

```
cannot restore ownership of etc/shadow (uid 0, gid 42): EINVAL
  gid 42 is not mapped in this user namespace (/proc/self/gid_map: 0 0 1)
  extracting without ownership; intended metadata recorded in .meta.jsonl
```

A one-line mode banner at startup — mode, why, and what it does not provide — costs
nothing and prevents the entire class of misdiagnosis this paper documents.

### 10.9 Packaging

A single-file artifact should record its immutable inputs, its runtime dependencies
(an outer shell and `chroot` utility are dependencies), the metadata
transformations applied at pack time — particularly symlink rewrites (§8.4) — and the
execution mode it selected. Persistent state must be separated from the immutable
image or labelled as mutable cache, with defined locking and recovery; the current
evidence for cache-mode persistence does not cover concurrent writers or interrupted
updates. A memfd-only launch requires a static, dependency-free entrypoint; a normal
payload still needs its filesystem on disk.

---

## 11. Comparative summary

Only results from this study. **Not reached** means an earlier stage failed;
**expected** means a barrier follows from the runtime but was not exercised.

| | Image acquisition | Rootfs preparation | Workload launch | Package management | Blocking wall |
|---|---|---|---|---|---|
| **lilipod, stock** | pull works **[V]** | not reached | fails **[V]** | not reached | `setgroups` in `EnsureFakeRoot`'s re-exec (§9.2) |
| **lilipod, chroot adaptation (v2)** | works on target **[V]** | ownership-neutral extraction **[V]** | full lifecycle incl. `exec` on target **[V]**; hostname isolation via `clone(NEWUTS)` **[V]** | `apk --version` only **[R]** | PTY unavailable; patch published (`patches/`) |
| **Podman, rootless** | — | — | — | — | `setuid(nonzero)` = `EINVAL` **[V]** |
| **Podman, rootful** | init OK with `vfs` **[V]** | layer apply fails **[V]** | not reached | not reached | mount ns → mount → unmapped-gid `lchown` (§6) |
| **Apptainer** | OCI fetch + SIF conversion proceed **[R]** | ownership restore fails **[R]** | not reached | not reached | unmapped-gid `lchown` (§9.1); mount/FUSE barriers *expected* |
| **runimage, normal launcher** | bundled | extraction OK on a filesystem with room **[R]** | fails **[V][S]** | not reached | `mount(MS_SLAVE, /)` after a successful clone (§8.1) |
| **rootfs via plain chroot** | bundled | directory rootfs **[V]** | selected utilities run **[V]** | **signed installs work** after two fixes **[V]** | no `/proc`, `/sys`, devices, PTY, mounts, ID range |
| **rootfs via chroot + onelf** | bundled | packaging reported **[R]** | packaged commands reported **[R]** | reported **[R]** | as above, plus outer `/bin/sh` + `chroot` + writable space |

The pattern is consistent: **the image and registry plane is ordinary userspace I/O
and mostly works; the isolation plane is namespaces and mounts and does not.** The
exception, and the finding that costs the most debugging time, is that image
*extraction* straddles both — it is file I/O that happens to call `chown`, and that
is where four separate tools stop.

### 11a The extended corpus (second target session, 2026-09-07)

Seven more tools were run at their claims on the target — fetched as source, built
where a build was possible (C: gcc on the runtime; Rust: 1.98.1 via rustup to
`/workspace`), executed unmodified. Evidence: `verification/real/ext*.txt`. The
session also produced the kernel findings F13–F14 recorded in §3.7a.

| Tool (revision) | Claim tested | Result on the target | Blocking wall |
|---|---|---|---|
| **udocker** 1.3.17 (`638bc42`) | "execute basic docker containers where docker is unavailable", multi-engine | pull/create work; **F1 (fakechroot) runs containers end-to-end**: `apk add` + `curl` HTTPS in alpine, echo in debian; needs `--allow-root` + `--user=0` (no-passwd root remap bug) | P1/P2 PRoot: `ptrace` (F). R1 runc: instant silent rc=4. dpkg-class payloads: interposer coverage (§10.3) |
| **dockless** (`ed35b5d`) | docker/podman verbs over udocker+PRoot | CLI skeleton, guardrails and fail-fast behave exactly as documented; engine dead; hook contract dead | PRoot `ptrace` (F); `chown 999`/`mknod` in hooks (N) |
| **rurima** (`30a0637`) | dockerhub pull + unpack + run via built-in ruri | `docker pull` dies in layer 0; `r` (run a prepared rootfs) works | `tar -xpf` as root → unmapped-gid `chown` (§9.1); non-root path needs proot (F) |
| **ruri** 3.9.5 (`711673a`) | "better chroot", runs where namespaces are unavailable | **works unpatched**: chroot container, per-mount failure warnings, unshare mode probed then refused, `apk`+`curl` end-to-end; needs host resolv.conf install; `/dev/null` absent (shell-created regular-file trap) | none fatal; degraded by design |
| **treesandbox** (`71acbee`) | rootless multi-layer sandbox | dead before any namespace call: `pwd.getpwuid(0)` KeyError, then missing `/etc/hostname`; its layers are `unshare`+`mount` (both F) with no fallback | environment + F |
| **sandlock** 0.8.7 (`841265d`) | confinement via Landlock + seccomp-bpf + seccomp-notif | Landlock/seccomp/resource-limit tiers work unpatched; notif-mediated COW, chroot mounts and net ACL degrade — `--dry-run` **fails open** (reports "no filesystem changes" while changing files under a write grant; fails closed without one), network fails closed; `/proc` virtualization inferred degraded, not separately captured | `process_vm_readv` (F) and `/proc/pid/mem` O_RDWR (M) |
| **pathshim** (`8bcc34e`) | bind mappings without mount privileges, via seccomp-notif | `probe` → `passthrough` with reason `EPERM`, run degrades to unmapped passthrough — honest, exactly as its README promises | `process_vm_readv` (F); `/proc/pid/mem` write (M) |

Three readings follow. **(1) The §10 ladder now has unpatched inhabitants on every
rung below `namespace`**: ruri is a working `chroot`-tier runtime, udocker F1 a
working `interpose`-tier one, pathshim a working *probe-and-degrade* for the
notif tier — the corpus no longer needs its own patch to demonstrate any mode
below namespaces. **(2) The interpose tier's ceiling repeats one rung down**
(§9.3 → seccomp-notif): both pathshim and sandlock read path arguments with
`process_vm_readv`; here that syscall is filtered, `/proc/pid/mem` read is not.
The two tools' opposite fallback directions — pathshim refuses the mode, sandlock
continues the syscall directly — are a live demonstration of §10.1's rule that
degradation must be *chosen and reported*, because the silent variant
(sandlock's dry-run) is not merely weaker, it is *false*. **(3) The §9.1
ownership wall now has a fifth tenant** — rurima's `tar -xpf`-as-root extraction
joins lilipod's tar, containers/storage's applier, Apptainer's Go unpacker and
pacman's `DownloadUser`: extraction code written for real root cannot be rescued
by privileges this runtime grants — only ownership-neutral extraction (udocker,
lilipod v2) or interposition (fakechroot) clears it.

---

## 12. Limitations

The measurements here come from a model of the target runtime, not the runtime. The
model reproduces its behaviour on every operation we could check and its identity
block byte for byte, which is what supports the attributions in §3.3 and the
differentials in §5–§8. It cannot establish that the target's filter contains exactly
the rules in §3.2, only that a filter with those rules plus a partial ID map produces
what the target produced. *That gap is now closed: the target's `/proc/self/uid_map`,
`gid_map` and `setgroups` were read on 2026-09-07 (§3.1,
`verification/real/identity.txt`), and the bare census ran on the target itself
(§3.7) — the model's attributions held, with the map corrected to `0 -> 1000` and
the write-scope mechanism added (§3.3, §3.7).*

The **[R]** material — the lilipod patch, the runimage payload, the onelf bundle, and
every timing — was never published and is not reproducible. This paper attaches no
conclusions to it beyond what its own transcripts show, and none at all to the
timings, which lack repetition counts, variance, cache controls and a defined
boundary. Claims about the adapted lilipod's lifecycle coverage, its `logs` capture,
its volume semantics and the packaged artifact's persistence are reported, not
verified.

The Arch results of §8.3 use `archlinux:latest`, not the reported runimage payload,
so package counts and symlink counts differ from the reported figures. The
preconditions we identified (`DownloadUser`, keyring, `CheckSpace`) are properties of
pacman and its configuration; other package managers will have their own.

One runtime, one architecture, one kernel version. The seccomp profile studied is one
point in a space; §10's probe protocol is designed not to assume otherwise.

§10 is a specification, not an implementation. Its central bet — that path
virtualization at the libc boundary covers enough real workloads to be worth building
— is supported here only by the unmodified success of dynamic payloads under a real
`chroot` (§8.3), which is a weaker result than it needs.

---

## 13. Prior art

The tools studied are [lilipod](https://github.com/89luca89/lilipod),
[Podman](https://github.com/containers/podman),
[Apptainer](https://github.com/apptainer/apptainer) and
[runimage](https://github.com/VHSgunzo/runimage); the packaging layer is
[onelf](https://github.com/qaidvoid/onelf), over
[DwarFS](https://github.com/mhx/dwarfs) images, launched by
[bubblewrap](https://github.com/containers/bubblewrap).

The design of §10 is not new territory, and two projects are direct baselines that
any implementation must be measured against rather than merely cited:

- **[udocker](https://github.com/indigo-dc/udocker)** already combines image handling
  with several execution engines — including PRoot and Fakechroot — selected per
  environment. It is the closest existing system to §10 and the obvious comparison
  point for a multi-mode runtime. **Measured on the target (§11a):** its PRoot
  engines die at the same `ptrace` filter that stops PRoot everywhere here, and its
  F1 fakechroot engine *runs containers unpatched* — pull, package install, network
  — through exactly the interpose tier §10.3 specifies, including the tier's
  predicted ceiling (dpkg-class workloads trip un-interposed paths). udocker's
  per-container `--execmode` switch is also the mode-selector design §10.2 asks
  for, at container granularity. Caveat for adopters: upstream has been dormant
  since 2024-08 (last merge `638bc42`); it still runs on Python 3.14, but the
  no-passwd-as-root remap bug fixed here by `--user=0` is upstream and unpatched.
- **[fakechroot](https://github.com/dex4er/fakechroot)** is the libc-interposition
  implementation of §10.3's `interpose` mode. §9.3's result bounds what it can reach
  in a Go-heavy container ecosystem. **Measured (§11a):** the bound is real but the
  tier is live — busybox/musl payloads complete package installs under it.

Two further projects are now *measured baselines* rather than citations, from the
extended corpus of §11a:

- **[ruri](https://github.com/RuriOSS/ruri)** is a working `chroot`-tier runtime on
  this runtime class: probe-then-refuse for unshare mode, per-mount failure
  warnings, and a docker-image-facing companion ([rurima](https://github.com/RuriOSS/rurima)
  — which dies at the §9.1 extraction wall as root). ruri is the strongest existing
  "better chroot" the §10 `chroot` tier should be compared against.
- **[pathshim](https://github.com/compforge/pathshim)** is the strongest existing
  implementation of the seccomp user-notification supervisor tier: it probes the
  node, reports the mode and degradation reason, and never silently maps paths.
  On this runtime it degrades to passthrough for exactly the reason §3.7a predicts
  (`process_vm_readv` filtered). Its probe subcommand is a reusable preflight for
  the whole tier. **[sandlock](https://github.com/multikernel/sandlock)**
  demonstrates the same tier's danger when degradation is silent: its dry-run
  reports "no filesystem changes" while writing files (§11a) — the field's best
  argument for §10.1's loud-degradation rule.

[dockless](https://github.com/ylang-ylang/dockless) (docker verbs over udocker)
and [treesandbox](https://github.com/garywill/treesandbox) (rootless namespace
tree sandbox) complete the measured corpus: the former is a sound CLI-honesty
layer over a dead-here engine, the latter an unshare/mount architecture with no
fallback — the §8.1 wall, one project later.

[fakeroot](https://tracker.debian.org/pkg/fakeroot) virtualizes file ownership through
the same interposition mechanism and is the model for §10.4's sidecar.
[PRoot](https://proot-me.github.io) intercepts through `ptrace`, which this runtime
denies, and is a separate tier rather than a fallback.
[sharun](https://github.com/VHSgunzo/sharun) belongs to a different lineage than all
of these: it maps the ELF interpreter into memory via userland-execve and patches
interpreter and RPATH so dynamically linked binaries run from any prefix. It solves
relocation, not filesystem virtualization, and is not a template for §10.3.

The contribution of this study is therefore not the idea of a multi-mode runtime. It
is the attribution: which mechanism produces which denial, which errors are
non-diagnostic, which probes measure nothing, and what a runtime must therefore test
and report.

---

## 14. Reproducing

```sh
./verification/run.sh                       # all sections
./verification/run.sh census bwrap podman   # selected sections
```

Needs `go`, `gcc` and a running `docker` (start `dockerd` by hand if necessary);
sections whose dependencies are absent print `SKIP`. Captured output for the run
cited above is in `verification/results/`. `verification/README.md` documents the
model, the toggles, and what each section answers.

| Section | Establishes | Paper |
|---|---|---|
| `census` | mechanism attribution for every operation; the identity block | §3.1, §3.3, §3.5 |
| `spawn` | which `SysProcAttr` shapes call `setgroups` | §9.2 |
| `bwrap` | that bubblewrap's message distinguishes clone from mount | §3.4, §8.1 |
| `tar` | the ownership wall, from the namespace alone | §9.1 |
| `libarchive` | `-20` is `ARCHIVE_WARN`; `archive_errno` is `ENOSPC` | §8.2 |
| `lilipod` | one wall, not two; the pull image ID; the tar wall | §5 |
| `podman` | overlay vs vfs; the layer-apply cascade | §6 |
| `interpose` | `LD_PRELOAD` reach for C vs Go, with and without cgo | §9.3 |
| `lookpath` | Go path resolution across a chroot; the `/dev/null` trap | §5.5 |
| `arch` | a distribution rootfs by chroot; the two pacman preconditions; `/etc/mtab` | §8.3 |
| `sources` | the upstream lines the `[S]` claims rest on | §5, §8.1, §8.4, §9.2 |
| `verification/real/` | target-run evidence: identity, bare census, spawn/interpose/lookpath, writability, bwrap, pacman.conf, lilipod v2 lifecycle | §3.1, §3.7, §5.4, §5.5, §8.3 |
| `verification/real/ext*.txt` | second target session: kernel-feature survey (new mount API, notif/ADDFD, memory-access split) and the seven-tool extended corpus | §3.7a, §11a |
| `arithmetic` | unit and size conversions | §8.4 |
