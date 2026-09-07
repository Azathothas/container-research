# TOOL.md — orientation for an agent with no prior context

*Read this file end-to-end first. It assumes you know containers and Linux, and
nothing else. Last updated: 2026-09-07.*

---

## 1. The problem, in sixty seconds

You are (or your users are) running inside a Linux sandbox that **presents itself as
fully privileged root while denying almost every operation containers are built on**.
This is not hypothetical; such runtimes are common for AI-agent sandboxes, hardened
CI executors and locked-down HPC nodes. The exact target characterized in this repo:

| You have | You do NOT have |
|---|---|
| uid 0, every capability bit, `Seccomp: 2` | `unshare(2)` — EPERM (any namespace) |
| `chroot(2)` | `mount(2)`, `pivot_root(2)` — EPERM, even inside a mount ns you own |
| `memfd_create`, `setsid`, `prctl` | `ptrace(2)` — EPERM (no strace, no proot) |
| `clone(2)` **with namespace flags** (they succeed!) | `mknod(2)` — EPERM (no device nodes, no /dev/fuse) |
| full network (shared host netns), HTTPS egress | `setuid`/`setgid` to non-zero id — **EINVAL** (unmapped) |
| `getrandom(2)`, netlink, `sysinfo(2)` | `chown` to anything but `0:0` — **EINVAL** (unmapped) |
| writable: `/tmp` (64 MiB!), `/workspace`, `/state`, `/dev/shm` | writes anywhere else (`/`, `/etc`, `/usr`… — path allowlist, an LSM-class restriction) |

Two mechanisms produce this, plus one helper (all verified on the target; see
`paper_final.md` §3 and `verification/real/identity.txt`):

- **N** — the process lives in a **user namespace** whose only map is `0 -> 1000`
  (`/proc/self/uid_map`), with `setgroups` denied. Every id other than 0 is
  **unmapped**; operations on unmapped ids return `EINVAL`, capabilities do not
  apply to unmapped-owned objects. This produces the chown/setuid/setgroups/mknod
  denials and the unwritable directories.
- **F** — a seccomp filter denying `unshare`, `setns`, `mount`, `umount2`,
  `pivot_root`, `ptrace` (each verified on the target). **It does not deny
  `clone`.** So `clone(CLONE_NEWNS)`
  *succeeds* — you can hold a private mount namespace and still be unable to mount
  anything in it. This asymmetry inverts tool assumptions; see §6.6 below.
- **M** — a path-scoped write allowlist (Landlock-class). Explains why `/` rejects
  writes while `/tmp` (same owner, same flags) accepts them.

There is **no `/etc/passwd`**, no `/run`, no `/var`, no `/dev/fuse`. `docker` on
PATH is a podman alias with no daemon. Plain-HTTP (tcp/80) egress is broken;
HTTPS works.

**The goal of the research in this repo**: figure out what container tooling does
here, what can be salvaged, and specify a runtime that "just works" in this class
of environments without lying about what it provides.

---

## 2. Where the research stands

### 2.1 The corpus

- **`paper_final.md`** — the reconciled, verified paper. Read §3 (the runtime
  model and its attribution table), §9 (the four recurring walls), §10 (the honest
  runtime design), §11 (comparative summary). §3.7 records target-run deltas.
- **`verification/`** — the harness that backs every `[V]` claim: `run.sh` runs
  model environments (`confine/`); `probe/`, `cprobe/` are the bare probes.
  **`verification/real/` is evidence captured on the actual target runtime** —
  `identity.txt`, `probe-census.txt`, `spawn.txt`, `writability.txt`, `bwrap.txt`,
  `lilipod-v2-lifecycle.txt`, PoC captures, and `poc-note.md`.
- **`references/`** — the three earlier manuscripts this corpus reconciled
  (`paper-ox.md`, `paper-opus.md`, `paper-astra-*.md`), unmodified. `paper-ox.md`
  is the original target-side study.
- **`patches/lilipod-restricted-v2.diff`** — the published, working adaptation of
  lilipod (89luca89/lilipod @ `872755a`) to this runtime. 5 files, +343/−34.

