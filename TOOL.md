# TOOL.md — build order for `podbox`

*A container runtime for environments that hand you root and then refuse almost
everything root is for.*

You are reading this because you are about to implement it and you have no prior
context. This file is written for exactly that: it assumes you know Linux and
containers, and nothing about this repository. Everything it asserts is either
reproducible by a command it names or tagged as unverified.

**Last revised 2026-09-08.** The research it rests on is `paper_final.md`.

---

## 0. What this document does not establish

Before the recommendation, not after it.

| Not established | Why it matters to you |
|---|---|
| **The third mechanism (M) has never been verified on a machine you can run.** The write allowlist, the `move_mount` denial and the `/proc/pid/mem` O_RDWR refusal come from one session on one machine plus kernel source. The reconstruction can model M with Landlock, but the kernel it was developed on has none, so those rows are `SKIP`. | Do not hard-code the allowlist `{/tmp,/dev/shm,/workspace,/state}`. **Probe it.** §6.1. |
| **Nobody has built podbox.** Every line of §5 and §6 is a specification. No milestone has been implemented, no acceptance test has ever passed. | Treat estimates as estimates. Where a design choice looks wrong once you have code in front of you, the code wins. |
| **The seven-tool corpus (`paper_final.md` §11a) is one session, unrepeatable.** Only two of its mechanisms were checked against upstream source. | Re-verify any verdict you are about to build on. §7 gives commits. |
| **The lilipod v2 patch was measured on the target, not here.** Its lifecycle capture contains a *failed* run before the passing one — it is racy under a fixed sleep. | It is a source of lessons, not a seed. §3 explains why you will not be reusing its code at all. |
| **No timing in this corpus is a benchmark.** No repetition counts, no variance, no defined boundary. | Do not quote "0.088 s warm launch" at anyone. Measure your own. |
| **Whether `-t` can ever work here is unresolved.** The target's mount table shows no `/dev/ptmx`; an earlier account asserts the outer one works and published no capture. | §6.5. One `stat("/dev/ptmx")` on the target settles it. Until then, probe and refuse. |
| **The previous revision of the research got six claims wrong**, corrected in this one. | That is the only honest estimate of how many are still wrong. Assume more remain. |

---

## 1. Route by budget

| You have | Read |
|---|---|
| two minutes | §2 (the runtime) and §3 (the language) |
| ten minutes | §2, §3, §4 (architecture), §5 (build order) |
| the implementation to do | all of it, in order, then `paper_final.md` §9 and §10 |
| a reason to distrust this | §0, then §7 (provenance and verdicts), then run `experiments/30-attribution-census.sh` |

---

## 2. The problem, in sixty seconds

You are running inside a Linux sandbox that **presents itself as fully privileged
root while denying almost every operation containers are built on**. These are
common: AI-agent sandboxes, hardened CI executors, locked-down HPC nodes.

| You have | You do NOT have |
|---|---|
| uid 0, every capability bit set, `Seccomp: 2` | `unshare(2)` — EPERM, any namespace |
| `chroot(2)` | `mount(2)`, `pivot_root(2)` — EPERM, even inside a mount ns you own |
| `clone(2)` **with namespace flags** — they succeed | `ptrace(2)` — EPERM (no strace, no PRoot) |
| `fsopen`/`fsmount`/`open_tree`/`mount_setattr` — mounts you can *create* | `move_mount(2)` — EPERM: you can never *attach* one |
| `memfd_create` + `fexecve`, `setsid`, `prctl` | `mknod(2)` — EPERM (no device nodes, no `/dev/fuse`, **no `/dev/ptmx`**) |
| `seccomp` — including your own notification listener | `process_vm_readv`/`writev` — EPERM |
| `/proc/<pid>/mem` read-only | `/proc/<pid>/mem` read-write — EACCES |
| full network, shared host netns, HTTPS egress | `setuid`/`setgid` to a non-zero id — **EINVAL** |
| `getrandom(2)`, netlink, `sysinfo(2)` | `chown` to anything but `0:0` — **EINVAL** |
| writable: `/tmp` (64 MiB!), `/workspace`, `/state`, `/dev/shm` | writes anywhere else — a path allowlist |

There is **no `/etc/passwd`**, no `/run`, no `/var`, no `/dev/fuse`, no `/dev/ptmx`,
no `/sys`. `docker` on PATH is a podman alias with no daemon. Plain-HTTP (tcp/80)
egress is broken; HTTPS works.

### 2.1 Three mechanisms, not one

Everything above is produced by three independent mechanisms, and **telling them
apart is the whole job**, because two of them can return the same errno for the
same call.

| | mechanism | what it produces | how you recognise it |
|---|---|---|---|
| **N** | a user namespace whose map has a single entry (`0 -> 1000`), `setgroups` denied, holding a mount namespace it owns | `EINVAL` from `setuid`/`chown` to any other id; `EPERM` from `setgroups` and from `mknod` with a real device number; `EACCES` writing into a directory whose owner is **unmapped** | `EINVAL`, not `EPERM`. An unmapped id is not a permission problem, it is a *nonexistent* id. |
| **F** | a seccomp filter denying `unshare`, `setns`, `mount`, `umount2`, `pivot_root`, `ptrace`, `process_vm_readv`, `process_vm_writev` | `EPERM`, unconditionally, before the syscall body runs | `EPERM` **for an argument the kernel would reject**: a path that cannot exist, a pid that cannot exist. |
| **M** | a path-scoped LSM (a single Landlock ruleset explains every observation) | `EACCES` writing outside the allowlist even where the owner *is* mapped; `EPERM` from `move_mount`; `EACCES` opening anything through a detached mount; `EACCES` on `/proc/pid/mem` O_RDWR | a **path-shaped** errno for a syscall that provably executed. |

**The discriminator, and you will use it constantly.** A seccomp filter sees the
syscall number and six argument registers, cannot dereference a pointer, and runs
before the syscall body. So call the syscall with an argument the kernel rejects
*inside* the body:

```
mount(2) with a nonexistent target   -> ENOENT   the syscall executed
mount(2) with a nonexistent target   -> EPERM    a filter refused it
move_mount to a nonexistent dest     -> ENOENT   executed; an EPERM elsewhere is an LSM
process_vm_readv on pid 999999       -> ESRCH    executed
process_vm_readv on pid 999999       -> EPERM    filtered
```

Run it yourself: `./experiments/30-attribution-census.sh`.

### 2.2 The four walls every tool hits

