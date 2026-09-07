# Containers Without Privileges: An Empirical Study of Container Tooling in a Namespace-less, Seccomp-Confined Runtime

**Version 2.0 — 2026-09-07**
*All command outputs in this paper were captured mechanically on the target runtime on
2026-09-06 between 16:45 and 17:12 UTC and are reproduced verbatim from the experiment
log (Appendix A). Where a historical output from the same day is quoted because a
cheaper reproduction was not possible (e.g. due to caching), this is marked explicitly.*

---

## Abstract

A growing class of Linux environments — AI-agent sandboxes, hardened CI executors,
locked-down HPC login nodes and Android/Termux — deny exactly the kernel primitives
that container runtimes are built on: mounts, `unshare`, ptrace and device creation.
We characterize one such runtime empirically and evaluate four container tools against
it: **lilipod** (namespace+pivot_root), **rootless podman** (user namespaces),
**apptainer** (setuid kernel mounts, or user namespaces+FUSE), and **runimage** (user
namespaces+bubblewrap+FUSE). Podman and apptainer fail for architectural reasons that
we trace to individual denied syscalls. lilipod can be adapted to the environment with
a ~280-line patch that removes the process-credential handling the filter rejects and
replaces its namespace machinery with `chroot(2)`, after which
pull/create/start/stop/rm/logs/volumes work, but `exec` and PTY allocation remain
broken. runimage, whose payload is a conventional distribution rootfs, works once its
bubblewrap stage is bypassed with the same chroot technique; its full Arch Linux
userspace including the pacman package manager is functional. Finally we show that the
resulting rootfs can be packaged with **onelf** into a single 215 MB self-extracting
executable with a 3.8 s cold start, and we distill the findings into a design for a
container runtime that degrades gracefully across the privilege spectrum.

A recurring theme is that the runtime's denials are *syscall-shaped*, not
capability-shaped, and do not partition the way container tooling assumes: `unshare(2)`
is refused while `clone(2)` with `CLONE_NEWNS` is not, so a process can hold a private
mount namespace and still be unable to mount anything in it.

---

## 1. Introduction

The modern Linux container stack assumes three kernel affordances: user namespaces
(`CLONE_NEWUSER`), mount namespaces plus `mount(2)`/`pivot_root(2)`, and — for FUSE-
based alternatives — `/dev/fuse`. A runtime that denies all of them is not a
hypothetical: it is the default configuration of a class of sandboxed agents and
CI executors, and it is routine on HPC systems where administrators disable
unprivileged user namespaces for security policy reasons.

This paper is an empirical study of what actually happens when four representative
container tools meet such a runtime, and what survives. It makes four contributions:

1. A precise, reproducible characterization of a namespace-less, seccomp-confined
   runtime (§2, Table 1), including which verdicts rest on direct probes and which on
   tool behaviour.
2. Failure analyses of lilipod, podman, and apptainer, each traced to the specific
   denied syscall, including two non-obvious walls: a `chown`-restriction that returns
   `EINVAL` for any owner other than `0:0`, and a `setgroups` denial that breaks the
   default credential path of Go's `exec.Cmd` (§4–§6).
3. A working demonstration that runimage's rootfs, entered via plain `chroot(2)`,
   provides a fully functional Arch Linux userspace with working package management,
   and that onelf can package the result into a single self-contained executable (§7).
4. A design sketch for a container runtime that survives this environment class by
   construction (§9), informed by each failure above.

A note on scope: in this runtime the sandbox boundary already exists *outside* the
process being studied. "Container" here means *a disposable, image-derived userspace*,
not a security isolation boundary. None of the working configurations in this paper
provide isolation, and §9 is explicit about that.

---

## 2. The experimental runtime

### 2.1 Identity and privileges

The runtime presents itself as root with every capability, which makes the denials
below easy to misdiagnose as logic errors rather than policy:

```
$ id
uid=0 gid=0 groups=0,65534
$ grep -E 'Cap(Eff|Bnd|Prm)|Seccomp' /proc/self/status
CapPrm:	000001ffffffffff
CapEff:	000001ffffffffff
CapBnd:	000001ffffffffff
Seccomp:	2
Seccomp_filters:	1
$ uname -a
Linux sandbox 6.18.39-gentoo-dist-bin #1 SMP PREEMPT_DYNAMIC ... x86_64 AMD Ryzen 7 7700 ...
```

`Seccomp: 2` is filter mode: the capability bits are a fiction; the filter decides.

### 2.2 Syscall verdicts

Table 1 summarizes the probes (full transcripts in Appendix A, files `env-*`):

| Syscall / operation | Verdict | Evidence |
|---|---|---|
| `unshare(CLONE_NEWUSER\|NEWNS\|...)` | `EPERM` | `unshare: unshare failed: Operation not permitted` |
| `mount(2)` | `EPERM` | `mount: /tmp/mntprobe: permission denied` (rc 32) |
| `clone(2)` with `CLONE_NEWNS` | **works** | bubblewrap gets past its namespace clone and dies at its first `mount(2)` (§7.1) |
| `ptrace(2)` | `EPERM` | `strace: PTRACE_TRACEME: Operation not permitted` |
| `mknod(2)` | `EPERM` | `mknod: nodprobe: Operation not permitted` |
| `setuid(2)` to a non-zero id | `EINVAL` | `setuid(1000) FAILED: [Errno 22] Invalid argument` |
| `setgroups(2)` (even empty) | `EPERM` | `setgroups(0): rc=-1 errno=1` |
| `chown(2)` to anything ≠ `0:0` | `EINVAL` | `chown 0:42 f` → `Invalid argument` |
| **`chroot(2)`** | **works** | `chroot-ok` |
| **`memfd_create(2)`** | **works** | `memfd-ok` |
| `setuid(0)` (no-op as root) | works | `setuid0-ok` |
| `setsid`, `prctl(PR_SET_PDEATHSIG)` | work | `rc=0` |
| exec on `/tmp`, `/workspace` | works | `exec-tmp-ok` |