### 2.2 Tool verdicts (target-verified)

| Tool | Verdict | Why |
|---|---|---|
| rootless podman | **impossible** | needs a non-root uid; `setuid(nonzero)` = EINVAL (N) |
| rootful podman | dead at init (target) | target podman 5.8.2 dies with a bare `no such file or directory` even with `--storage-driver vfs --root/--runroot` (`verification/real/podman-vfs-target.txt`); the corpus model (podman 4.3.1) initialized with vfs and died later, at unmapped-gid `lchown` (§6 of paper) |
| apptainer | dead at SIF build | same `lchown` wall in its Go unpacker (raw syscalls — cannot be LD_PRELOADed) |
| runimage (as shipped) | dead at bubblewrap | bwrap needs `mount(MS_SLAVE)` (F) |
| **lilipod + patch** | **works** | namespaces+mounts replaced by chroot; see below |
| **runimage rootfs via chroot + onelf** | **works** | full Arch userspace packaged as one 215 MiB executable |

### 2.3 What the lilipod v2 patch does (the working system)

Applied to the lilipod tree, it adds `pkg/sandbox/restricted.go` and modifies 4
files. Behavior:

1. **Probe once, in disposable children** (never `unshare` — it mutates the
   prober and is the wrong operation): a `clone(CLONE_NEWNS)` child attempts a
   tmpfs mount (the operation the normal path actually needs); a
   `clone(CLONE_NEWUTS)` child attempts `sethostname`. Results cached.
2. If mounts are impossible → **restricted mode**: enter-children spawn with only
   probed flags (`CLONE_NEWUTS` — per-container hostnames work!), no `Credential`
   (a non-nil one makes Go call `setgroups` → EPERM → spawn fails as a baffling
   `fork/exec ...: operation not permitted`), per-config namespace flags are
   **not** applied (`CLONE_NEWNET` would *succeed* here and yield an empty,
   routeless netns — silent total networking loss).
3. Rootfs setup without mounts: mkdir `tmp/run/dev/etc`, copy host
   `resolv.conf` (only if the image's has no `nameserver` line — images ship
   empty placeholders), **regular-file `/dev/null` shim** (mknod is denied;
   writes succeed, reads give EOF), volumes as snapshot copies, write
   `/run/.containerenv` (powers `ps` running-state via `/proc/*/root` scan).
4. `pivot_root` → `chroot(path)` with absolute path; skip cgroup2, hostname
   is honored *only* when the UTS probe passed.
5. Layer extraction with `tar --no-same-owner` (the chown wall would otherwise
   abort on the first non-root-owned file, e.g. `/etc/shadow` gid 42).
6. `exec` re-enters by a **fresh chroot enter that inherits the parent
   environment** (the v1 bug: env-stripped children recompute the store from a
   relative path, fabricate an empty rootfs via MkdirAll, and chroot into it).

Result on the target: `pull`, `run`, `create`, `start`, `ps`, `stop`, `rm`,
`logs`, `exec`, volumes (copy-in), hostnames — all work. PTY allocation does not
(no `/dev/ptmx` reachable). ~0.1 s warm launch.

### 2.4 The ten PoCs (all single-shot, evidence captured)

Under `verification/real/poc*` (repo) and `/workspace/poc/` (target):

1. **Alpine → static musl binary**: `apk add build-base`, `cc -static`; artifact
   has no `PT_INTERP`, runs on the host, exit code preserved.
2. **Debian bookworm-slim → curl from source**: apt (https + host CA +
   `APT::Sandbox::User=root`), `curl-8.22.0` configured with OpenSSL+nghttp2,
   built, and the built binary fetches `https://example.com`.
3. **AlmaLinux 9 → fastfetch**: dnf + EPEL, fastfetch 2.66.0 runs and — via
   `sysinfo(2)`/netlink — honestly reports the shared host kernel and IP.
4. **Arch Linux → CMake project**: pacman (after `DownloadUser` fixup), cmake
   4.4.3 builds `fmtlib/fmt` at HEAD; test program links against `libfmt.a`
   and runs.