Named so you stop re-deriving them. `paper_final.md` §9 has the full treatment.

1. **Ownership.** `chown`/`lchown` to an unmapped id returns **`EINVAL`**. This
   stops GNU tar, containers/storage's layer applier, Apptainer's Go unpacker,
   pacman's `DownloadUser` and rurima's `tar -xpf` — five tools, one wall.
   `/etc/shadow` is the usual first casualty because it is `root:shadow`, gid 42.
2. **Credentials.** Go's `os/exec` issues `setgroups` in the child whenever
   `SysProcAttr.Credential` is non-nil. Under this runtime that is `EPERM`, and it
   surfaces as `fork/exec <path>: operation not permitted` — which reads like a
   missing binary and is not.
3. **Interposition reach.** `LD_PRELOAD` never sees a Go program's `lchown`, with or
   without cgo, because Go's `os` package issues it as a raw syscall. Static
   binaries are equally out of reach. This is a property of the *payload*.
4. **Mounts.** You can create a mount and never attach it. Every mount-shaped
   requirement is unsatisfiable: bubblewrap's `MS_SLAVE`, overlayfs, `pivot_root`,
   FUSE.

---

## 3. The language: Rust

**Decision: Rust, `x86_64-unknown-linux-musl`, `crt-static`.** Not Go, which the
earlier draft of this document specified.

This is not taste. `paper_final.md` is largely a catalogue of things that go wrong
when a language runtime makes process-level decisions on your behalf, and podbox is
a program whose entire job is process-level decisions.

### 3.1 What was measured

`./experiments/40-language-selection.sh`, one build of one trivial program each, on
one host (kernel `6.18.44-fc-v24`, rustc 1.94.1, go 1.24.7, gcc 13). Not a
benchmark; sizes are orders of magnitude.

| | static, no `PT_INTERP` | threads at `main()` | `unshare(CLONE_NEWUSER)` unconfined | `LD_PRELOAD` hooks a C payload | survives the payload forking | threads injected into the host | interposer size |
|---|---|---|---|---|---|---|---|
| **Rust** (musl) | yes | **1** | **OK** | yes | yes | **0** | 312 K |
| **Go** (`CGO_ENABLED=0`) | yes | **5** | **EINVAL** | yes (c-shared) | yes | **6** | 2.0 M |
| **C** (control) | yes | 1 | OK | yes | yes | 0 | 16 K |

### 3.2 Why those rows decide it

- **Go cannot `unshare(CLONE_NEWUSER)` at all**, on any host, confined or not. The
  kernel refuses it to a multithreaded caller and the Go runtime is multithreaded
  before `main()`. This is `paper_final.md` F11, and it is a language property, not
  a sandbox property. A runtime that must *probe* namespace availability cannot be
  written in a language that structurally fails the probe.
- **`PR_SET_PDEATHSIG` fires when the creating *thread* exits**, not on any
  ancestor's death. In a Go supervisor this produces surprising early exits that
  look like crashes. `paper_final.md` §10.6.
- **Go's `syscall.Unshare` mutates only the calling thread**, so even a successful
  call leaves the process half-transitioned — worse than either outcome.
- **The interposer is not optional.** It is the whole `interpose` tier. A Go
  c-shared object does hook the symbol, but it drags the Go runtime into every
  process it hooks: 6 extra threads and 2 MB, injected into `dpkg`, `tar`, `make`
  and every `configure` script. That is a different program running under your
  users' payloads.
- **Size matters here specifically.** The memfd launch rung needs a static,
  dependency-free entrypoint, and the artefact gets packed into a single file.

### 3.3 What choosing Rust costs, stated plainly

- **The lilipod v2 patch (`patches/lilipod-restricted-v2.diff`, +532/−34, Go) is not
  a seed.** You will not apply it. Its value is the list of things it learned the
  hard way, and §5 carries every one of them explicitly so that nothing is lost with
  the code.
- **Rust is not installed on the target** (`paper_final.md` §3.6). This does not
  matter: podbox ships as a static binary, so the build host need not be the target.
  A `rustup` install into `/workspace` works there if you need it — the second
  target session built two Rust tools that way.
- **`unsafe` is unavoidable.** Roughly every syscall in §6.1 is a raw one. Confine it
  to one module per subsystem, with the safe wrapper adjacent.

### 3.4 Toolchain and crates

Versions are what the index carried on 2026-09-08; pin exact versions in
`Cargo.toml` and update deliberately.

```toml
# rust-toolchain.toml: stable, target x86_64-unknown-linux-musl
# .cargo/config.toml: rustflags = ["-C", "target-feature=+crt-static"]

[profile.release]
lto = true; opt-level = "z"; codegen-units = 1; strip = "symbols"; panic = "abort"
```

| need | crate | version | note |
|---|---|---|---|
| syscalls | `rustix` | 1.1.4 | prefer over `libc` where it covers the call; `linux_raw` backend needs no libc |
| syscalls not in `rustix` | `libc` | 0.2.x | `fsopen`, `fsmount`, `move_mount`, `open_tree`, `seccomp` ioctls may need hand declarations |
| process/fd plumbing | `nix` | 0.31.3 | pidfd, waitid, signalfd |
| seccomp BPF | `seccompiler` | 0.5.0 | pure Rust, no libseccomp C dependency — keeps the static build clean |
| Landlock | `landlock` | 0.4.7 | for podbox's own optional confinement, and to probe M |
| OCI registry | `oci-client` | 0.17.0 | pure-Rust registry client |
| OCI types | `oci-spec` | 0.10.0 | manifests, image config |
| TLS | `rustls` + `webpki-roots` | 0.23.44 / 1.0.9 | no OpenSSL, no C, statically linkable |
| HTTP | `ureq` | 3.4.1 | blocking; podbox has no reason to be async |
| tar | `tar` | 0.4.46 | but see §6.3 — you will drive it at entry level, not `unpack()` |
| gzip | `flate2` | 1.1.10 | use the `rust_backend` feature; no zlib C |
| zstd | `ruzstd` | 0.9.0 | pure Rust. `zstd` 0.14 is faster and pulls C — measure before choosing |
| digests | `sha2` | 0.11.0 | |
| JSON | `serde_json` | 1.0.151 | the ownership sidecar and the store |
| CLI | `clap` | 4.6.6 | `derive`, with the parity table of §6.8 |
| ELF inspection | `goblin` | 0.10.7 | payload classification (§6.7) |
| memfd launch | `memfd-exec` | 0.2.1 | or the ~40 lines it wraps; see §7 |