The `unshare`/`clone` split is the runtime's most consequential asymmetry, and it is
easy to get backwards, because the natural witness is ambiguous. A Go tool that sets
both namespace clone flags and `SysProcAttr.Credential` on the same spawn cannot
distinguish them: `clone` runs first, `setgroups` runs in the child before `execve`,
and *either* failure surfaces as the identical `fork/exec <path>: operation not
permitted`. The verdict above therefore rests on bubblewrap, whose behaviour separates
the two: its clone flags unconditionally include `CLONE_NEWNS`, and a failed clone
produces a distinct message (`Creating new namespace failed`) from a failed mount
(`Failed to make / slave`). The runtime produces the latter (§7.1), so the namespace
clone succeeds and the mount is what is refused. A private mount namespace is therefore
obtainable and useless.

Three denials deserve emphasis because they produce misleading errors downstream:

- **`chown` → `EINVAL`, not `EPERM`.** Anything that restores archive ownership as
  root (tar, OCI unpackers) fails with "Invalid argument" on the first non-root-owned
  file — e.g. `/etc/shadow` (root:shadow, gid 42). This kills stock lilipod's tar
  extraction and apptainer's SIF builder at the same wall (§4.1, §6.1).
- **`setgroups` → `EPERM`, in a code path callers do not know they are on.** Go's
  `os/exec` issues `setgroups` in the child whenever `SysProcAttr.Credential` is
  non-nil, unless `Credential.NoSetGroups` is set (`syscall/exec_linux.go`). Container
  tools written in Go set `Credential{Uid: 0, Gid: 0}` to be explicit about running as
  root and leave `NoSetGroups` at its zero value, so *every* privileged spawn pattern
  fails — reported as `fork/exec <path>: operation not permitted`, an error naming a
  path that exists and is executable (§4.2).
- **`setuid` to a non-zero id → `EINVAL`.** No process on this runtime can drop to an
  unprivileged uid, which forecloses every "rootless" mode by definition, before any
  namespace question arises (§5).

### 2.3 Filesystem shape

The runtime is a Gentoo userspace without the usual Linux furniture:

```
$ ls /etc/passwd /etc/mtab /etc/containers
ls: cannot access '/etc/passwd': No such file or directory
ls: cannot access '/etc/mtab': No such file or directory
ls: cannot access '/etc/containers': No such file or directory
$ ls -ld /run /var /tmp ; mkdir /run ; touch /etc/probe
ls: cannot access '/run': No such file or directory
ls: cannot access '/var': No such file or directory
drwxrwxrwt 8 0 0 260 ... /tmp
mkdir: cannot create directory '/run': Permission denied
touch: cannot touch '/etc/probe': Permission denied
```

There is no `/dev/fuse` (and `mknod` cannot create it), no `/run`, no `/var`, `/` is a
16 GB tmpfs owned by uid 1000 that this process cannot write to despite holding
`CAP_DAC_OVERRIDE` in `CapEff`, `/tmp` is a **64 MB tmpfs** (relevant in §7.1), and the
only large writable non-tmpfs path is `/workspace` (zfs). No user database exists at
all — `getpwuid(0)` fails (§6.1). Tools available: Go 1.26.4, GCC 15.3, Python 3.14.6,
GNU tar 1.35, zstd. Not available: rust/cargo, musl-gcc, any package manager
(`emerge`/`apt` binaries exist but have nothing to work against).

Notably `max_user_namespaces = 2147483647` — the denials above are seccomp policy, not
sysctl configuration, and no amount of sysctl tweaking would help.

---

## 3. Methodology and versions

Each tool was exercised from the runtime as uid 0, with commands and outputs captured
mechanically (Appendix A). Tools and versions:

| Tool | Version | Source |
|---|---|---|
| lilipod | upstream `main` @ `872755a` | built from source, Go, `CGO_ENABLED=0` |
| podman | 5.8.2 | preinstalled on runtime |
| apptainer | 1.5.3 | official `apptainer_1.5.3_amd64.deb` |
| runimage | image v0.43.1 / runtime v0.5.6 | `continuous` release single-file binary |
| onelf | 0.3.3 | prebuilt `onelf-x86_64-linux` release |

For lilipod we evaluate both the stock build and a patch (Appendix B) that adds a
runtime probe and chroot fallback. All timings are wall-clock on the host CPU
(Ryzen 7700).

---

## 4. lilipod

lilipod (89luca89) is a minimal Go container manager: it pulls OCI images, unpacks
layers with system `tar`, and starts containers by re-exec'ing itself with
`CLONE_NEWUTS|CLONE_NEWNS` (+ user namespace and uid maps for rootless keep-id),
then `pivot_root(2)`.

### 4.1 Stock build

