# experiments/

Scripts that reconstruct the runtime `paper_final.md` characterizes, and take
the measurements the paper cites, on a machine that is not the target.

Numbered in the order they run. A number is never reused: a citation of `30-`
has to keep meaning what it meant.

| script | the question it answers |
|---|---|
| `10-build-target-image.sh` | can a container image supply the target's *userspace* — the toolchain it has, the files it lacks? |
| `20-enter-target.sh` | can a container supply the target's *kernel-visible shape* — its mount topology, its ID map, its filter, its write policy — and which parts does this host refuse? |
| `30-attribution-census.sh` | which mechanism produces which denial, measured one mechanism at a time, against a written-down expectation |

## Exit codes

Uniform across all three, per this repository's convention:

| code | meaning |
|---|---|
| 0 | the measurement ran and matched expectation |
| 1 | the measurement ran and something under test failed |
| 2 | the measurement could not run (missing dependency, kernel feature absent) |

## Quick start

```sh
./experiments/10-build-target-image.sh          # ~2 min, needs docker + network
./experiments/20-enter-target.sh                # interactive shell in the reconstruction
./experiments/20-enter-target.sh -- id          # or run one command
./experiments/30-attribution-census.sh          # the census, with assertions
```

`20-` needs a **privileged** container: reconstructing a mount topology
requires `mount(2)`, and reconstructing a partial ID map requires writing
`uid_map` with a host id the process does not own. Neither is available to the
reconstruction *inside* — that is the point of it.

## What this reconstructs, and what it cannot

The target is described in `paper_final.md` §3.1, §3.6, §3.7 and measured in
`verification/real/`. Three mechanisms compose it:

| | mechanism | reconstructed here? |
|---|---|---|
| **N** | user namespace, map `0 -> 1000`, `setgroups` denied, one unmapped supplementary group, mount namespace owned by it | **yes**, fully |
| **F** | seccomp filter denying `unshare`, `setns`, `mount`, `umount2`, `pivot_root`, `ptrace`, `process_vm_readv`, `process_vm_writev` | **yes**, fully |
| **M** | Landlock-class write allowlist over `{/tmp, /dev/shm, /workspace, /state}` | **only where the host kernel has Landlock** |

⛔ **M needs `CONFIG_SECURITY_LANDLOCK` and `landlock` in the boot LSM list.**
Where the kernel lacks it, `20-` prints `M: unavailable` and continues with N+F;
`30-` then reports the M-dependent rows as `SKIP` and exits 2 rather than
passing a run that never tested them. This is a real gap, not a formality: on
the kernel this repository's own captures were taken on
(`6.18.44-fc-v24`, a Firecracker guest), `CONFIG_SECURITY_LANDLOCK is not set`,
so the M rows here are **[S]** from kernel source plus **[T]** from the target,
never **[V]** locally. Any host with a distro kernel — Debian, Fedora, Arch,
Ubuntu ≥ 20.04 — has Landlock and closes the gap.

Two further differences are inherent and are *not* bugs to chase:

- **The kernel is the host's.** Syscall availability, the Landlock ABI and the
  new mount API all follow the host kernel, not the target's 6.18.39. `30-`
  prints the running version with every result.
- **The reconstruction is not the security boundary.** Everything here is
  built by a privileged process that could tear it down. It reproduces what a
  confined program *observes*; it is not a sandbox and must not be used as one.

## Conditions

Every script prints, on the way out: host kernel, container runtime version,
image digest, the mechanisms actually applied, and the date. A number quoted
from these scripts without that block is a number without conditions.