---

## 4. Architecture

### 4.1 The mode ladder

**One non-negotiable rule: report the mode you achieved, and never let a weaker mode
satisfy a stronger request.** A user who believes they have namespaces when they
have a `chroot` is worse off than one who is told the truth.

| rung | requires | provides | must never claim |
|---|---|---|---|
| `namespace` | namespace creation **and** mounts **and** ID maps for what was asked | isolation as configured | — |
| `supervise` | a seccomp notification listener, `NOTIF_ADDFD`, **and** a working channel to read the child's syscall arguments | mediation of syscalls it can read: deny, allow, substitute an fd | anything whose arguments it cannot read; on this runtime, exec remapping |
| `chroot` | `CAP_SYS_CHROOT`, a prepared rootfs, payload syscalls permitted | a root change inside the outer environment | process, network, IPC or mount isolation |
| `interpose` | a dynamically linked payload and sufficient libc coverage | path and metadata emulation for cooperative programs | any security property whatsoever |
| `unsupported` | — | a diagnostic naming the unmet requirement | — |

On the target runtime, podbox lands on **`chroot`**, with `interpose` available for
dynamically linked payloads. `namespace` is unreachable (mounts) and `supervise` is
crippled (argument reads).

`supervise` is on the ladder rather than buried as an implementation detail for one
reason: **it is the only rung whose failure is silent by default.** Its listener can
keep working after its argument-reading channel dies, and a supervisor whose
per-syscall fallback is "continue" then reports success for mediation it never
performed. That is not hypothetical — §7 records a shipped tool whose `--dry-run`
reports "no filesystem changes" while changing files. Probe all three legs; refuse
the tier if any is missing; never fall back per call.

### 4.2 Process model

Single-threaded by default, and deliberately so. Spawn threads only for log pumps
and the notification supervisor, never on the path that clones, chroots or execs.

```
podbox (launcher, pid P)
 └── enter child (fork; chroot; exec payload)
      └── payload
```

- **The launcher owns a pidfd per direct child.** Exit status via `waitid`, wakeups
  via the pidfd. Never infer container membership from the filesystem: scanning
  `/proc/*/root/<marker>` races against exit, depends on other processes' root links
  being readable, and trusts a path any writable payload can create.
- **A pidfd addresses one process.** It does not contain descendants, and it is not
  a PID namespace. Grandchildren that reparent are outside your reach. Say so rather
  than implying containment.
- **`exec` into a running container is a fresh `chroot`, not `setns`.** It shares
  the filesystem tree with the original process and nothing else. Document that.

### 4.3 Crate layout

```
podbox/
  crates/
    podbox-cli/        clap surface, the parity table of §6.8, exit codes
    podbox-probe/      §6.1 — the probe set, disposable children, mode selection
    podbox-image/      §6.2 — registry client, manifests, store, digests
    podbox-extract/    §6.3 — layers, whiteouts, ownership sidecar, path safety
    podbox-complete/   §6.4 — environment completion (dev shims, resolv.conf, distro fixups)
    podbox-enter/      §6.5 — chroot entry, fd passing, PTY, exec
    podbox-supervise/  §6.6 — pidfd, waitid, logs, restart, the notif tier
    podbox-interpose/  §6.7 — the LD_PRELOAD cdylib (separate build, embedded as bytes)
  experiments/         acceptance tests, seeded from this repository's experiments/
```

`podbox-interpose` is a `cdylib`, built separately and embedded in the launcher as a
byte array, extracted to the store on first use. It must not depend on the rest of
the tree: it runs inside other people's processes.

---

## 5. Build order

Milestones in dependency order. Each has an acceptance test that either passes or
does not; **do not proceed on a milestone whose test has never run green.**

### M0 — the probe, and nothing else

`podbox probe` prints the mode it would select, the evidence, and exits 0.

Acceptance: run it inside `./experiments/20-enter-target.sh` and on an unconfined
host. It must select `chroot` in the first and `namespace` in the second, and its
per-probe verdicts must match `experiments/results/attribute.txt` row for row.

This is first because everything downstream branches on it, and because it is the
component the prior art most consistently gets wrong (§6.1).

### M1 — image acquisition

`podbox pull`, `images`, `rmi`, `tag`, and a content-addressed store.

Acceptance: `podbox pull alpine:latest` produces the same image digest as
`docker pull`. No extraction yet.

The registry plane is ordinary HTTPS and file I/O and works fine here. It is also
the least interesting part of the problem; do not gold-plate it.

### M2 — extraction that survives the ownership wall

The single highest-risk component. §6.3.

Acceptance, in order:
1. `alpine:latest` extracts with no `chown` error and `/etc/shadow` present.
2. `voidlinux/voidlinux-musl:latest` extracts **and** `/var/cache/xbps` is not a
   symlink loop — that image ships a self-referential symlink which a later layer
   whiteouts, and plain `tar -x` leaves the loop in place. This test exists because
   it was found the hard way.
3. A crafted layer whose entry resolves outside the destination through a symlink
   created by an earlier entry in the **same** layer is refused.
4. The ownership sidecar records `etc/shadow` as `uid 0, gid 42, applied 0:0`.

### M3 — `run` on the `chroot` rung

`podbox run --rm alpine:latest /bin/echo hi`.

Acceptance: that exact command succeeds inside `./experiments/20-enter-target.sh`,
with the mode banner on stderr and `hi` on stdout, exit code 0.

This is the product requirement the whole document exists for: **an agent that knows
docker must need zero new knowledge.**

### M4 — lifecycle

`create`, `start` (detached), `ps`, `logs`, `stop`, `rm`, `exec`, `inspect`, `kill`,
`wait`, `cp`.

Acceptance: create → detached start → `ps` shows it running → `exec` prints a marker
→ `stop` → `rm`. **Run this loop 20 times and require 20 passes.** The prior art's
own capture of this lifecycle contains a failed run because it decided "running" by
sleeping three seconds and looking; §6.6 is what replaces that, and this test is
what proves it did.

### M5 — environment completion

The layer that makes package managers work. §6.4.

Acceptance: `podbox run <image> <install a package>` succeeds for alpine (apk),
debian (apt), archlinux (pacman), fedora (dnf5) and voidlinux-musl (xbps), with no
user-supplied fixups.

### M6 — the interposer

`podbox-interpose.so`, path mapping plus ownership faking. §6.7.