Before any subcommand runs, lilipod requires `getsubids`, `newuidmap` and `newgidmap`
on `PATH` — an unconditional hard-dependency check that applies even to `pull` and even
as root. The runtime's shadow-utils satisfy it; an environment without them would stop
lilipod before any of the walls below.

Pull works — the registry client is ordinary HTTPS + file I/O:

```
$ LILIPOD_HOME=... lilipod-stock pull alpine:latest
pulling image manifest: index.docker.io/library/alpine:latest
pulling layer 55afa1ecc...tar.gz
saving manifest ... done
ff727edbcbe60df2bd6a89cf65d6db2b
```

`run` fails at the first spawn it attempts, and not where the flags suggest. At uid 0
lilipod's `setEnviron` defaults `ROOTFUL=true`, so plain `run` and `ROOTFUL=true run`
take the same path: `EnsureFakeRoot` re-execs lilipod with `Credential{0,0}` and
`CLONE_NEWNS`, and the child dies at `setgroups` before `execve`:

```
$ lilipod-stock run --rm alpine:latest /bin/echo hi
2026/09/06 16:46:30 fork/exec /workspace/lilipod/lilipod-stock: operation not permitted
```

The clone flags are accepted (§2.2); the credential handling is what fails, at
`pkg/procutils/proc_utils.go`. The enter-child spawn in
`pkg/containerutils/container_utils.go` is a later wall and is never reached.

With that first spawn short-circuited — `UNSHARED=true` does it, and so does the patch
of §4.2 — the next wall is layer extraction, where system `tar` restoring ownership
from the archive hits the `chown` restriction:

```
$ UNSHARED=true lilipod-stock run --rm --userns host alpine:latest /bin/echo hi
2026/09/06 ... exit status 2: tar: etc/shadow: Cannot change ownership to uid 0, gid 42: Invalid argument
tar: Exiting with failure status due to previous errors
```

### 4.2 Patching for the runtime

We patched lilipod to detect the restricted runtime once (uid 0 + failed
`unshare(CLONE_NEWNS)` probe, cached) and degrade to plain chroot. The interesting
part is how many distinct walls had to be peeled:

1. **`setgroups` in the spawn path** — the operative fix. Probing the spawn attributes
   individually localized it:

   ```
   $ python3 attr_probe.py
   setsid(): rc=7834 errno=0
   setgroups(0): rc=-1 errno=1
   prctl(PR_SET_PDEATHSIG=1, SIGTERM): rc=0 errno=0
   setgid(0): rc=0 errno=0
   setuid(0): rc=0 errno=0
   ```

   Cause: `SysProcAttr.Credential{0,0}` makes Go's `exec` call `setgroups` in the
   child. Fix: set `Credential.NoSetGroups`, which suppresses that call and nothing
   else; omitting `Credential` entirely has the same effect here, since we are already
   0:0.
2. **Namespace clone flags** — dropped (`CLONE_NEW*` = 0) for the enter child. The
   runtime would grant the mount namespace, but it is worthless without `mount(2)`,
   and `pivot_root(2)` additionally requires the new root to be a mount point.
3. **tar chown wall** — extraction switched to `--no-same-owner` under restriction
   (§4.1); ownership metadata is lost, which is acceptable given the runtime never
   permits non-root ownership anyway.
4. **pivot_root → chroot** — replaced by `chroot(2)` + `chdir("/")`.
5. **Skipped subsystems** — cgroup2 setup (needs `mount`), hostname (shared UTS
   namespace; renaming would leak to the host), capability dropping (capset semantics
   under a seccomp-restricted root are pointless), and `nsenter`-based `exec`
   (setns denied) — the latter re-routed to a fresh chroot enter.
6. **An experimental artifact worth documenting**: during testing, "detached"
   containers appeared to die instantly and `ps` showed them stopped. The actual
   cause was `PR_SET_PDEATHSIG`: our test harness wrapped `lilipod start` in
   `timeout(1)`, whose exit SIGTERM'd the container's parent, which pdeath-killed the
   container. Started without the harness wrapper, the container survives and is
   correctly reported:

   ```
   $ lilipod-patched start t9   # started detached, no harness
   $ lilipod-patched ps
   CONTAINER ID                    	IMAGE        	COMMAND           	... STATUS 	LABELS	NAMES
   82f696175c08fe04cd4bf22182d109f6	alpine:latest	/bin/sh -c slee...	... running	      	t9
   ```

   Running-state detection works because lilipod scans `/proc/*/root/run/.containerenv`,
   and `/proc/<pid>/root` is readable for chrooted processes in this runtime.

The patch (5 files changed, 278 insertions, 21 deletions; full diff in Appendix B)
adds a `sandbox.Restricted()` probe package and the fallbacks above.

### 4.3 Results with the patch

| Operation | Result |
|---|---|
| `pull alpine:latest` | works |
| `run --rm -i --userns host alpine /bin/echo ...` | works — `hello-from-patched-lilipod` |
| `run` + `apk --version` inside | works — `apk-tools 3.0.6-r0` |
| `create` / `start` (detached) / `ps` (running) / `stop` / `rm` | all work |
| `logs` | works (empty for silent payloads) |
| `-v /host/dir:/data` volumes | work as snapshot copies (not live mounts; `:ro` not enforceable) |
| `exec` into a running container | **broken** (§4.4) |
| `--tty` (PTY allocation) | **broken** — no `/dev/ptmx` reachable in a chroot without devpts |