5. **Six more via one distro-detecting harness** (`poc5-build.sh`, evidence
   `poc5-*.txt`): voidlinux-musl (xbps — dynamic **and** `-static` musl
   builds), ubuntu 26.04, opensuse leap 16.0, rockylinux 9,
   rockylinux 9-minimal (microdnf) and fedora 44 (dnf5) — each installs a C
   toolchain and builds+runs a two-file make project. The per-manager fixup
   matrix is in `poc-note.md` and paper §8.3; three findings generalize:
   OCI **whiteouts are load-bearing** (void ships a `/var/cache/xbps`
   self-loop that a later layer whiteouts — plain tar leaves the loop; v2.2
   gained `ApplyOCIWhiteouts`), **zypper regenerates repos.d from its RIS
   index** (fixups must sed `/usr/share/zypp/local/service/` first), and
   **images bake unreachable resolvers** (rocky: `192.168.122.1` — v2.3
   adopts docker's always-install-host-resolv.conf semantics).

Package-manager-specific fixes encoded by the PoCs (see `poc-note.md`): pacman
`DownloadUser=alpm` chowns to an unmapped uid (comment it out); apt's `_apt`
sandbox user fails on unmapped ids (use root); tcp/80 is broken (use https);
dpkg/rpm log chown *warnings* but proceed.

---

## 2.5 All this machinery vs. vanilla `chroot`: what is actually gained

Honest framing first: **mechanically, everything this spec does is expressible as
a pile of shell scripts around `chroot(2)`** — same syscalls, same walls, no
kernel magic; nothing here conjures privileges. The product *is* the pile of
scripts — probed, tested, and wearing docker's face. "Why not just chroot?"
therefore reduces to four advantages vanilla `chroot` structurally cannot provide:

| | `chroot rootfs/ cmd` | podbox (this spec) |
|---|---|---|
| **Interface** | bespoke script per use, nothing reusable | docker/podman verbs, flags, exit codes — existing CI, scripts and agent habits work unmodified (§5.1) |
| **Images** | bring your own rootfs, by hand | `pull`/`push`/`save`/`load` against any OCI registry; layered extraction that survives the chown wall (ownership sidecar); tags, manifests, store |
| **Lifecycle & state** | none — you own daemons, logs, cleanup | named containers, `ps`/`stop`/`rm`/`inspect`/`logs`/`exec`, running-state detection, detached start with log capture, restart policy |
| **Pre-solved walls** | you rediscover every failure mode of §6 yourself (each entry there cost real debugging time; a bare chroot hits it with a misleading errno) | environment-completion layer automates all PoC fixups (dev shims, resolv.conf, mtab, pacman/apt/dnf config, keyrings); probe discipline prevents the empty-netns and setgroups traps; the mode banner states what you actually got |

Secondary gains: reproducible in-container toolchains (PoCs 1–4 become one
`docker run`-shaped command each), and single-file distribution (static binary,
onelf-packable with an embedded rootfs).

One sentence: **chroot is a syscall; podbox is the missing container userland
around it, speaking the only container language most agents know.** Where it
cannot beat chroot — kernel isolation — it says so out loud; §6 is the price of
not having this layer.

---

## 3. What to read, in order

If you have minutes, not hours:

1. This file.
2. `paper_final.md` — §2 (findings table), §3 (runtime), §9 (the four walls),
   §10 (design), §11 (comparison).
3. `verification/real/identity.txt`, `probe-census.txt`, `writability.txt` —
   fifteen lines each; they *are* the runtime.
4. `patches/lilipod-restricted-v2.diff` — the whole working system in ~340 lines.
5. `verification/real/poc-note.md` + the four `poc*.txt` captures.
6. For depth: `references/paper-ox.md` (the original study), `verification/run.sh`
   + `confine/` (how the model was built), `verification/README.md`.

On the target machine, the working tree lives at `/workspace/lilipod` (patch
applied; binaries `lilipod-stock`, `lilipod-v2`), evidence at
`/workspace/poc/evidence/` and `/workspace/paper/evidence/` (93+ files, all
mechanically captured via `paper/cap.sh`), artifacts at `/workspace/poc/`.
**Never write results from memory — re-run and capture.**

---

## 4. Known limitations, and how to resolve each

These are the gaps between "works" and "a drop-in container CLI". Each has a
concrete plan; none requires privileges we do not have.

| # | Limitation | Cause | Resolution path |
|---|---|---|---|
| L1 | **PTY/`-t` unavailable** | no `/dev/ptmx` reachable after chroot; devpts cannot be mounted | allocate the pty pair **outside** the chroot (host `/dev/ptmx` works), pass both fds into the container process, `TIOCSCTTY` in the child (paper §10.5 step 2). Payloads that *reopen* `/dev/pts/N` by name stay unsupported. |
| L2 | **No `/proc`, `/sys` inside** | mount denied | synthesize fixtures per-need: static `mountinfo` (device-consistent — proven with apptainer), filtered-copy `/proc` from the host (only the launcher's pid subtree), `/proc/net` from netlink dumps. Fail loudly for tools needing live kernel interfaces. |
| L3 | **No device nodes** | mknod denied; /dev not mountable | regular-file `/dev/null` (done); `/dev/zero`, `/dev/urandom` as pre-filled regular files where a *file* suffices; everything else: fd-passing at spawn (§10.5). `getrandom(2)` already covers TLS/crypto. |
| L4 | **Ownership metadata lost** | chown to unmapped ids = EINVAL | fakeroot-style sidecar (`.meta.jsonl`) recording intended uid/gid/mode per path; apply on export where mapping permits; report honestly (paper §10.4). `--no-same-owner` extraction stays the default. |
| L5 | **Volumes are copy-in only** | no bind mounts | keep copies; add explicit `sync` subcommands (push/pull) and document; reject `:ro` (unenforceable) with an error, not silence. |
| L6 | **`exec` is a fresh chroot, not setns** | setns denied | acceptable: re-enter against the same rootfs with env + fds; document that it shares nothing but the filesystem with the original process. |
| L7 | **No network isolation / no resource limits** | no netns we can populate, no cgroup2 mounts | out of scope by construction — the mode banner must say so. (A populated netns would need `mount` for `/sys/class/net` at minimum; denied.) |
| L8 | **Static/Go payloads bypass interposition** | raw syscalls | payload classification + honest refusal (paper §10.3); they still run under chroot fine — they just can't be *further virtualized*. |
| L9 | **uid/gid inside is always 0:0** | only `0->1000` mapped | fake `id` output via PATH-shim only if requested; kernel checks unchanged. Document. |
| L10 | **stores/keys of package managers need fixups** | unmapped-id chowns, tcp/80 broken | the "environment completion" layer (§5.4 below) automates the PoC fixups. |

---

## 5. SPEC: a drop-in `docker`/`podman` CLI for confined runtimes

**Working name: `podbox`** (any name works; it must answer to `docker` and
`podman` on PATH for drop-in behavior). One static Go binary (memfd-eligible,
onelf-packable), zero external dependencies, seeded by the lilipod v2 patch.

### 5.1 Prime directive

**Same verbs, same flags, same exit codes as docker/podman.** An agent that knows
docker must need zero new knowledge. Where a flag cannot be honored, it is
accepted and reported in the mode banner — never silently ignored, never fatal
(§5.6). Isolation-requests (`--privileged` inverse) degrade loudly.

### 5.2 Startup: probe, then declare

On first run (cached in `$store/probe.json`), run the §10.2 probe set in
disposable children; print the mode banner to stderr once:

```
podbox 0.1: mode=chroot (namespaces: uts-only; mounts: none; devices: shimmed;
ownership: virtualized+sidecar; network: host-shared; pids: host-shared)
probes: clone(NEWNS)=ok mount=EPERM clone(NEWUTS)=ok sethostname=ok chroot=ok
```

If real namespaces+mounts are available (normal host), podbox uses them and is
indistinguishable from a normal runtime. The ladder: namespaces → chroot →
interpose → `unsupported <reason>`.

### 5.3 CLI surface and docker/podman parity matrix

Statuses (spec; PoC-proven items are marked):

- **Native** — real semantics, indistinguishable from docker for this flag.
- **Degraded** — works, with a documented semantic difference (banner states it).
- **Stub** — accepted, no-op, listed in the mode banner (never fatal, never silent).
- **None** — fails with a named reason (per §5.6: never silently substitute a
  weaker meaning for an isolation request).

**Commands**

| Command | Status | Notes |
|---|---|---|
| `run` | **Native** | PoCs 1–4 ran through exactly this path |
| `create` / `start` / `stop` / `restart` / `rm` | **Native** | PoC-proven (detached start + running-state `ps`) |
| `ps [-a]` / `inspect` / `logs` | **Native** | `inspect` gains a true-mode field; `logs` from store capture |
| `exec` | **Degraded** | fresh chroot re-entry (shares only the fs with the original process); PoC-proven working incl. hostname ns |
| `kill` / `wait` | **Native** | signals via launcher-tracked pid tree |
| `pause` / `unpause` | **Degraded** | SIGSTOP/SIGCONT process-freeze, not cgroup freeze |
| `cp` | **Native** | copies against the store rootfs |
| `pull` / `push` / `images` / `rmi` / `tag` / `search` / `login` / `logout` | **Native** | full OCI registry client; extraction ownership-neutral + sidecar |
| `save` / `load` / `export` / `import` | **Native** | archives carry the ownership sidecar (L4) |
| `history` | **Native** | from image config |
| `diff` | **Degraded** | rootfs snapshot diff (no overlayfs) |
| `build` | **Degraded** | RUN-subset Dockerfile interpreter (RUN/ENV/WORKDIR/COPY/ARG/FROM/USER-stub); no buildkit |
| `attach` | **Degraded** | log tail + signal proxy; true tty attach after L1 |
| `stats` / `top` | **Degraded** | per-pid `/proc` of the launcher subtree, honestly labeled; no cgroups exist |
| `port` | **Stub** | services already sit on the host network |
| `events` | **Degraded** | launcher-local event log |
| `system info` / `version` | **Native** | reports probes + achieved mode |
| `system prune` / `container prune` / `image prune` | **Native** | store GC |
| `volume ls/create/rm/inspect` | **Degraded** | named dirs + explicit `sync` push/pull (L5); no live mounts |
| `network ls` | **Stub** | lists exactly `host` |
| `network create/connect/...` | **None** | no populatable netns exists; named-reason failure |
| `compose` | **None** | v1 scope; error text points at the run-loop equivalent |
| `swarm`/`service`/`stack`/`node` | **None** | orchestrators need real containers |

**`run`/`create` flags**

| Flag | Status | Notes |
|---|---|---|
| `-i` / `-d` / `--rm` / `--name` | **Native** | PoC-proven |
| `-e` / `--env-file` / `-w` / `--entrypoint` / `--label` / `--pull` / `--cidfile` | **Native** | PoC-proven (`-e`,`-w`,`--entrypoint`,`--pull`) |
| `--add-host` | **Native** | completion layer writes `/etc/hosts` |
| `--hostname` | **Native** | probed `CLONE_NEWUTS`; PoC-proven (`finalhost`, host untouched) |
| `--platform` | **Native** | `linux/amd64`; others fail with a clear error |
| `-t` | **Degraded** | after L1: pty pair allocated *outside* the chroot, fds passed in, `TIOCSCTTY` in child; payloads reopening `/dev/pts/N` by name unsupported (spec, not yet PoC-proven) |
| `-a` | **Degraded** | with `-d`; log tail + signal proxy |
| `-v` / `--mount` | **Degraded** | snapshot copy-in (PoC-proven); `:ro` **rejected** (unenforceable — honesty rule); `--sync` opt-in bidirectional; `type=tmpfs` → rootfs dir |
| `-u` / `--user` | **Degraded** | only `0:0` is real; other ids via interposer identity memo for C payloads; static/Go payloads get `0:0` + warning (L9) |
| `--device` | **Degraded** | fd-passing allowlist opened before chroot (L3) |
| `--tmpfs` | **Degraded** | real dir in the container rootfs, not kernel tmpfs |
| `--restart` | **Degraded** | launcher-level respawn; no supervisor integration |
| `--health-cmd` / `--health-interval` … | **Degraded** | periodic `exec` probe by the launcher |
| `--init` | **Degraded** | built-in reaper between launcher and payload |
| `--log-driver` | **Degraded** | `json-file` only |
| `--pid=host` / `--ipc=host` / `--network=host` / `--userns=host` | **Native** | host is the only mode; accepted verbatim |
| `--pid` (private) | **None** | empty pidns without `/proc` breaks tooling; named-reason failure |
| `--network` (`none`/`bridge`/custom) | **None** | isolation request → loud failure (§5.6); no populatable netns |
| `--userns=keep-id`/`private` | **Stub** | single mapping exists; behaves as host, banner states it |
| `-p` / `--expose` / `--link` | **Stub** | shared host net: the service is already reachable |
| `--memory` / `--cpus` / `--pids-limit` / `--ulimit` | **Stub** | no cgroups exist here |
| `--privileged` / `--cap-add` / `--cap-drop` | **Stub** | process already holds every capability in its userns |
| `--security-opt` | **Stub** | no seccomp/apparmor profiles apply |
| `--read-only` | **Stub** | rootfs is already a per-container copy; enforcement not attempted |
| `--dns` / `--dns-search` / `--dns-option` | **Stub** | resolver managed by the completion layer |
| `--detach-keys` | **Stub** | no tty by default |
| `--cgroup-parent` / `--cgroupns` | **Stub** | no cgroups |
| `--isolation` | **Stub** | accepted verbatim |

### 5.4 The environment-completion layer (the "it just works" core)

Before any payload runs, podbox *prepares the rootfs* — generalizing every fixup
the ten PoCs needed, derived from image + distro detection, no user action:

- `/dev/null` regular-file shim; `/dev/zero`, `/dev/urandom` pre-filled files;
  `/dev/tty` → passed-in fd symlink where possible.
- `/etc/resolv.conf`: install host's iff no `nameserver` line (AlmaLinux case).
- `/etc/mtab`: static device-consistent file iff target package set reads it
  (pacman with `CheckSpace`).
- `/etc/hosts`: `127.0.0.1 localhost <container-name>`.
- **distro fixups** (idempotent, logged): pacman → comment `DownloadUser`; apt →
  `APT::Sandbox::User=root` + https sources + CA bundle from host iff tcp/80
  probe fails; dnf/rpm → nothing needed; apk → nothing needed.
- keyring: if pacman keyring uninitialized → `pacman-key --init; --populate`
  (works here; proven in the corpus model §8.3).
- a tiny `procfix/` directory of static fixtures (`mountinfo`, `uptime`,
  `meminfo`, `cpuinfo`) mounted-in-text at `/proc/...` where a tool merely reads
  a file (L2); the launcher regenerates them from syscalls at start.

### 5.5 Payload classes & the interposer

- Classification at `run` time: ELF `PT_INTERP` present → interposable; absent →
  static (runs, not virtualizable); Go markers → same as static (paper §9.3,
  verified on target: `LD_PRELOAD` never sees Go `lchown`, cgo or not).
- The **interposer** (libc-agnostic `.so`, no `DT_NEEDED`) is podbox's answer for
  C payloads that need more than chroot gives: path rewrite into the rootfs for
  `open*/stat*/execve/chdir`, `chown/lchown/fchown` → success + sidecar record,
  `setuid/setgid/setgroups` → success + identity memo (`getuid` family report
  it), `mknod` → regular file, `mount` → in-memory table + success, `unshare`
  → success + memo (no-op), `clone` → strip namespace flags then real clone.
  This is the fakeroot/fakechroot lineage, constrained to what this runtime
  allows; it is *compatibility*, never isolation, and the banner says which
  payloads got it.
- PTY per L1: pty pair allocated outside, fds inherited, `TIOCSCTTY` in child —
  then `-t` works for payloads that use their controlling terminal.

### 5.6 Honesty rules (non-negotiable, from paper §10.1)

1. The mode banner prints on every `run`/`exec` (suppressible by config, never
   by default).
2. A request that *requires* isolation (e.g. `--network=none` for secrecy) fails
   with a named reason instead of silently using the host network.
3. `inspect` reports the true mode per container.
4. No output may imply namespaces/cgroups/devices exist when they do not.

### 5.7 Acceptance tests

The ten PoCs become CI (`tests/`): pull+build each distro image, run the PoC
script, assert markers (`BUILD-OK`, exit codes, `PT_INTERP` absence for the musl
artifact). Plus: `docker run --rm alpine echo hi` must succeed with **zero
non-docker knowledge** — that is the product requirement this whole document
exists for.

### 5.8 Implementation notes

- Seed = lilipod tree + `patches/lilipod-restricted-v2.diff`; replace probe with
  §5.2 set; add completion layer, CLI shim (docker/podman arg-compat table),
  sidecar store, pty allocator, interposer `.so` (build with `-nostdlib`
  raw-syscall stubs; embed in the Go binary, extract to store at first run).
- Single static Go binary; `onelf pack` ships it (and optionally a rootfs) as
  one file — memfd rung on normal hosts, rundir/cache here.
- Everything an agent touches must degrade exactly like the corpus §10 ladder:
  probe → strongest mode → honest banner.

### 5.9 Running *unpatched third-party* runtimes (research direction)

For running tools we cannot patch (their Go cores issue raw syscalls):
- **crun is C** (libc-bound): an interposer around *crun itself* — strip its
  `clone` namespace flags, fake `mount`/`pivot_root`(→chroot), fake `chown` —
  could make an unmodified OCI runtime believe it succeeded. Then podman
  (unpatched) *might* run images through it. Highest-value experiment left open.
- **Static fixtures + env**: preconditions that are files (mtab, resolv.conf,
  pacman.conf, apt conf) can be pre-satisfied without touching binaries — the
  apptainer `mountinfo` technique generalized; already implemented in §5.4.
- ptrace/qemu tiers: denied here; keep as optional tiers where available.

---

## 6. Failure-pattern field guide (so you don't re-derive the walls)

| You see | It actually is | Fix |
|---|---|---|
| `fork/exec <path>: operation not permitted` (Go tool) | child `setgroups` EPERM (N), *not* a missing binary, *not* clone | drop `Credential` or `NoSetGroups:true` |
| `chown ...: Invalid argument` | id unmapped in userns (N), not permissions | ownership-neutral extract + sidecar |
| `setuid(1000): Invalid argument` | uid unmapped (N) | only 0 exists; don't drop privileges |
| `mount ...: operation not permitted` **inside your own new mountns** | filter F denies mount everywhere | nothing mount-shaped works; chroot |
| network dead in a cloned child (`ENETUNREACH`) | `CLONE_NEWNET` *succeeded* → empty netns | don't pass namespace clone flags you can't populate |
| `tar: etc/shadow: Cannot change ownership ... Invalid argument` | gid 42 (shadow) unmapped | `--no-same-owner` |
| dwarfs `short write: -20 != N` | libarchive `ARCHIVE_WARN`; errno ENOSPC — tmp dir too small (64 MiB /tmp!) | `TMPDIR` somewhere with room |
| `failed to chown temporary download directory` (pacman) | `DownloadUser = alpm` unmapped | comment it out |
| apt `Method http has died` / `no Release file` | tcp/80 egress broken in this sandbox | https sources + CA |
| `getpwuid(0)` fails / `unknown userid 0` | no `/etc/passwd` on host | synthesize one in chroots you build |
| `failed to change dir to cachedir: Symbolic link loop` (xbps) | a later OCI layer whiteouts an earlier layer's self-referential symlink; plain tar ignores `.wh.*` | apply whiteouts after each layer (v2.2 `ApplyOCIWhiteouts`) |
| zypper fixups don't stick (http again after refresh) | RIS index service regenerates repos.d from `/usr/share/zypp/local/service/` | sed the index, refresh-services, then repos.d |
| dnf "Couldn't resolve host mirrors.*" although resolv.conf looks fine | image bakes a build-host resolver (rocky: `192.168.122.1`) | install the host resolv.conf (docker semantics, v2.3) |

---

*End of TOOL.md. If any statement here disagrees with
`verification/real/` or `paper_final.md`, those win — then fix this file.*