Acceptance: with the interposer active, `chown 0:42 <file>` **succeeds** and the
sidecar records it — the measured gap in §7's `pathmap` row. And a `-v` bind that is
a real view rather than a copy, for a dynamically linked payload.

### M7 — packaging

A single static binary; optionally one file with an embedded rootfs.

Acceptance: `readelf -l` shows no `PT_INTERP`; the binary runs on the target with no
libraries present.

---

## 6. Component specifications

### 6.1 The probe

Probing is where every prior account went wrong. The rules, each one paid for:

1. **Probe the operation you need, never the privilege that usually implies it.**
   `unshare(CLONE_NEWNS)` failing does not tell you `chroot` works.
   `clone(CLONE_NEWNS)` succeeding does not tell you that you can mount.
2. **Run every probe in a disposable child.** A successful `unshare`, `chroot` or
   `setuid` mutates the prober.
3. **Never probe `unshare(CLONE_NEWUSER)` from a multithreaded process.** It returns
   `EINVAL` unconditionally. (In Rust this is free — you are single-threaded — but
   the rule survives the day someone adds a thread pool.)
4. **Use discriminating arguments.** `mknod(S_IFCHR, makedev(0,0))` is
   `WHITEOUT_DEV` and the kernel exempts it from the capability check, so it tests
   nothing. Run *both* it and a real device number in the same directory: a whiteout
   that succeeds where `makedev(1,3)` fails proves the denial is capability-based
   and not path-based, because no path-scoped policy can tell two device numbers
   apart at one path.
5. **Record the errno, not a boolean.** `EINVAL` from `setuid`/`chown` means an
   unmapped id and points at a *mapping* fix; `EPERM` points at a policy. They are
   different diagnostics and different remedies.
6. **Read the mapping directly.** `/proc/self/uid_map`, `/proc/self/gid_map`,
   `/proc/self/setgroups` answer in one read what a dozen probes infer.
7. **Use the bogus-argument discriminator** (§2.1) to separate F from M, and carry
   its controls (`pidfd_getfd(-1,-1)` → `EBADF`) so a probe that has stopped
   discriminating says so.
8. **Probe creation and attachment separately.** `mount(2)` failing does not mean
   `fsopen`/`fsmount` fail — here they succeed.
9. **A verdict must be the operation's**, never a child's exit code unless the child
   sets it from the operation; and **"could not run" must never read as "denied"**.
   Both mistakes were live in this repository's own harness.
10. **Probe the write allowlist by writing.** Do not assume `{/tmp, /dev/shm,
    /workspace, /state}`. Try every directory the workload needs and report the set
    you got.

Minimum set, each in its own child:

```
clone(CLONE_NEWNS) | clone(CLONE_NEWUSER) | clone(CLONE_NEWUTS) + sethostname
unshare(CLONE_NEWNS) [single-threaded]
mount(tmpfs) in the current ns | mount(tmpfs) inside clone(CLONE_NEWNS)
fsopen+fsmount(tmpfs) | open_tree(CLONE) | move_mount -> a real destination
mount(2) and move_mount with a bogus path        [F-vs-M discriminator]
process_vm_readv(bogus pid) | pidfd_getfd(-1,-1) [control]
pivot_root | chroot | mknod(chr 1:3) | mknod(chr 0:0)   [pair]
ptrace(TRACEME) | seccomp(NEW_LISTENER) | /proc/self/mem O_RDONLY and O_RDWR
setuid(nonzero) | setgroups(0,NULL) | chown(f, 0, 42)
memfd_create + fexecve
write into each directory the workload needs
```

`verification/probe/` in this repository implements this set in Go
(`probe census`, `probe attribute`). Port it; do not redesign it.

Cache the result in `$store/probe.json`, keyed by boot id, and re-probe when the key
changes.

**The banner**, on stderr, once per `run`/`exec`, suppressible by config and never
by default:

```
podbox 0.1: mode=chroot (namespaces: uts-only; mounts: none; devices: shimmed;
ownership: virtualized+sidecar; network: host-shared; pids: host-shared)
probes: clone(NEWNS)=ok mount=EPERM fsmount=ok move_mount=EPERM
        clone(NEWUTS)=ok sethostname=ok chroot=ok ptrace=EPERM
```

### 6.2 Image acquisition and the store

Ordinary work; three notes specific to this environment.

- **tcp/80 is broken. HTTPS works.** Anything that falls back to plain HTTP will
  hang rather than fail.
- **`/tmp` is 64 MiB.** Choose the extraction and download destination by free
  space and check it with `statvfs` — for blocks *and* inodes — before starting.
  A payload that overshoots the default temporary directory produces an error whose
  text names neither space nor the directory. That failure cost a prior session
  real time and its error message was `short write: -20 != 33554432`, in which `-20`
  is a libarchive status code and not an errno.
- **Name the destination in the error** when the check fails.

### 6.3 Extraction

The component with the most exposure and the least room for shortcuts.

**Do the extraction in-process.** Shelling out to system `tar` inherits its
ownership semantics, its exit codes and its path behaviour. This is how the ownership
wall reaches five separate tools.

**Never restore ownership by default.** Record intended metadata in a sidecar keyed
by path, and apply it only where the target id is mapped:

```json
{"path":"etc/shadow","uid":0,"gid":42,"mode":"0640",
 "applied":{"uid":0,"gid":0},"reason":"gid 42 unmapped"}
```

The sidecar buys three things `--no-same-owner` alone does not: faithful re-export,
an honest answer to a workload that asks who owns a file, and a diagnostic that
names the gap. It changes no kernel permission check and must never be presented as
if it does.

**The OCI layer contract still applies, and dropping ownership does not discharge
it:**

- apply layers in order;
- interpret `.wh.<name>` whiteouts **after each layer**, and `.wh..wh..opq` opaque
  directories;
- preserve hard links and symlinks;
- refuse any entry whose resolved path leaves the destination, **including through a
  symlink an earlier entry in the same layer created**.

Whiteouts are load-bearing, not a nicety. `voidlinux/voidlinux-musl` ships
`/var/cache/xbps -> /var/cache/xbps` in one layer and whiteouts it in the next;
plain `tar -x` ignores the marker, leaves the self-loop, and `xbps` dies with
`failed to change dir to cachedir: Symbolic link loop`. M2's acceptance test is that
image for exactly this reason.

### 6.4 Environment completion