Representative captures:

```
$ lilipod-patched run --rm -i --userns host alpine:latest /bin/echo hello-from-patched-lilipod
container_utils.go:582 [warn] restricted runtime: container will share host namespaces
rootfs_utils.go:491 [warn] restricted runtime: setting up plain-chroot rootfs (no mounts)
hello-from-patched-lilipod

$ lilipod-patched run --rm -i --userns host alpine:latest /bin/sh -c 'cat /etc/os-release | head -2; ls / | tr "\n" " "; echo; id'
NAME="Alpine Linux"
ID=alpine
bin dev etc home lib media mnt opt proc pty root run sbin srv sys tmp usr var
uid=0(root) gid=0(root) groups=65534(nobody),65534(nobody),...
```

(The `pty` entry in `/` is the pty agent lilipod injects; `/proc`, `/dev` remain as
shipped in the image — empty.) A warm `run --rm ... /bin/true` completes in
**0.088 s** wall-clock.

### 4.4 The residual `exec` bug

`exec` spawns a fresh chroot-enter child whose `exec.LookPath("/bin/sh")` fails with
`stat /bin/sh: no such file or directory` *after* a successful chroot into a rootfs
where the same path demonstrably resolves (a manually-invoked `enter` with the same
config execs `/bin/sh` and runs; a standalone Go program doing
`chroot(rootfs); exec.LookPath("/bin/echo")` also succeeds in this runtime). The
diverging factor is confined to `cmd/exec.go`'s config/env plumbing. We report it as
the single broken lifecycle operation and leave it unlocalized.

---

## 5. Rootless podman

Podman 5.8.2 is preinstalled (and `docker` is an alias for it). Rootless mode is
doubly impossible:

1. *Becoming unprivileged is denied*: `setuid(1000)` → `EINVAL` (§2.2). "Rootless"
   requires a non-root uid; no process on this runtime can acquire one. This alone is
   decisive and needs no namespace argument.
2. Even ignoring that, rootless podman's first action is to establish a user namespace
   (`podman unshare`), and `unshare(2)` is denied — as is any path to `CLONE_NEWUSER`,
   since the runtime's one demonstrated namespace grant is `CLONE_NEWNS` via `clone(2)`
   (§2.2), which does not help a rootless engine that still cannot become non-root.

Rootful podman cannot initialize either, for want of standard directories:

```
$ podman info
Error: no such file or directory
$ podman unshare echo ok
Error: no such file or directory
```

`/run`, `/var`, `/etc/containers` do not exist and cannot be created (`/` and `/etc`
are not writable; §2.3). Redirecting `XDG_RUNTIME_DIR`, `CONTAINERS_STORAGE_CONF`
and `CONTAINERS_REGISTRIES_CONF` into `/workspace` does not clear the failure. And
even with storage solved, a podman container requires `mount(2)` and `pivot_root` —
both denied. **Verdict: no path exists on this runtime.**

---

## 6. apptainer

### 6.1 Getting a runnable apptainer at all

The 1.5.3 `.deb` was unpacked (`ar x` + `tar xf data.tar.xz`) and given a minimal
chroot: synthesized `/etc/passwd` + `/etc/nsswitch.conf` (none exist on the host),
the host runtime's glibc (the deb binary links against the system loader), the CA
bundle copied from the host, and — because
`/proc` cannot be mounted — a **static `/proc/self/mountinfo`**. The mountinfo
contents matter: apptainer cross-checks the `st_dev` of directories against the
table. A verbatim copy of the *host's* mountinfo fails:

```
$ cp /proc/self/mountinfo <chroot>/proc/self/mountinfo
$ chroot <chroot> /usr/bin/apptainer exec docker://alpine:latest echo hi
INFO:    Converting OCI blobs to SIF format
FATAL:   ... unable to create new build: failed to find mount point for /tmp:
         no parent mount point found
```

because the chroot's `/tmp` lives on the zfs device, not the tmpfs the host table
claims. A two-line synthetic table naming the real device (`0:38`, zfs) of the
extraction filesystem clears this stage.

With that, the version command works, and `exec docker://alpine` proceeds through
TLS, pull, and SIF conversion — and dies at the chown wall during layer unpack:

```
$ chroot <chroot> /usr/bin/apptainer exec docker://alpine:latest echo hi
INFO:    Converting OCI blobs to SIF format
INFO:    Starting build...
INFO:    Fetching OCI image...
INFO:    Extracting OCI image...
FATAL:   ... while unpacking layer sha256:55afa1e...: unpack entry: etc/shadow:
         apply hdr metadata: restore chown metadata:
         lchown .../rootfs/etc/shadow: invalid argument
```

(The x509 waypoint that precedes this — `certificate signed by unknown authority`
until the CA bundle is installed — is quoted from the session log at 16:09 UTC; the
cached layers in the re-run made a cheap reproduction impossible.)

This is the same `EINVAL`-on-`chown` wall as stock lilipod's tar, but it cannot be
shimmed the way one might hope: apptainer's unpacker is Go, and Go's `os` package
issues `lchown` as a direct syscall, so an `LD_PRELOAD` interposer never sees it.

### 6.2 Even with a SIF in hand