The layer that makes it "just work". Before any payload runs, prepare the rootfs
from image plus distro detection, idempotently, logging each fixup.

| what | why |
|---|---|
| `/dev/null` as a **regular file** | `mknod` is denied. Writes succeed, reads give EOF. Note the trap this replaces: with no `/dev/null` at all, the first shell redirection creates a growing regular file silently. |
| `/dev/zero`, `/dev/urandom` as pre-filled regular files | where a *file* suffices. `getrandom(2)` already covers TLS and crypto. |
| `/etc/resolv.conf` — **always install the host's** | docker's semantics, and they subsume two separate failures: images that ship an empty placeholder, and images that bake an unreachable build-host resolver (`192.168.122.1`, a libvirt NAT gateway, in the rocky family). |
| `/etc/hosts` | `127.0.0.1 localhost <container-name>` |
| `/etc/passwd`, `/etc/group` | synthesize them. Their absence kills Python tooling with `getpwuid(): uid not found: 0` before any syscall wall. |
| `/etc/mtab` | only where the package set reads it — pacman with `CheckSpace` enabled. **`/etc/mtab` is a symlink**: `printf ... > "$R/etc/mtab"` follows it, and if the target is absolute it escapes the rootfs entirely. Remove the link first. |
| pacman | comment out `DownloadUser = alpm` — it chowns a download directory to an unmapped uid. Initialize the keyring (`pacman-key --init; --populate`) if it is not already. |
| apt | `APT::Sandbox::User=root` (the `_apt` user is unmapped), https sources, host CA bundle |
| zypper | fix the **RIS index** under `/usr/share/zypp/local/service/` first — `refresh-services` regenerates `repos.d` from it and overwrites naive edits |
| apk, dnf, rpm | nothing needed |

Ownership `chown` failures from `dpkg`, `rpm` and `xbps` are warnings, not fatal,
once extraction was ownership-neutral. Ten distributions were driven end to end
this way; none hit a fatal ownership wall at install time.

### 6.5 Entering the rootfs

Order matters, and step 2 is the one that gets skipped:

```
1. resolve the rootfs path; refuse it if it is a symlink
2. open every fd the child needs WHILE THE OUTER ROOT IS STILL CURRENT
   (stdio, log sinks, a PTY master/slave pair, any host device the config exposes)
3. chroot(rootfs); chdir("/")
4. resolve the program path — now, inside the new root, in this process
5. exec
```

**Step 2** avoids a trap worth naming — a child with no explicit stdio opens
`/dev/null`, which an extracted rootfs does not have — and it is the only route by
which a PTY could reach a chrooted payload: allocate the pair outside, pass the fds
in, `TIOCSCTTY` in the child.

⚠ **Whether that route is open here is unresolved, and the corpus disagrees with
itself.** Allocating a pty pair means opening `/dev/ptmx` in the **outer**
environment, before the chroot. The target's mount table shows exactly six device
nodes bind-mounted into `/dev` — `full`, `null`, `random`, `tty`, `urandom`, `zero`
— no `ptmx`, no `devpts`, and `mknod` cannot create one. An earlier account of the
same runtime asserts the host `/dev/ptmx` works and published no capture. A mount
table does not list plain files, so neither source settles it.

⭐ **So probe, and make the answer visible.** `stat("/dev/ptmx")` before the
chroot; if it is absent, `-t` is a **named-reason refusal**, not a degraded PTY that
cannot open a terminal. If it is present, the sequence above works. A payload that
reopens `/dev/pts/N` by name stays unsupported either way. One `stat` on the target
closes this; nobody has run it.

**Step 4** is where a real bug lived. A prior implementation resolved the program in
a child whose environment had been replaced, so the child recomputed its store path
from an empty environment, got a *relative* path, `MkdirAll`-ed a fresh empty rootfs
under its working directory, chrooted into **that**, and reported
`stat /bin/sh: no such file or directory` — from a rootfs where that path exists.
Resolve the program in the process that has already changed root, never in the
parent and never at command-construction time. And do not strip the environment the
child needs to find the store.

### 6.6 Supervision

- **One pidfd per direct child.** `SIGCHLD` + `waitid` for exit status.
- **Never decide "running" by sleeping and looking.** Wait on the pidfd, or on a
  readiness fd the child writes to. The prior art's lifecycle capture contains a
  failed run for exactly this reason, and M4's acceptance test is 20 consecutive
  passes because one pass proves nothing about a race.
- **`PR_SET_PDEATHSIG` fires when the creating *thread* exits.** Lock the spawning
  thread, or do not rely on the signal. A wrapper such as `timeout(1)` around the
  launcher is enough to kill a detached child unexpectedly.
- **Running state is launcher state**, in the launcher. Not `/proc/*/root/<marker>`.
- **Logs**: capture to the store at spawn time from fds opened in step 2.

### 6.7 The interposer

`interpose` is a compatibility tier. It is **never** a security property, and the
banner must say so.

**Classification first**, and treat it as advisory:

| ELF property | verdict |
|---|---|
| `PT_INTERP` present | dynamically linked; interposition *may* reach it |
| `PT_INTERP` absent | static; interposition cannot reach it |
| Go build markers present | unreachable regardless of linkage, cgo or not |
| anything else | may still issue raw syscalls; no ELF property proves coverage |

Where classification says unreachable, **decline the mode with a named reason**
rather than starting and failing later, deeper, and less legibly.

**Two jobs, and conflating them is the mistake to avoid.** Measured, inside the
reconstruction (`experiments/results/interpose-tier.txt`):

| job | mechanism | status |
|---|---|---|
| **path virtualization** — rewrite path arguments so a payload sees a tree that is not there | rewrite `open*`, `stat*`, `exec*`, `chdir`, `readdir`, `getcwd`, `readlink`, `realpath`, the `*at` family via `/proc/self/fd/<dirfd>` | **proven to work here** with no mount privilege at all: a stock preload resolved `/mapped/marker` to a real file with `mount(2)` denied |
| **ownership virtualization** — make `chown` succeed and report the intended owner back | intercept `chown`/`lchown`/`fchown`/`fchownat` → return success + record to the sidecar; `stat` family reports the memo; `setuid`/`setgid`/`setgroups` → success + identity memo | **not** provided by a path interposer: the same preload left `chown 0:42` at `EINVAL`, identically to the bare call |

Do both. The second is the one that clears wall 1 (§2.2), which is the wall that
stops the most tools, and it is the half that path-mapping libraries do not have.