Apptainer's runtime paths are each independently denied: image mounting needs
`mount(2)` (denied), the `squashfuse` fallback needs `/dev/fuse` (absent,
uncreatable), and rootless mode needs `CLONE_NEWUSER`, which no available call
provides here. Its `proot` integration would not have rescued the run in any case: it
wraps `mksquashfs` during image *building*, not container execution, and it needs
`ptrace(2)`, which is denied. The tool is architecturally excluded on this runtime,
and unlike lilipod its exclusion point (the Go direct-syscall unpacker) is not
patchable at the libc boundary.

---

## 7. runimage

runimage (VHSgunzo) is a single-file (121 MB, static-pie) portable container: an
Arch Linux rootfs in a DwarFS image, containerized at runtime by static bubblewrap +
tini, normally mounted via FUSE from unprivileged user namespaces.

### 7.1 As designed: two walls and a landmine

```
$ ./runimage-x86_64 bash -c 'echo inside-runimage'
runimage-x86_64: failed to utilize FUSE during startup!      # wall 1: no /dev/fuse
...                                                          # landmine: extraction fallback, see below
bwrap: Failed to make / slave: Operation not permitted        # wall 2: mount(2)
```

Full transcript (filtered):

```
$ TMPDIR=/workspace/tmp RIM_ALLOW_ROOT=1 RIM_NO_NVIDIA_CHECK=1 \
    ./runimage-x86_64 bash -c 'echo inside-runimage'
runimage-x86_64: failed to utilize FUSE during startup!
0%...100%                                          # extraction completes
[ INFO ]: Bind $TMPDIR to: '/tmp/.r0/run/9417/tmp'
[ WARNING ]: Nvidia driver check is disabled!
bwrap: Failed to make / slave: Operation not permitted
2026/09/06 17:06:58 connection error: dial unix /tmp/.r0/run/9417/sock: ...
```

(`RIM_ALLOW_ROOT=1` is required because runimage refuses to run as uid 0 at all, on
any host; `RIM_NO_NVIDIA_CHECK=1` skips a driver download triggered by the host GPU.)

The landmine: with the default `TMPDIR=/tmp` (a 64 MB tmpfs, §2.3), the extraction
fallback fails with thousands of `dwarfs ... archive_error: short write: -20 != N`
errors. The `-20` is not an errno — it is libarchive's `ARCHIVE_WARN` status code,
returned by `archive_write_data` and formatted verbatim by the dwarfs extractor, which
throws when the write returns fewer bytes than requested. The underlying write failure
is `ENOSPC`: the extracted payload is several hundred megabytes and `/tmp` holds 64 MB.
Pointing `TMPDIR` at the zfs `/workspace` makes extraction complete in ~40 s. The
portability lesson is about the *size* of `/tmp`, not about tmpfs semantics, and it
generalizes to any tool that extracts a large payload into a default temporary
directory.

Bubblewrap's failure is decisive and matches §2.2. bwrap's clone flags unconditionally
include `CLONE_NEWNS`, and that clone succeeds here; its first mount operation,
`mount(NULL, "/", NULL, MS_SILENT|MS_SLAVE|MS_REC)`, then returns `EPERM`. The call is
unconditional and there is no bwrap flag that avoids it. The distinction is visible in
the message: a rejected namespace clone would have produced `Creating new namespace
failed`, not `Failed to make / slave`.

### 7.2 The chroot bypass

`--runtime-extract` unpacks the payload once into `RunDir/` — an Arch Linux rootfs
(298 MB by `du`, before the package installs below) plus a static toolset. Since
runimage's own launcher is the only thing that requires bubblewrap, the rootfs can be
entered directly:

```sh
R=/workspace/runimage/RunDir/rootfs
cp /etc/resolv.conf $R/etc/resolv.conf    # DNS
# pacman requires /etc/mtab; the image ships it as an absolute symlink into /proc,
# which dangles without /proc — replace with a static file:
printf 'rpool / zfs rw,xattr,posixacl 0 0\ntmpfs /tmp tmpfs rw,nosuid,nodev 0 0\n' > $R/etc/mtab
chroot $R /bin/bash
```

Results:

```
$ chroot $R /bin/bash -c 'cat /etc/os-release | head -2; pacman -Q | wc -l; python -V'
NAME="Arch Linux"
PRETTY_NAME="Arch Linux"
210
Python 3.14.7

$ chroot $R /usr/bin/pacman -S --noconfirm --needed tree
:: Processing package changes...
installing tree...

$ chroot $R /usr/bin/tree -L 1 /etc/apk    # tree demonstrably runs (path chosen
/etc/apk  [error opening dir]               # poorly: /etc/apk is apk-specific)
0 directories, 0 files
$ chroot $R /usr/bin/pacman -S --noconfirm --needed python # completes (session log, 16:16 UTC)
```

Package installation against live repositories (core, extra, multilib,
chaotic-aur, blackarch) works, including signature verification — modern TLS and
crypto use the `getrandom(2)` syscall, which this runtime permits. HTTPS from inside
the chroot was verified directly (a `urllib` fetch of a public URL succeeded).

### 7.3 Packaging with onelf

onelf (0.3.3, prebuilt) packs a directory tree into a single executable whose
runtime tries, in order: memfd (single static entrypoint only) → FUSE via user
namespace → FUSE via fusermount3 → tmpfs via user namespace → a private runtime
directory (rundir) → persistent cache. On this runtime the ladder degrades exactly
as the sandbox dictates — every invocation prints:

```
fusermount3: fuse device /dev/fuse not found. Kernel module not loaded?
onelf-rt: fuse: mount failed: fusermount3 exited with exit status: 1
onelf-rt: tmpfs: enter_namespace failed: unshare: Operation not permitted (os error 1)
```

— and lands on **rundir**: eager extraction into a private directory, cleaned at
exit. (The tmpfs rung fails at `unshare(2)`, not at the mount: onelf's ephemeral mode
enters its namespace with `unshare`, which this runtime refuses outright.)

Two adjustments were needed:

1. **Symlink policy**: onelf refuses any bundle symlink whose target is absolute, or
   whose `..` components climb above the package root (`onelf-rt: extraction failed:
   onelf: symlink target escapes package root`). Absolute targets are the common case
   in a distribution rootfs — they are correct only once the tree is `/` — and this
   Arch rootfs holds 26 of them (e.g. `/etc/mtab → /proc/mounts`) alongside 1,558
   legitimate relative ones. A sanitizing copy (rewrite-or-drop) precedes packing.
2. **Entrypoint**: a small `utils/onelf-entry` script (shipped inside the bundle)
   resolves the extraction root via onelf's `$ONELF_DIR` environment variable,
   maintains the static `/etc/mtab`, and `exec chroot`s into the rootfs
   (Appendix B.2).

Pack and run (the content figure is onelf's sum of apparent file sizes over the whole
prepared `RunDir/` tree, after the §7.2 installs, counting each hard link separately —
not comparable to the `du` figure in §7.2):

```
$ onelf pack packdir/RunDir -o runimage-arch.onelf --command utils/onelf-entry
  Content: 603.7 MB
  Dedup:   12.3 MB saved by sharing identical content
  Payload: 213.6 MB (zstd level 12)
  Output:  215.2 MB (ratio: 2.81x)          # ~12 s

$ ./runimage-arch.onelf bash -c 'cat /etc/os-release | head -1; pacman -Q | wc -l'
NAME="Arch Linux"
214
```

Cold start (cache cleared) is **3.8 s**; warm runs skip extraction entirely in
cache mode. With `ONELF_MODE=cache`, mutations persist across invocations:

```
$ ONELF_MODE=cache ./runimage-arch.onelf pacman -S --noconfirm --needed sl
installing sl ...                                           # completes

$ ONELF_MODE=cache ./runimage-arch.onelf bash -c 'command -v sl && echo PERSISTED'
/usr/sbin/sl
PERSISTED
```

The deliverable is one 225,641,729-byte executable that is simultaneously the
container, the rootfs, and the means of entering it.

---

## 8. Comparative analysis

| Capability | lilipod (stock) | lilipod (patched) | rootless podman | apptainer | runimage (as designed) | runimage (chroot + onelf) |
|---|---|---|---|---|---|---|
| Pull image | ✅ | ✅ | ❌ (init fails) | ✅ | n/a (bundled) | n/a (bundled) |
| Unpack to rootfs | ❌ chown EINVAL | ✅ (`--no-same-owner`) | — | ❌ chown EINVAL (Go direct syscall) | ✅ (DwarFS, needs a `TMPDIR` with room) | ✅ |
| Start container | ❌ setgroups EPERM | ✅ | ❌ | ❌ (every path denied) | ❌ bwrap mount EPERM | ✅ |
| Package manager inside | — | ✅ apk present; apk network installs untested beyond `--version` | — | — | ✅ pacman | ✅ pacman, verified installs |
| `exec` into running container | — | ❌ (bug, §4.4) | — | — | — | not attempted (n/a for chroot model) |
| PTY / `--tty` | — | ❌ | — | — | — | ❌ |
| Single-file distribution | (13 MB static binary) | idem | — | — | ✅ (121 MB) | ✅ 215 MB, 3.8 s cold |
| Isolation provided | namespaces (elsewhere) | chroot paths only | — | — | namespaces (elsewhere) | chroot paths only |

*(In the "as designed" column for runimage, capabilities beyond "Start container"
describe the tool on unrestricted hosts; on this runtime it cannot start at all.)*

The pattern across all four tools: **the image/registry plane works** (it is
userspace I/O over HTTPS) and **the isolation plane does not** (it is namespaces and
mounts). Every failure reduces to two denied syscalls — `unshare` and `mount` — with
`ptrace` and `mknod` closing the two escape hatches (proot, `/dev/fuse`) that tools
reach for when mounting is unavailable. Three more, `chown`, `setgroups` and `setuid`,
fail with errnos that misdirect (`EINVAL`, `EPERM`, `EINVAL`) and account for the most
confusing failure modes. The instructive negative result is that `clone(2)` is *not*
denied: the resource these tools cannot get is not the namespace, it is the mount.

---

## 9. Design implications: a no-privileges container runtime

The evidence above suggests the shape of a container runtime that works across the
entire privilege spectrum, including this runtime's zero point. We sketch it here as
a proposal; it is not implemented in this paper.

**Principle: a capability ladder, not a requirement.** The runtime probes what the
host permits and silently selects the strongest available tier — the same philosophy
onelf applies to its execution modes, and the lesson of §7.3:

1. user namespaces + mount namespaces (full isolation) when available;
2. `chroot(2)` + the machinery below when `CAP_SYS_CHROOT` exists (this paper's
   demonstrated configuration);