Also intercept: `mknod` → create a regular file; `mount` → an in-memory table plus
success; `unshare` → success and a memo, no-op; `clone` → strip namespace flags,
then the real call.

Build constraints, non-negotiable because this object runs inside other people's
processes:

- **a `cdylib` with a version script that exports only the interposed symbols.**
  Rust otherwise exports `rust_eh_personality` and friends into every process.
- **no allocation and no locks on an interposed path.** A preloaded library that
  allocates during a call it intercepts can deadlock its host.
- **no `println!`.** Write to fd 2 directly.
- **must survive the payload forking.** Every workload here forks constantly.
  `experiments/40-language-selection.sh` tests exactly this.

### 6.8 CLI parity

**Same verbs, same flags, same exit codes as docker.** Where a flag cannot be
honored it is accepted and reported in the banner — never silently ignored, never
fatal. Where a flag *requests isolation*, it fails loudly with a named reason.

Four statuses: **Native** (real semantics), **Degraded** (works, documented
difference, stated in the banner), **Stub** (accepted, no-op, listed in the banner),
**None** (fails with a named reason).

| command | status | note |
|---|---|---|
| `run`, `create`, `start`, `stop`, `restart`, `rm` | Native | |
| `ps [-a]`, `inspect`, `logs` | Native | `inspect` gains a true-mode field |
| `exec` | Degraded | a fresh chroot re-entry; shares only the filesystem |
| `kill`, `wait` | Native | via the launcher's pidfds |
| `pause`, `unpause` | Degraded | `SIGSTOP`/`SIGCONT`, not a cgroup freeze |
| `cp` | Native | against the store rootfs |
| `pull`, `push`, `images`, `rmi`, `tag`, `search`, `login`, `logout` | Native | |
| `save`, `load`, `export`, `import` | Native | archives carry the ownership sidecar |
| `history` | Native | from image config |
| `diff` | Degraded | rootfs snapshot diff; no overlayfs exists |
| `build` | Degraded | a RUN-subset Dockerfile interpreter; no buildkit |
| `attach` | Degraded | log tail plus signal proxy |
| `stats`, `top` | Degraded | per-pid `/proc` of the launcher's subtree, labeled as such; no cgroups exist |
| `events` | Degraded | launcher-local |
| `system info`, `version` | Native | reports probes and achieved mode |
| `system/container/image prune` | Native | store GC |
| `volume ls/create/rm/inspect` | Degraded | named directories plus explicit sync |
| `port` | Stub | services already sit on the host network |
| `network ls` | Stub | lists exactly `host` |
| `network create/connect/...` | **None** | no populatable netns exists |
| `compose` | **None** | out of v1 scope; the error names the run-loop equivalent |
| `swarm`, `service`, `stack`, `node` | **None** | orchestrators need real containers |

| `run`/`create` flag | status | note |
|---|---|---|
| `-i`, `-d`, `--rm`, `--name` | Native | |
| `-e`, `--env-file`, `-w`, `--entrypoint`, `--label`, `--pull`, `--cidfile` | Native | |
| `--add-host` | Native | completion layer writes `/etc/hosts` |
| `--hostname` | Native | via probed `CLONE_NEWUTS` — this works here and is easy to miss |
| `--platform` | Native | `linux/amd64`; others fail with a clear error |
| `-t` | Degraded where `/dev/ptmx` exists, **None** where it does not | PTY pair allocated outside the chroot, fds passed in, `TIOCSCTTY` in the child. Whether the target has an outer `/dev/ptmx` is unresolved (§6.5) — probe it, and refuse with that reason when absent. Payloads reopening `/dev/pts/N` by name unsupported either way |
| `-v`, `--mount` | Degraded | interposer bind view where the payload is reachable, snapshot copy otherwise; **`:ro` rejected** as unenforceable; `type=tmpfs` becomes a rootfs directory |
| `-u`, `--user` | Degraded | only `0:0` is real; other ids via the interposer identity memo for reachable payloads, `0:0` plus a warning otherwise |
| `--device` | Degraded | fd-passing allowlist, opened before the chroot |
| `--tmpfs` | Degraded | a real directory in the rootfs, not kernel tmpfs |
| `--restart` | Degraded | launcher-level respawn |
| `--health-*` | Degraded | periodic `exec` probe |
| `--init` | Degraded | a built-in reaper between launcher and payload |
| `--log-driver` | Degraded | `json-file` only |
| `--pid=host`, `--ipc=host`, `--network=host`, `--userns=host` | Native | host is the only mode; accepted verbatim |
| `--pid` (private) | **None** | an empty pidns without `/proc` breaks tooling |
| `--network` (`none`, `bridge`, custom) | **None** | an isolation request; loud failure |
| `--userns=keep-id`/`private` | Stub | one mapping exists; banner states it |
| `-p`, `--expose`, `--link` | Stub | shared host net: the service is already reachable |
| `--memory`, `--cpus`, `--pids-limit`, `--ulimit` | Stub | no cgroups exist |
| `--privileged`, `--cap-add`, `--cap-drop` | Stub | the process already holds every capability in its userns |
| `--security-opt` | Stub | no profiles apply |
| `--read-only` | Stub | the rootfs is already a per-container copy; not enforced |
| `--dns`, `--dns-search`, `--dns-option` | Stub | the completion layer owns the resolver |
| `--cgroup-parent`, `--cgroupns`, `--isolation`, `--detach-keys` | Stub | |

**Honesty rules, from `paper_final.md` §10.1:**

1. The banner prints on every `run`/`exec`. Suppressible by config, never by default.
2. A request that *requires* isolation fails with a named reason instead of silently
   using the host.
3. `inspect` reports the true mode per container.
4. No output may imply namespaces, cgroups or devices exist when they do not.

### 6.9 Diagnostics

Every failure names the operation, the errno, the mechanism and the remedy — because
in this environment the errno alone actively misleads:

```
cannot restore ownership of etc/shadow (uid 0, gid 42): EINVAL
  gid 42 is not mapped in this user namespace (/proc/self/gid_map: 0 1000 1)
  extracting without ownership; intended metadata recorded in .meta.jsonl
```

---

## 7. The reference corpus

Studied per `docs/methodology/references.md` from `Azathothas/TEMPLATE`: fetched at a
commit, read, verdict recorded. **Depth** says how far the reading actually went, so
you know which rows to distrust.