3. pure userland emulation — never requires any privilege (below).

The probe must test the operations it needs, not the ones it assumes imply them.
§2.2's `unshare`/`clone` split is the cautionary case: a ladder that tests
`unshare(CLONE_NEWNS)` and concludes "no mount namespaces" would be right by accident,
and a ladder that tests `clone(CLONE_NEWNS)` and concludes "mount namespaces
available" would be wrong and would fail later, deeper, and less legibly.

**Tier 3 is the interesting one, and every section of this paper contributes a
requirement to it:**

- *Filesystem virtualization without mounts* must happen at the libc boundary:
  an `LD_PRELOAD` shim that rewrites path-taking calls (`open*`, `stat*`,
  `execve`, `chdir`, ...) into a rootfs directory. This is the fakeroot/proot
  lineage, with the crucial difference that ptrace is unavailable here (§2.2), ruling
  out proot itself. (runimage's launcher stack solves an adjacent problem by a
  different route — sharun redirects the ELF interpreter rather than interposing at
  the libc boundary — so it is not a template for this tier; see §11.) §7.2
  demonstrates the payoff available even without the shim: dynamic payloads (bash,
  pacman, python) run unmodified once paths resolve into a rootfs.
- *`chown`/`setuid` emulation with sidecar metadata.* The `EINVAL` walls of §2.2 and
  §4.1/§6.1 mean ownership must be virtual: record intended uid/gid/mode in a
  per-rootfs database (fakeroot-style), report it to libc consumers via the shim,
  and re-apply it on export. Image *pull* must unpack with ownership-neutral
  semantics (`--no-same-owner`, §4.2) — never shell out to host `tar`.
- *Spawn without host credentials.* §4.2's `setgroups` finding generalizes: the
  supervisor must suppress the child's `setgroups` call — `Credential.NoSetGroups` in
  Go, or no `Credential` at all — and fake identity at the libc boundary
  (`getuid` → configured uid) instead of asking the kernel for it.
- *Devices and /proc without mknod or mounts.* The shim maps `/dev/*` opens to the
  host's device nodes by path (no `mknod` — impossible per §2.2) and synthesizes
  `/proc` views from the host's, filtered to the container's process subtree.
  §6.1's synthetic `/proc/self/mountinfo` (device-consistent) got one tool through one
  stage, which is encouraging for the subset of programs that only read mount tables
  and is not yet evidence for more.
- *Process model without pid namespaces.* lilipod's `/proc/*/root/<marker>` scan
  (§4.2) works in this runtime and generalizes: the supervisor tracks its own
  process subtree via `pidfd`/`SIGCHLD`; `exec` re-enters through a socket
  handshake that passes the shim and rootfs handle.
- *Static and Go payloads.* The one population the libc-boundary shim cannot
  virtualize: Go runtimes and static binaries issue syscalls directly (apptainer's
  un-shimmable `lchown`, §6.1, is the proof). The ladder again: detect via ELF
  inspection (`PT_INTERP` absence; Go-specific markers), report the mode honestly,
  and offer a ptrace assist tier where ptrace exists (not here).
- *Distribution.* A fully static single binary is memfd-eligible and onelf-packable
  (§7.3): the runtime, the shim(s), and optionally a rootfs can ship as one file
  with delta updates. Bundle symlinks must be relative and root-contained, since the
  packer enforces that (§7.3).

**What this design is not:** a security boundary. In tiers 2 and 3 the "container"
is path virtualization around an ordinary process; it must be positioned as
environment reproducibility (the threat model of CI steps, dev shells, agent
sandboxes whose boundary is exterior), never as isolation. The runtime should print
which tier it achieved — users who believe they have namespaces when they have a
chroot are worse off than users told the truth.

---

## 10. Limitations

- Single runtime, single CPU arch, one day of wall-clock time. The seccomp profile
  studied is one point in a space; we characterize it precisely rather than claim
  generality.
- Table 1 mixes direct probes with verdicts read off tool behaviour. Tool behaviour is
  weaker evidence and can be ambiguous — `fork/exec ...: operation not permitted` is
  emitted for a rejected `clone` and a rejected `setgroups` alike — so §2.2 records a
  verdict only where some witness distinguishes the alternatives. Syscalls not listed
  there were not resolved.
- The lilipod patch was carried to "works for the primary lifecycle" depth; `exec`
  remains broken (§4.4) and no attempt was made to upstream it.
- onelf timing (3.8 s cold) reflects one host and one payload (603.7 MB content);
  the pack figure (12 s) likewise.
- §9 is a design informed by evidence, not an implementation; its central bet —
  that libc-boundary virtualization suffices for the dominant container workloads —
  is supported here only by the unmodified success of dynamic payloads in §7.2.

## 11. Related work

The tools studied: lilipod [1], podman [2], apptainer/singularity [3], runimage
[4]. The packaging layer: onelf [5], which builds on the AppImage-style single-file
distribution idea with a fallback-ladder runtime. The userland-virtualization
lineage: fakeroot [6] (LD_PRELOAD ownership virtualization), proot [7] (ptrace-based
filesystem virtualization), bubblewrap [8] (unprivileged sandboxing via user
namespaces), and sharun [9], runimage's launcher, which takes a different route from
the LD_PRELOAD lineage: it maps the ELF interpreter into memory via userland-execve and
patches interpreter and RPATH so dynamically linked binaries run from any prefix.
DwarFS [10] is runimage's filesystem layer.

[1] https://github.com/89luca89/lilipod
[2] https://github.com/containers/podman
[3] https://github.com/apptainer/apptainer
[4] https://github.com/VHSgunzo/runimage
[5] https://github.com/qaidvoid/onelf
[6] fakeroot: https://tracker.debian.org/pkg/fakeroot
[7] proot: https://proot-me.github.io
[8] https://github.com/containers/bubblewrap
[9] https://github.com/VHSgunzo/sharun — run dynamically linked ELF binaries everywhere
[10] https://github.com/mhx/dwarfs

## 12. Conclusion

On a runtime where mounts, `unshare`, ptrace and device creation are denied:
podman is unreachable; apptainer reaches furthest (full registry + SIF build) and
dies at an unshimmable `chown`; lilipod is one ~280-line patch away from a working
chroot-based lifecycle; and runimage's distribution payload — entered by chroot and
packaged with onelf — delivers the most complete result: a single 215 MB executable
containing a full Arch Linux with working package management and a 3.8 s cold start.
The viable design center for this environment class is not another namespace
orchestrator but a runtime that degrades from namespaces to chroot to libc-boundary
virtualization, and that states plainly which tier the user actually got. The most
transferable lesson is smaller and sharper: in a seccomp-filtered environment the
denials do not respect the categories the tooling is built around, so a runtime must
probe for the operation it needs rather than for the privilege that usually implies it.

---

## Appendix A: experiment log index

Mechanically captured transcripts, one file per command, under `evidence/`
(93 files; timestamps UTC 2026-09-06). Selected index:

| File | Contents |
|---|---|
| `env-*.txt` (22 files) | runtime characterization probes of §2 |
| `lilipod-stock-*.txt` | stock build: version, pull, run failures |
| `lilipod-patched-*.txt` | patched build: pull, run, create/start/ps |
| `lilipod-p2-*` … `lilipod-p8-*` | lifecycle series, volume test, ps-running, final smoke test |
| `env-spawnattr.txt` | setsid/setgroups/prctl/setgid/setuid probe |
| `podman-*.txt` | podman version/info/unshare/rootless attempts |
| `apt-*.txt` | apptainer version, mountinfo variants, lchown failure |
| `runimage-fuse-fail`, `rim1-3.log` | runimage FUSE/bwrap failures, TMPDIR landmine |
| `runimage-chroot-enter`, `runimage-pacman-install` | chroot bypass results |
| `onelf-*.txt` | pack, run, cache persistence, info, cold-start timing |
| `lilipod-patch.diff` | the complete patch of §4 (420 lines including context and headers) |

## Appendix B: the lilipod patch and the onelf entrypoint

### B.1 Patch summary (5 files changed, +278/−21; full diff in `evidence/lilipod-patch.diff`)

- **`pkg/sandbox/restricted.go` (new)** — `Restricted()`: probed once; true iff uid 0
  and `unshare(CLONE_NEWNS)` fails. On unrestricted hosts running as root, the probe
  puts the caller in a private mount namespace, which the rootful path wants anyway.
- **`pkg/procutils/proc_utils.go`** — `EnsureFakeRoot` short-circuits under
  restriction (no namespace re-exec). This is the wall stock lilipod hits first at
  uid 0, since `ROOTFUL` defaults to true there (§4.1).
- **`pkg/containerutils/container_utils.go`** — enter-command spawn: no clone flags,
  no `setgroups` (`Credential.NoSetGroups`, the wall of §4.2), no uid/gid maps under
  restriction; `generateExecCommand` re-enters via a fresh chroot instead of `nsenter`.
- **`pkg/containerutils/rootfs_utils.go`** — `setupRootfsRestricted`: mkdir
  `tmp/run/dev/etc`, copy `/etc/resolv.conf`, volumes as snapshot copies, write
  `/run/.containerenv` (which powers `ps` running-state detection); `RunContainer`:
  `chroot`+`chdir` instead of `pivot_root`; skip cgroup2 setup, hostname, capability
  dropping.
- **`pkg/fileutils/file_utils.go`** — `UntarFile` adds `--no-same-owner` under
  restriction (the `chown` wall).

### B.2 The onelf entrypoint (`utils/onelf-entry`, verbatim)

```sh
#!/bin/sh
# onelf entrypoint: run the bundled runimage rootfs via chroot.
set -eu

DIR="${ONELF_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
ROOT="$DIR/rootfs"

if [ ! -d "$ROOT/usr" ]; then
	echo "onelf-entry: rootfs not found at $ROOT" >&2
	exit 1
fi

# /etc/mtab: pacman & friends read it; /proc is unavailable in this
# sandbox, so keep the static file shipped in the rootfs.
if [ -L "$ROOT/etc/mtab" ] || [ ! -e "$ROOT/etc/mtab" ]; then
	rm -f "$ROOT/etc/mtab"
	printf 'rpool / zfs rw,xattr,posixacl 0 0\ntmpfs /tmp tmpfs rw,nosuid,nodev 0 0\n' \
		> "$ROOT/etc/mtab"
fi

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export TERM="${TERM:-xterm}"

if [ "$#" -eq 0 ]; then
	set -- /bin/bash -l
fi

exec chroot "$ROOT" "$@"
```

*End of paper.*