⚠ Every "measured on target" verdict is a single session on a machine you cannot
reach. Every "measured here" verdict has a command in this repository. Prefer the
second, and re-check the first before building on it.

| project | commit | depth | verdict | what transfers |
|---|---|---|---|---|
| [pathmap](https://github.com/VHSgunzo/pathmap) (C, MIT) | `98b3d2a` | **built and run here**, symbol table read, `path-mapping.c` skimmed | **adopt** | The path half of §6.7, near-complete: 129 interposed entry points, `*at` resolution via `/proc/self/fd/<dirfd>`, and reverse mapping so `getcwd`/`readdir`/`readlink`/`realpath` report virtual names. **Measured: its bind view works here with `mount(2)` denied, and it leaves `chown` at `EINVAL`.** Its `ptrace` half is dead here — both channels (`ptrace`, `process_vm_readv`) are filtered. MIT, so the code is usable directly. |
| [udocker](https://github.com/indigo-dc/udocker) (Python) | `638bc42` | source read at file and line; measured on target | **adopt (mechanism), confirms (design)** | `container/structure.py::_untar_layers` extracts with `--no-same-owner --no-same-permissions --exclude=.wh.*` and applies whiteouts itself in `_apply_whiteouts` — ownership-neutral by design, which is why it clears wall 1 unpatched. Its per-container `--execmode` switch is the mode selector §4.1 asks for, at container granularity. Its fakechroot engine tarballs are a viable shortcut for the interpose tier. ⚠ Upstream dormant since 2024-08. |
| [ruri](https://github.com/RuriOSS/ruri) (C) | `711673a` | measured on target; not read here | **adopt (discipline)** | The strongest existing "better chroot": probes mount-ns support and *refuses* unshare mode cleanly rather than crashing, and turns every failed mount/`mknod` into a per-source-line warning while continuing. That is §6.1 and §6.9 in shipped C. Copy the style. |
| [pathshim](https://github.com/compforge/pathshim) (Rust) | `8bcc34e` | measured on target; not read here | **adopt (protocol)** | `pathshim probe` → `passthrough` with a printed reason and a non-zero exit, then runs the command unmapped and never silently maps. That is the `supervise` rung's preflight, and its exit code is a drop-in gate. |
| [sandlock](https://github.com/multikernel/sandlock) (Rust) | `841265d` | measured on target; not read here | **anti-pattern exhibit — keep** | Its notif handlers cannot read the child's path arguments here and fall back to *Continue*, so the kernel executes the syscall directly. `--dry-run` then reports `no filesystem changes` **while the file changes on disk**. This is the single best argument for §4.1's rule that a tier must be refused, not degraded per call. Its Landlock and seccomp-bpf tiers work unpatched. |
| [memfd-exec](https://github.com/VHSgunzo/memfd-exec) (Rust) | `9708cb7` | source skimmed | **adopt** | `memfd_create` + `fexecve` behind a `Command`-shaped API. Two dependencies. `memfd_create+exec` is permitted on this runtime. |
| [ulexec](https://github.com/VHSgunzo/ulexec) (Rust, MIT) | `00934f8` | source skimmed | **filed elsewhere** | Loads and runs an ELF from memory, over `memfd-exec` or `userland-execve`. Relevant to M7 packaging, not to the runtime. Same lineage as [sharun](https://github.com/VHSgunzo/sharun): both solve *relocation*, not filesystem virtualization. |
| [lilipod](https://github.com/89luca89/lilipod) (Go) | `872755a` + `patches/lilipod-restricted-v2.diff` | patch read in full | **refused as a seed; lessons adopted** | Wrong language (§3). Its lessons are in §6.5 (the fabricated-root `exec` bug), §6.6 (the racy lifecycle), §6.4 (resolv.conf, `/dev/null`, whiteouts) and §6.3. ⚠ It also hard-requires `getsubids`/`newuidmap`/`newgidmap` on PATH before *any* subcommand including `pull` — a dependency check ahead of every syscall wall. |
| [fakechroot](https://github.com/dex4er/fakechroot) / [fakeroot](https://tracker.debian.org/pkg/fakeroot) | — | not read | **adopt (model)** | fakechroot is the path half, fakeroot the ownership half, of §6.7. The split in §6.7's table *is* these two projects. |
| [onelf](https://github.com/qaidvoid/onelf) (Rust) | HEAD 2026-09-07 | source read at file and line | **adopt (packaging)** | Launch ladder: memfd → FUSE → ephemeral tmpfs → private run directory → persistent cache. Its `symlink_target_within_root` refuses absolute targets and targets climbing above the package root. ⚠ The memfd rung requires a static, dependency-free entrypoint — a shell entrypoint skips it. |
| [PRoot](https://proot-me.github.io) | — | measured on target | **refused** | `ptrace` is filtered. It misdirects, too: it blames an old Ubuntu kernel bug and suggests `PROOT_NO_SECCOMP`, which cannot help. Everything built on it (dockless's engine, rurima's non-root path, udocker P1/P2) inherits the refusal. |
| [rurima](https://github.com/RuriOSS/rurima) | `30a0637` | measured on target | **refused (pull)** | Extracts layers with plain `tar -xpf` as root → wall 1. Its `r` runner works once a rootfs exists. |
| [dockless](https://github.com/ylang-ylang/dockless) | `ed35b5d` | measured on target | **adopt (CLI posture), refused (engine)** | Its fail-fast guardrails and disk precheck are the parity documentation §6.8 specifies. Engine is PRoot. |
| [treesandbox](https://github.com/garywill/treesandbox) | `71acbee` | measured on target | **refused** | `unshare`+`mount` architecture with no fallback; dies before any namespace call on `getpwuid(0)`. |
| [bubblewrap](https://github.com/containers/bubblewrap) | 0.8.0 | source read at file and line | **confirms** | Its clone flags always include `CLONE_NEWNS`, so `Failed to make / slave` proves the clone *succeeded* and the mount did not. That message is the witness for the whole clone-vs-mount asymmetry. |
| [Podman](https://github.com/containers/podman) / [Apptainer](https://github.com/apptainer/apptainer) | 4.3.1 / `6099bb1` | measured, source read | **confirms** | Both die at wall 1 in layer application. Apptainer's unpacker is Go, so `LD_PRELOAD` cannot rescue it. ⚠ `proot` is **not** one of Apptainer's runtime paths — it appears once, wrapping `mksquashfs` during image *building*. |

### 7.1 What none of them do

No project in the corpus does **both** halves of §6.7 in one interposer while also
speaking docker's CLI. udocker gets closest — fakechroot plus a docker-shaped CLI —
and it is Python, dormant, and inherits fakechroot's coverage ceiling (its `dpkg`
unpack fails on the rename dance). That gap is podbox.

---

## 8. Failure-pattern field guide

So you do not re-derive the walls. Each line cost somebody real time.

| you see | it actually is | fix |
|---|---|---|
| `fork/exec <path>: operation not permitted` from a Go tool | the child's `setgroups` → EPERM. Not a missing binary, not `clone` | `Credential{NoSetGroups: true}`, or no `Credential` |
| `chown ...: Invalid argument` | the id is unmapped (N), not a permission problem | ownership-neutral extraction plus the sidecar |
| `setuid(1000): Invalid argument` | uid 1000 does not exist in this namespace | only 0 exists; do not drop privileges |
| `mount ...: operation not permitted` **inside a mount namespace you just created** | F denies `mount` everywhere | nothing mount-shaped works; use `chroot` |
| `fsmount` succeeds but `move_mount` gives EPERM | M, not F — the syscall executed | there is no attach path; stop looking |
| `openat` on a detached mount fd → `EACCES` | an LSM cannot resolve a path into a detached mount | detached mounts are unusable, not just unattachable |
| networking dead in a cloned child, `ENETUNREACH` | `CLONE_NEWNET` **succeeded** and gave you an empty, routeless netns | never pass namespace clone flags you cannot populate |
| `tar: etc/shadow: Cannot change ownership to uid 0, gid 42: Invalid argument` | wall 1: gid 42 (`shadow`) is unmapped | `--no-same-owner`, or interposition |
| `short write: -20 != N` from dwarfs | `-20` is libarchive's `ARCHIVE_WARN`, a status code, not an errno. `archive_errno` is `ENOSPC` | the temp dir is too small — `/tmp` is 64 MiB |
| `failed to chown temporary download directory` (pacman) | `DownloadUser = alpm` is an unmapped uid | comment it out |
| apt `Method http has died` / `no Release file` | tcp/80 egress is broken | https sources plus a CA bundle |
| `getpwuid(0)` fails / `unknown userid 0` | no `/etc/passwd` on the host | synthesize one in every rootfs you build |
| `failed to change dir to cachedir: Symbolic link loop` (xbps) | a later layer whiteouts an earlier layer's self-referential symlink; plain tar ignores `.wh.*` | apply whiteouts after each layer |
| zypper fixups revert after a refresh | the RIS index regenerates `repos.d` | edit `/usr/share/zypp/local/service/` first |
| dnf `Couldn't resolve host mirrors.*` though resolv.conf looks fine | the image baked a build-host resolver | always install the host's resolv.conf |
| `proot error: ptrace(TRACEME): Operation not permitted` plus a launchpad-bug hint | F filters `ptrace`; the hint is a misdirection | no env var helps; use a chroot or interpose engine |
| a sandbox tool's dry-run reports "no changes" and the file changed | a notif supervisor fell back to Continue because it could not read the child's arguments | probe the tier's legs up front and refuse it |
| `Error: invalid syntax for user` (udocker as root) | it remaps `root` via `getpwuid(0)`, which fails with no `/etc/passwd` | `run --user=0` — a numeric uid skips the remap |
| a shell redirection to `/dev/null` creates a growing file | `/dev/null` is absent and `>` implies `O_CREAT` | install the regular-file shim before the payload runs |

---

## 9. Acceptance tests

The milestone tests of §5, wired as CI, plus:

- **`podbox run --rm alpine echo hi` must succeed with zero non-docker knowledge.**
  This is the product requirement.
- **`experiments/30-attribution-census.sh` must exit 0 or 2, never 1.** A 1 means the
  runtime moved under you, or a probe stopped discriminating.
- **The lifecycle loop 20 times, 20 passes** (M4).
- **The ten-distro sweep**: alpine, debian, ubuntu, archlinux, almalinux, rocky,
  rocky-minimal, fedora, opensuse-leap, voidlinux-musl — each installs a C toolchain
  through its native package manager and builds and runs a two-file project. This
  set is not arbitrary: each member was chosen because it broke something (§6.4).
- **Negative tests are tests.** Assert that `--network=none` *fails* with a named
  reason, that `-v ...:ro` is *rejected*, and that a Go payload under `interpose` is
  *declined* rather than silently unvirtualized.

---

## 10. Deliberately out of scope

Say so in the banner rather than approximating:

- **Network isolation.** There is no populatable netns; populating one needs
  `mount` for `/sys/class/net` at minimum.
- **Resource limits.** No cgroup2 mount exists. `--memory` and friends are stubs.
- **Live `/proc` and `/sys`.** A static fixture can satisfy a program that only
  *reads* a mount table, and nothing more. Generate it from the real topology, never
  ship someone else's device numbers, and fail loudly for anything needing a live
  interface.
- **Security.** In `chroot` and `interpose` modes there is none, and `chroot(2)`
  requires `CAP_SYS_CHROOT` and is not a sandbox. The correct framing is environment
  reproducibility for contexts whose security boundary is already exterior.

---

## 11. Orientation in this repository

| path | what it is |
|---|---|
| `paper_final.md` | the research. §3 (runtime), §9 (the four walls), §10 (design) are the ones you need |
| `verification/` | the model harness. `./verification/run.sh`; `probe/` is the reference probe set |
| `verification/real/` | captures from the target runtime itself — one session, unrepeatable |
| `experiments/` | the reconstruction and the measurements: build the runtime in a container, assert every attribution row, compare languages, run the interpose tier |
| `patches/lilipod-restricted-v2.diff` | the prior Go implementation. Read for its lessons; do not apply it |
| `references/` | the three earlier manuscripts this corpus reconciled, unmodified |

```sh
./experiments/10-build-target-image.sh   # the runtime's userspace
./experiments/20-enter-target.sh         # a shell inside it
./experiments/30-attribution-census.sh   # every attribution, asserted
./experiments/40-language-selection.sh   # the measurements behind §3
./experiments/50-interpose-tier.sh       # the measurements behind §6.7
```

Exit codes are uniform across all five: **0** ran and matched, **1** ran and
something failed, **2** could not run. A `2` from `30-` is expected on a kernel
without Landlock and is not a failure; a `1` is.

---

*If any statement here disagrees with `experiments/results/`,
`verification/real/` or `paper_final.md`, those win — then fix this file.*
