# Containers with Limited Privileges: A Case Study of Container Tooling When Namespace Creation Is Denied

**Version 2.0 — 2026-09-07**

## Abstract

Some restricted Linux environments permit ordinary process execution and filesystem
I/O while denying operations used to establish additional container isolation. This
case study examines reported experiments with **lilipod**, **Podman**,
**Apptainer**, and **runimage** in one such environment. The available excerpts show
namespace-related startup failures, unsuccessful ownership restoration, and a
credential-setting failure consistent with a denied `setgroups(2)` operation.
They do not identify the enforcement mechanism behind every failure. An adaptation
of lilipod is reported to support selected lifecycle operations by using
`chroot(2)`, retaining the invoking identity, and extracting files without restoring
archive ownership; `exec` and the tested PTY path remain unsuccessful. A runimage
root filesystem entered through `chroot` is reported to run selected Arch Linux
utilities and package installations. Packaging this userspace with **onelf** yields
a reported 225,641,729-byte executable, equivalent to 215.19 MiB, with a reported
3.8 s fresh-extraction launch. The raw logs, patch, and executable are unavailable
with this manuscript, limiting independent reproduction. The findings support
explicit compatibility modes for selected workloads when `CAP_SYS_CHROOT` and the
required host services remain available; they do not establish general execution
without privileges or an additional security boundary.

## 1. Introduction

Linux container tools combine several functions: retrieving images, constructing
root filesystems, configuring process execution, and applying isolation and resource
controls. These functions have different kernel and filesystem requirements.
Failure to create a namespace need not prevent downloading an image or executing
an ordinary binary from its extracted userspace.

The study concerns a particular restricted runtime, not a measured population of
AI-agent sandboxes, CI systems, HPC installations, or Android environments. Policies
and available helpers vary across those systems. In particular, disabling
unprivileged user namespaces does not imply that an administrator-provided setuid
container runtime cannot operate.

The study has four aims:

1. Describe the reported process identity, filesystem layout, and operation-level
   failures in the target runtime (§2).
2. Separate observed failures from architectural explanations and unresolved causes
   in lilipod, Podman, and Apptainer (§4–§6).
3. Assess the reported execution and packaging of runimage's root filesystem through
   `chroot` (§7).
4. Derive requirements for explicit, limited compatibility modes (§9).

Here, a *container userspace* means an image-derived directory tree and its running
programs. Every Linux process already belongs to namespaces; the relevant
restriction is the inability to create or enter the additional namespaces needed
by the tested launch paths. The working configurations described here retain the
outer environment's restrictions and do not establish independent process, network,
or mount isolation. `chroot` requires an effective `CAP_SYS_CHROOT` in the caller's
user namespace and is not a security sandbox. [Linux `chroot(2)`](https://man7.org/linux/man-pages/man2/chroot.2.html)

## 2. The experimental runtime

### 2.1 Identity, capabilities, and enforcement

The study reports the following identity and status fields:

```text
uid=0 gid=0 groups=0,65534
CapPrm: 000001ffffffffff
CapEff: 000001ffffffffff
CapBnd: 000001ffffffffff
Seccomp: 2
Seccomp_filters: 1
```

The mask has bits 0–40 set. These capability sets are meaningful within their
applicable user namespace; they do not confer unrestricted authority over the
outer host. Capability checks, UID/GID mappings, filesystem permissions, security
modules, and seccomp can independently constrain an operation. Retaining seccomp
does not make capability reduction pointless. [Linux capabilities](https://man7.org/linux/man-pages/man7/capabilities.7.html)

`Seccomp: 2` indicates filter mode. It neither exposes the filter rules nor proves
that a particular `EPERM` or `EINVAL` originated in seccomp. Filter actions can
return an error without executing the syscall, but attributing a denial requires
the policy or sufficiently discriminating probes. [Kernel seccomp documentation](https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html)

The reported kernel is `6.18.39-gentoo-dist-bin`, the architecture is x86-64, and
the processor is an AMD Ryzen 7 7700. The complete kernel build identification and
configuration are not supplied.

### 2.2 Operation-level results

Table 1 distinguishes direct probe results stated in the study from application
diagnostics. The missing probe programs and complete transcripts prevent checking
all arguments, return values, and controls.

| Operation | Reported result | Supported interpretation |
|---|---|---|
| `unshare` with requested namespace flags | `EPERM` | The tested request failed; the exact per-flag coverage is unavailable. |
| Mount attempt | Permission denied; utility exit status 32 | Mount setup failed. The utility's exit status is not a syscall errno. |
| Go spawn configured with namespace clone flags | `fork/exec …: operation not permitted` | Child creation or preparation failed; this message alone does not identify `clone` as the failing call. |
| `strace` startup using `PTRACE_TRACEME` | `EPERM` | The tested tracing request failed; other ptrace requests were not independently established. |
| Device-node creation with `mknod` | `EPERM` | The requested device node could not be created. |
| `setuid(1000)` | `EINVAL` | The requested UID change failed. |
| `setgroups` with an empty list | `EPERM` | Supplementary groups could not be cleared. |
| Ownership restoration including `chown 0:42` | `EINVAL` | The tested nonzero GID could not be assigned. |
| `chroot` into a prepared root filesystem | Success marker | This path-changing operation and the tested payload were permitted. |
| `memfd_create` | Success marker | Creation was permitted; executable memfd use requires a separate check. |
| `setgid(0)`, `setuid(0)` | Success | The tested identity-setting calls succeeded. |
| `setsid`, `prctl(PR_SET_PDEATHSIG, SIGTERM)` | Success | These individual process-management operations succeeded. |
| Executing a file from `/tmp` or `/workspace` | Success | The tested executable and path were usable. |

`EINVAL` on `setuid(1000)` is compatible with UID 1000 being unmapped in the
current user namespace. Likewise, `chown` documents `EINVAL` for unmapped IDs.
These results do not establish a policy denying every nonzero identity. [Linux
`setuid(2)`](https://man7.org/linux/man-pages/man2/setuid.2.html), [Linux
`chown(2)`](https://man7.org/linux/man-pages/man2/chown.2.html)

An empty `setgroups` request can fail when `/proc/self/setgroups` is `deny`, even
with capabilities in the current namespace. The displayed group 65534 can also
represent an unmapped supplementary group. The required discriminating evidence
includes `/proc/self/uid_map`, `/proc/self/gid_map`, `/proc/self/setgroups`, and
namespace identifiers; these are not supplied. [Linux user namespaces](https://man7.org/linux/man-pages/man7/user_namespaces.7.html)

The stated `max_user_namespaces` value, 2147483647, rules out only a zero value for
that particular limit. It does not identify seccomp as the cause or exclude other
namespace-creation constraints.

### 2.3 Filesystem and installed tools

The runtime is described as a Gentoo userspace with no accessible `/etc/passwd`,
`/etc/mtab`, `/etc/containers`, `/run`, or `/var`. Attempts to create `/run` and a
file under `/etc` fail. `/dev/fuse` is absent. The reported filesystem layout is a
16 GB tmpfs at `/`, a 64 MB tmpfs at `/tmp`, and writable ZFS storage at
`/workspace`; the unit convention for the tmpfs capacities is unspecified.

These observations establish inaccessible paths and unsuccessful writes. They do
not establish NFS-style root squashing or its equivalent on tmpfs. Mount options,
ownership mappings, ACLs, and the outer access policy would be needed to explain
the write restrictions. Absence of `/etc/passwd` also does not, by itself, exclude
every possible NSS identity source, although the study reports an unsuccessful
lookup of UID 0.

Reported tools include Go 1.26.4, GCC 15.3, Python 3.14.6, GNU tar 1.35, and zstd.
No working host package-management workflow, Rust toolchain, or musl compiler is
demonstrated. These are properties of the reported installation, not requirements
or limitations of the tools on other systems.

## 3. Methodology and versions

### 3.1 Study record

The reported experiments were performed as UID 0 on 2026-09-06. Most cited captures
are assigned to 16:45–17:12 UTC, with additional excerpts from 16:04–16:16 UTC.
Commands and diagnostics reproduced below are selected excerpts; ellipses and
omissions mean they are not complete verbatim transcripts.

The available study record consists of this manuscript's text. The 93-file
`evidence/` directory, probe sources, lilipod diff, rootfs, and onelf executable
are not included. Consequently, the empirical results below are **reported
observations**, not independently reproduced measurements. Documentation establishes
general mechanisms but cannot authenticate the reported runs or exact binaries.
References to moving upstream documentation describe those mechanisms rather than
reconstructing the listed builds.

| Tool | Reported version or revision | Reported acquisition |
|---|---|---|
| lilipod | `main` at abbreviated commit `872755a` | Source build with `CGO_ENABLED=0` |
| Podman | 5.8.2 | Preinstalled |
| Apptainer | 1.5.3 | `apptainer_1.5.3_amd64.deb` |
| runimage | Image 0.43.1; runtime 0.5.6 | Binary from the mutable `continuous` release |
| onelf | 0.3.3 | Prebuilt `onelf-x86_64-linux` |

These identifiers are insufficient for exact reconstruction. Full commit hashes,
release-asset hashes, dependency versions, OCI manifest digests, and package
repository snapshots are absent. `alpine:latest` and a `continuous` release are
mutable inputs.

### 3.2 Interpretation and measurement

A successful version query establishes that the queried executable starts. It does
not establish package installation, workload compatibility, or complete lifecycle
support. A failed early stage leaves later stages untested. Expected architectural
constraints are distinguished from failures actually reached by the command.

Reported durations are wall-clock values. Repetition counts, distributions, host
load, peak memory, and detailed cache controls are not supplied. The 0.088 s
lilipod launch, approximately 40 s runimage extraction, approximately 12 s onelf
packing, and 3.8 s packaged launch measure different operations and are not a
comparative performance benchmark. Clearing an application's extraction cache
does not establish a cold kernel page cache.

## 4. lilipod

lilipod provides image retrieval, extraction, and process-launch functions in a
small Go program. Its normal execution path uses namespaces and a changed root
filesystem. The upstream project presents a limited feature set and does not
claim parity with Docker or Podman. [lilipod project](https://github.com/89luca89/lilipod)

### 4.1 Stock build

The study reports a successful Alpine image pull. A stock launch fails with:

```text
fork/exec /workspace/lilipod/lilipod-stock: operation not permitted
```

The launch configuration requests namespaces, making a namespace restriction a
plausible explanation. However, Go can return the same diagnostic for several
operations before payload execution. Without per-operation instrumentation, it
does not uniquely establish a failed `clone` call.

A separate extraction attempt reports:

```text
tar: etc/shadow: Cannot change ownership to uid 0, gid 42: Invalid argument
tar: Exiting with failure status due to previous errors
```

This identifies ownership restoration as a failure in that attempt. Because the
captures use different launch conditions and omit parts of the configuration,
they do not establish one universal ordering of the spawn and extraction failures.

### 4.2 Chroot adaptation

The described adaptation has five functional components:

1. Enter the prepared rootfs without requesting new namespaces or UID/GID maps.
2. Retain the invoking identity where changing credentials is unnecessary.
3. Extract layers without restoring archive ownership.
4. Use `chroot` followed by `chdir("/")` instead of root-mount replacement.
5. Replace selected mount-dependent operations with explicitly limited behavior,
   including copying requested input directories into the rootfs.

Go's Linux spawn code calls `setgroups` for an ordinary non-nil credential
configuration, including an empty group list. It can skip that call through
`Credential.NoSetGroups` or a specific GID-mapping condition. Omitting
`Credential` is therefore one possible solution when identity is already correct,
not a requirement for all Go programs. Both approaches can retain supplementary
groups that cannot be cleared. [Go Linux spawn implementation](https://go.dev/src/syscall/exec_linux.go)

Using tar's `--no-same-owner` changes filesystem semantics: intended ownership is
not restored. Software that requires distinct owners or groups may consequently
fail or behave differently. Successful extraction is not equivalent to faithful
OCI filesystem reconstruction.

`pivot_root` changes mounts in the caller's existing mount namespace and requires
appropriate `CAP_SYS_ADMIN` authority and mount topology. It does not intrinsically
require creating a new namespace, although container runtimes normally use one
to contain its effects. The chroot adaptation avoids root-mount replacement.
[Linux `pivot_root(2)`](https://man7.org/linux/man-pages/man2/pivot_root.2.html)

The described patch skips hostname changes, mount-dependent setup, and capability
reduction. Avoiding a shared hostname change is appropriate, but retaining
capabilities is a limitation, not a security equivalence. Capability reduction
should be assessed separately from seccomp restrictions.

The reported mode detector returns true when UID is 0 and an
`unshare(CLONE_NEWNS)` probe fails. That condition neither proves chroot support
nor fully characterizes the runtime. A probe must run in a disposable helper:
a successful call changes the caller's namespace, and probing inside a Go process
also requires attention to OS-thread state. Mode selection should test its actual
prerequisites and report the reason for fallback.

### 4.3 Reported results

| Operation | Result and scope |
|---|---|
| Pull Alpine | Reported successful. |
| Run `/bin/echo` | Output `hello-from-patched-lilipod` is shown. |
| Run `apk --version` | Reports `apk-tools 3.0.6-r0`; network installation is untested. |
| `create`, detached `start`, `ps`, `stop`, `rm` | Reported successful for selected test containers. |
| `logs` | An empty result for a silent payload is reported; capture of emitted output is unverified. |
| `-v /host/dir:/data` | Copy-in behavior is reported; this is not a live bind mount. |
| Read-only volume semantics | Not implemented by the described copy mechanism. |
| `exec` | Unsuccessful in the tested configuration. |
| `--tty` | Unsuccessful in the tested configuration. |

A warm `run --rm … /bin/true` duration of 0.088 s is reported. It is a single
published timing value without a supplied sample distribution.

The described process-status mechanism searches
`/proc/<pid>/root/run/.containerenv`. This depends on access to other processes'
root links and is vulnerable to races and ambiguous or mutable marker files; it
is not a general process-membership guarantee.

Detached-process survival is reported to depend on the launch harness. A parent
death signal is delivered when the creating parent thread exits, subject to Linux's
documented semantics. It is not a generic signal propagated from any ancestor.
The supplied excerpts do not establish the exact parent/thread relationship in the
`timeout` experiment. [Linux `PR_SET_PDEATHSIG`](https://man7.org/linux/man-pages/man2/PR_SET_PDEATHSIG.2const.html)

### 4.4 Unresolved execution and PTY failures

The `exec` path reportedly fails while resolving `/bin/sh`, with
`stat /bin/sh: no such file or directory`. Separate direct-entry tests reportedly
succeed. This establishes a difference between the tested execution paths, not
its cause. Go's lookup of a name containing `/` checks that path directly;
changing `PATH` alone does not explain failure of the absolute path `/bin/sh`.
[Go executable lookup](https://go.dev/src/os/exec/lp_unix.go)

Useful discriminating data would include the selected rootfs and its identity,
the resolved symlink chain, configuration, working directory, and the exact failing
stage. No specific configuration or environment bug is localized by the available
record.

The tested PTY path fails without a usable device setup inside the rootfs. This
does not establish that all PTY use is impossible: a supervisor could potentially
allocate a PTY before chroot and pass the open descriptors to the child. That
alternative, its controlling-terminal setup, and payloads that reopen device paths
were not tested.

## 5. Podman

The study reports these diagnostics under UID 0:

```text
$ podman info
Error: no such file or directory
$ podman unshare echo ok
Error: no such file or directory
```

These are initialization failures, not direct observations of a rootless
`CLONE_NEWUSER` failure. A UID-0 invocation and a failed attempt to switch to UID
1000 do not constitute a successful test setup for a normal non-root Podman
invocation. The evidence supports the narrower conclusion that such an invocation
was not established in this session.

Missing default directories are a plausible initialization problem, but the
diagnostic does not identify the missing path. Podman exposes configurable storage,
runtime-state, and temporary directories through `--root`, `--runroot`, and
`--tmpdir`; downloaded-image temporary storage also has its own setting. The
reported environment-variable changes do not document an exhaustive configuration
test. [Podman command reference](https://docs.podman.io/en/latest/markdown/podman.1.html)

If the namespace and mount operations required by a particular local OCI launch
remain denied, moving storage directories cannot by itself make that launch work.
Nevertheless, the available commands do not prove that every Podman configuration,
storage-only operation, or remote-service use is impossible. The result is
**initialization unsuccessful in the tested setup; local container execution not
demonstrated**.

Docker Engine is outside the measured comparison. A `docker` command can be a
Docker client, a wrapper, or a Podman compatibility command; its identity requires
inspection. A Docker client without a running daemon does not establish a kernel
limitation. A reproducible Docker comparison would identify both binaries, start
the local daemon where available, and record its startup and workload results.
[Docker daemon startup documentation](https://docs.docker.com/engine/daemon/start/)

## 6. Apptainer

### 6.1 Initialization and image extraction

The reported Apptainer setup unpacks the Debian package into a prepared chroot and
supplies identity files, a compatible dynamic loader and libraries, and a CA bundle.
It also supplies a static `/proc/self/mountinfo` because a procfs mount is unavailable.
The resulting environment is a modified execution context, which limits comparison
with a normal Apptainer installation.

A copied outer mount table reportedly leads to:

```text
unable to create new build: failed to find mount point for /tmp:
no parent mount point found
```

A synthetic table consistent with the extraction filesystem is reported to let
initialization proceed. Such a table is an application-specific fixture: it does
not mount procfs or supply a live kernel view. Device numbers and paths are local
to that setup and cannot be copied unchanged as a portable configuration.

The invocation then reaches image extraction and reports:

```text
while unpacking layer …: unpack entry: etc/shadow:
apply hdr metadata: restore chown metadata:
lchown …/rootfs/etc/shadow: invalid argument
```

The supported result is **OCI retrieval and conversion initialization proceeded;
ownership restoration failed before successful SIF creation**. No completed SIF
build or container execution is demonstrated.

A libc interposer cannot intercept a call issued directly through the Linux
syscall interface. Go's direct syscall paths therefore require a source-level
change, an appropriate unpacker option, or preparation of compatible content
outside this path; `LD_PRELOAD` is not a universal solution. This is a limitation
of that interception method, not proof that the unpacker cannot be modified.

### 6.2 Runtime requirements

Apptainer supports installations using user namespaces and installations with a
setuid helper. Its fakeroot feature combines user mappings and the separate
fakeroot command in several configurations; PRoot is not a documented fallback
in that feature. [Apptainer fakeroot modes](https://apptainer.org/docs/user/main/fakeroot.html)

Direct image mounts, FUSE-assisted paths, and namespace setup have distinct
requirements. An absent usable `/dev/fuse` excludes a FUSE path requiring that
device. Extracting an image into a directory can avoid mounting the image file,
but does not automatically eliminate Apptainer's remaining mount and namespace
setup. A setuid helper also remains subject to inherited restrictions. [Apptainer
installation guide](https://apptainer.org/docs/admin/main/installation.html)

The observed stopping point is ownership restoration. Under the reported mount
and namespace restrictions, normal runtime setup has additional expected barriers,
but the study does not show completed tests of every execution configuration or
of a prebuilt directory image. No successful Apptainer execution is demonstrated.

## 7. runimage

runimage distributes a Linux userspace in a portable single-file package. Its
normal launcher uses bubblewrap, while the image runtime provides mounting or
extraction of the bundled filesystem. The reported artifact contains an Arch
Linux rootfs in DwarFS and a supporting `RunDir` toolset. [runimage
project](https://github.com/VHSgunzo/runimage), [DwarFS project](https://github.com/mhx/dwarfs)

### 7.1 Normal launch and extraction

The reported launch uses writable workspace storage for temporary extraction:

```sh
TMPDIR=/workspace/tmp RIM_ALLOW_ROOT=1 RIM_NO_NVIDIA_CHECK=1 \
    ./runimage-x86_64 bash -c 'echo inside-runimage'
```

The directory must already exist and have sufficient free space. Selected
diagnostics are:

```text
runimage-x86_64: failed to utilize FUSE during startup!
bwrap: Failed to make / slave: Operation not permitted
```

Extraction between these stages is reported to complete in approximately 40 s.
The bubblewrap diagnostic identifies a failure to configure mount propagation;
the payload does not start through the normal launcher. Bubblewrap's documented
sandbox construction uses a mount namespace, so extracting the image alone does
not remove that requirement. [bubblewrap project](https://github.com/containers/bubblewrap)

With `/tmp` as the extraction destination, the study instead reports repeated
`archive_error: short write: -20 != N` messages. This is insufficient to identify
a failed `copy_file_range` or `sendfile` call. On Linux x86-64, `ENODEV` is 19 and
`ENOTDIR` is 20; a library's negative status must not be decoded as a kernel errno
without checking its interface. In libarchive, `-20` denotes `ARCHIVE_WARN`, with
details obtained separately through its error-reporting API. The exact DwarFS
call site is not supplied. [libarchive status definitions](https://github.com/libarchive/libarchive/blob/master/libarchive/archive.h)

The stated 64 MB `/tmp` capacity is also much smaller than the reported 298 MB
rootfs, although the size conventions and allocated-space measurements are
unspecified. Free blocks, free inodes, sparse files, metadata operations, and
extraction-library errors are unresolved factors. Success on `/workspace` establishes
a working destination in this test, not a general incompatibility with tmpfs.

### 7.2 Direct entry into the root filesystem

The reported `--runtime-extract` operation makes `RunDir/rootfs` available as a
directory. A prepared directory can be entered without invoking runimage's
bubblewrap launcher, provided `chroot` is permitted and the binaries and their
loader are compatible with the host kernel and CPU.

The following preparation example assumes a trusted, writable extracted tree,
ordinary `rootfs/etc` directories, and an accessible outer `/etc/resolv.conf`:

```sh
set -eu
rootfs_dir=/workspace/runimage/RunDir/rootfs
test -d "$rootfs_dir/etc"
test ! -L "$rootfs_dir/etc"

# Replace rootfs configuration links before writing through these paths.
rm -f -- "$rootfs_dir/etc/resolv.conf"
cp -- /etc/resolv.conf "$rootfs_dir/etc/resolv.conf"
rm -f -- "$rootfs_dir/etc/mtab"
printf 'none / none rw 0 0\n' > "$rootfs_dir/etc/mtab"

chroot "$rootfs_dir" /bin/bash
```

The static `mtab` is a minimal compatibility fixture, not a measured mount table.
It deliberately supplies no fictitious `/tmp` mount or host-specific ZFS device.
Programs requiring accurate mount topology need an appropriately generated view
or remain unsupported. Package-manager compatibility with this minimal fixture
has not been measured. Removing the link before writing is essential: redirection
to the image's `mtab -> ../proc/self/mounts` link otherwise follows its target.

The study reports these userspace observations:

```text
NAME="Arch Linux"
PRETTY_NAME="Arch Linux"
210
Python 3.14.7
```

The number 210 is the output of a package-list count in one rootfs state.
An installation invocation for `tree` reports that package changes are being
processed. The subsequent `tree -L 1 /etc/apk` starts the binary but reports a
directory error: `/etc/apk` is not a valid positive filesystem test for this Arch
rootfs. Python execution, a Python HTTPS request, and another package-management
invocation are also reported.

These observations support selected command execution and limited package-manager
use. They do not establish a complete Arch environment, successful installation
from every configured repository, or verified signature enforcement. Those claims
would require package versions, transaction exit statuses, repository and trust
configuration, and appropriate verification tests. Availability of `getrandom`
alone establishes neither TLS success nor package-signature policy.

The rootfs lacks live `/proc`, `/sys`, and the usual mounted device filesystems in
this configuration. Applications requiring these interfaces, working PTYs,
different ownership, privilege changes, services, or restricted syscalls may fail.
The packaged and unpackaged tests share those limitations.

### 7.3 Packaging with onelf

The study reports packing the extracted tree with onelf 0.3.3 using an entrypoint
that obtains the extraction directory from `ONELF_DIR` and invokes the host's
`chroot` utility. The onelf source revision and executable are unavailable for
verification; its mode names and behavior here are the interfaces reported by
this experiment.

Selected startup diagnostics identify failed FUSE and namespace attempts:

```text
fusermount3: fuse device /dev/fuse not found. Kernel module not loaded?
onelf-rt: fuse: mount failed: fusermount3 exited with exit status: 1
onelf-rt: tmpfs: enter_namespace failed: unshare: Operation not permitted (os error 1)
```

The study attributes the successful fallback to eager extraction into a private
runtime directory. These messages do not by themselves establish the complete
fallback order, the chosen directory, cleanup under failure, or executable-memfd
support. Those require the artifact and a mode-specific execution record.

The bundle preparation is reported to modify 26 symlinks while retaining 1,558
relative links. The precise link manifest and transformation are absent. A
relative link such as `rootfs/etc/mtab -> ../proc/self/mounts` resolves within
`rootfs/proc` and does not lexically escape the bundle; it can instead be dangling.
Likewise, absolute links may be valid inside a chroot even if a packager rejects
their extraction-time interpretation. Link handling must distinguish confinement,
target existence, and intended resolution after chroot. Blanket removal can change
the userspace's behavior.

The reported pack command is:

```sh
onelf pack packdir/RunDir -o runimage-arch.onelf --command utils/onelf-entry
```

The entrypoint in Appendix B.2 defines a minimal launch interface. It is a reference
implementation, not the measured binary used for the reported timing.

| Quantity | Reported value | Interpretation |
|---|---|---|
| Initial rootfs size | 298 MB | Measurement method and byte convention unspecified. |
| Packed tree content | 603.7 MB | Pack-tool display; includes a different tree/state from the initial rootfs. |
| Deduplication saving | 12.3 MB | Pack-tool display; underlying file manifest unavailable. |
| Compressed payload | 213.6 MB | Pack-tool display; unit convention unverified. |
| Final executable | 225,641,729 bytes | Exactly 225.641729 MB or approximately 215.19 MiB. |
| Packing duration | Approximately 12 s | Unreplicated reported value. |
| Fresh-extraction launch | 3.8 s | Extraction cache reportedly cleared; page-cache state and repetitions unspecified. |

The displayed 215.2 MB output size is numerically consistent with binary MiB, not
decimal MB. The exact byte count is the authoritative reported size. The difference
between the 298 MB rootfs and 603.7 MB packed content cannot be assigned to a
specific cause without consistent size measurements and manifests.

The packaged rootfs is reported to contain 214 packages. In the reported
`ONELF_MODE=cache` configuration, installing `sl` is followed by a separate
invocation finding `/usr/sbin/sl`. This supports reuse of a modified extracted
tree across those invocations. It does not demonstrate that the executable itself
changes, that a copied executable contains the installation, or that concurrent
writers and interrupted updates are handled safely.

This is single-file distribution of a userspace, with execution dependencies:
the reported shell entrypoint requires an outer `/bin/sh`, a `chroot` utility,
appropriate privilege, and sufficient writable storage. No additional kernel or
isolation boundary is bundled.

## 8. Comparative analysis

Table 2 uses only the reported target-runtime results. **Not reached** means an
earlier stage failed; **not tested** means no result is supplied. A successful
rootfs command is not equivalent to a successful native container launch.

| Configuration | Image/rootfs preparation | Workload launch | Package-management evidence | Residual limits |
|---|---|---|---|---|
| Stock lilipod | Pull succeeds; one extraction attempt fails restoring ownership | Spawn fails | Not reached | Failing spawn syscall not uniquely identified |
| Adapted lilipod | Extraction without original ownership reported | Selected lifecycle operations succeed | `apk --version` only | `exec` and tested PTY path fail; volumes are copies; nonempty logs unverified |
| Podman | Initialization fails | Not reached | Not reached | Non-root setup not established; configuration cause unresolved |
| Apptainer | OCI retrieval proceeds; ownership restoration fails | Not reached | Not reached | No completed SIF build; runtime barriers also expected |
| runimage normal launcher | Extraction succeeds using workspace temporary storage | bubblewrap mount setup fails | Not reached | No native payload execution demonstrated |
| runimage rootfs through chroot | Directory rootfs available | Selected utilities execute | Limited pacman activity reported | Ownership, devices, procfs, and other interfaces remain restricted |
| runimage rootfs through chroot and onelf | Packaging and extraction reported | Selected packaged commands execute | Limited installs and cache persistence reported | Same execution limits; external launcher dependencies; timing unreplicated |

Registry access, extraction, and execution must be assessed separately. The reported
lilipod and Apptainer pulls show that some registry I/O can proceed, but Podman's
initialization failure prevents a claim that every tool's image plane works.
Extraction itself can depend on ownership, link semantics, device metadata, and
storage capacity.

The observed failure categories include namespace-related setup, mount setup,
identity changes, ownership restoration, and missing paths or devices. The record
does not support reducing every failure to a fixed list of conclusively identified
syscalls. Successful chroot configurations retain shared namespaces and inherited
restrictions; their utility lies in access to selected image-derived programs.

## 9. Design implications: explicit compatibility modes

The results motivate a runtime that separates execution compatibility from security
requirements. The following design is a proposal, not an implementation or a
demonstrated general solution.

### 9.1 Mode selection

The runtime should report its effective mode and require an explicit request for
operation with reduced isolation. A workload that requires isolation must fail if
that requirement cannot be met.

| Mode | Required mechanisms | Scope |
|---|---|---|
| Namespace-based execution | A usable combination of namespaces, filesystem setup, credentials, and other requested controls | Isolation depends on the full configuration, not namespace creation alone. |
| Chroot compatibility | A prepared rootfs, usable `CAP_SYS_CHROOT`, and supported payload syscalls | Path-root change within the outer environment; no independent process or network isolation. |
| Libc-interposition compatibility | Compatible dynamically linked programs and sufficiently complete interception | Limited path/metadata emulation for cooperative workloads; no security boundary. |
| Unsupported | A required mechanism is unavailable | An explicit diagnostic identifying the unmet requirement. |

Tests should run in disposable helpers and record individual operations and errors.
The ability to create one namespace does not prove that mounts, mappings, devices,
or the intended workload will work. Similarly, failure of `unshare` is not a
positive test for chroot or libc-interposition compatibility.

### 9.2 Filesystem and metadata behavior

An ownership-neutral unpacker can preserve intended metadata separately, but that
metadata does not change kernel permission checks. Exporting it faithfully needs
an explicit format and tests. OCI extraction must also apply layers in order,
interpret whiteouts and opaque directories, preserve required links, and prevent
archive paths from writing outside the destination. `--no-same-owner` alone does
not establish these properties. A vetted library or carefully constrained external
extractor can be used; the choice of an in-process implementation is not itself a
correctness guarantee. [OCI filesystem-layer specification](https://github.com/opencontainers/image-spec/blob/main/layer.md)

A libc shim is one possible path-translation mechanism, as in fakechroot. It must
handle loader startup, path resolution, relative directory descriptors, symlinks,
working directories, and child execution. Successful execution under a real
`chroot` does not establish that a shim covers these operations. [fakechroot
project](https://github.com/dex4er/fakechroot)

Static binaries and direct-syscall paths bypass ordinary `LD_PRELOAD` wrappers;
dynamically linked programs may also issue direct syscalls. ELF interpreter and
language markers can inform compatibility checks but cannot certify coverage.
PRoot uses ptrace-based interception and would require a usable tracing path.

### 9.3 Credentials, devices, and process management

The supervisor should request only supported credential transitions, retain them
where they are required and permitted, and expose failures. Omitting credential
changes or faking identity answers does not change the real identity or remove
inherited supplementary-group access.

Copy-in data must be exposed as a copy operation, with documented update and export
semantics. A request for a live or read-only mount must be rejected when that
semantics is unavailable.

In chroot mode, ordinary absolute paths cannot access device nodes outside the
new root. Preopened file descriptors can support selected uses, including a
potential PTY implementation, but a pathname rewrite to an outer absolute path
does not overcome the changed root. A pure interposition mode has different
constraints and needs its own device tests.

Static `/proc` fixtures can satisfy a narrow reader but cannot implement a live
process interface. Process supervision should record launched children and use
appropriate wait and signal mechanisms. Pidfds can address individual processes;
they do not automatically identify or contain all descendants. Process groups,
reparenting, daemonization, cleanup, and any requested `exec` semantics need explicit
handling. None of these mechanisms supplies PID-namespace isolation.

### 9.4 Packaging and state

A distribution artifact should identify immutable inputs, runtime dependencies,
metadata transformations, and the selected execution mode. Persistent changes
should be separated from the immutable image or clearly labeled as mutable cache
state, with defined locking and recovery. A rootfs bundle is not made executable
entirely from memory merely because one static launcher can use a memfd; normal
payloads still require their filesystem and libraries. Delta updates and robust
cache management remain unimplemented proposals here.

## 10. Limitations

The study concerns one reported runtime, architecture, and day of experiments.
Neither population-level prevalence nor behavior on other sandboxes is measured.
The seccomp policy, user mappings, complete probes, exact image digests, patch,
and binary artifacts are absent, preventing precise reproduction and causal
attribution for several failures.

The tests cover selected utilities and lifecycle operations. They do not establish
general OCI compliance, isolation, complete package-manager functionality, a
fully operational distribution, or support for services and device-dependent
programs. Ownership loss, inherited groups, and static mount fixtures materially
change the execution environment.

All timing claims lack a supplied sample distribution and comprehensive cache
controls. Different operations and payload states are not directly comparable.
The onelf symlink transformation and growth of the packed tree are unauditable
without their manifests.

The proposed libc-interposition mode is unimplemented and unbenchmarked. Its
coverage cannot be inferred from successful chroot execution. The relevant
fakechroot and udocker baselines are not evaluated in this runtime.

## 11. Related work

The directly studied tools are [lilipod](https://github.com/89luca89/lilipod),
[Podman](https://github.com/podman-container-tools/podman),
[Apptainer](https://github.com/apptainer/apptainer), and
[runimage](https://github.com/VHSgunzo/runimage). The reported packaging tool is
[onelf](https://github.com/qaidvoid/onelf); its cited artifact and implementation
were not available for independent inspection.

[Fakeroot](https://tracker.debian.org/pkg/fakeroot) provides simulated privileged
file-metadata operations. [Fakechroot](https://github.com/dex4er/fakechroot)
interposes selected libc functions to provide a simulated chroot environment.
[PRoot](https://proot-me.github.io) uses ptrace for filesystem and related
interception. These are distinct mechanisms with different workload coverage.

[udocker](https://github.com/indigo-dc/udocker) already integrates image handling
with several execution engines, including PRoot and Fakechroot. It is a direct
baseline for the proposed multi-mode compatibility design. The potential
contribution of this case study is therefore its particular restriction profile
and reported adaptation experience, rather than invention of interposition-based
container execution.

[Bubblewrap](https://github.com/containers/bubblewrap) supplies low-level sandbox
construction. [Sharun](https://github.com/VHSgunzo/sharun) supports relocatable
dynamically linked executables by preparing and invoking an ELF interpreter and
its libraries; it does not establish a complete virtual filesystem.
[DwarFS](https://github.com/mhx/dwarfs) supplies compressed filesystem images and
extraction/mounting tools. These distribution and launcher mechanisms should be
distinguished from the kernel controls that determine isolation.

## 12. Conclusion

The reported results show that selected image-derived programs can remain useful
when normal container launch paths fail. lilipod's described adaptation and direct
entry into runimage's rootfs rely on a permitted, privileged `chroot` operation
and a restricted subset of normal filesystem and process semantics. Podman does
not initialize in the tested setup, Apptainer stops during ownership restoration,
and runimage's normal launcher fails during bubblewrap mount setup.

The onelf package is reported to occupy 225,641,729 bytes and to launch in 3.8 s
with a fresh extraction cache. These values are specific, unreplicated reports
whose artifacts are not supplied. They support further evaluation of portable
userspace packaging, not general performance or self-containment claims.

A useful compatibility runtime must state its real prerequisites, preserve
requested security requirements, and identify unsupported semantics. The present
evidence motivates that design while leaving its generality and interposition
coverage to be established experimentally.

## Appendix A: Data availability and reproduction requirements

The manuscript identifies the following materials, but they are not included in
the available submission:

| Material named in the study | Intended contents |
|---|---|
| `env-*.txt` | Environment and operation probes |
| `env-spawnattr.txt` | Process attributes and credential-setting results |
| `lilipod-stock-*.txt` | Stock build, pull, and launch attempts |
| `lilipod-patched-*.txt`, `lilipod-p2-*` through `lilipod-p8-*` | Adapted lifecycle and copy-in tests |
| `podman-*.txt` | Version, initialization, and identity-change attempts |
| `apt-*.txt` | Apptainer setup and extraction failures |
| `runimage-fuse-fail`, `rim1-3.log` | Normal-launch and extraction diagnostics |
| `runimage-chroot-enter`, `runimage-pacman-install` | Direct-rootfs commands and package operations |
| `onelf-*.txt` | Packaging, launch, persistence, and timing |
| `lilipod-patch.diff` | Source changes for the adaptation |

An independently reproducible release needs the complete command/exit-status
record, probe sources, applicable policy and mapping information, immutable inputs,
patch and build instructions, rootfs and symlink manifests, and checksums of the
distributed artifacts. Timing records need operation definitions, independent
repetitions, cache conditions, and resource measurements. A policy-matched control
environment would strengthen causal attribution; results from a different host
must remain a separate experiment.

## Appendix B: Adaptation specification and entrypoint

### B.1 Described lilipod components

The adaptation description names five source paths. Its exact size and behavior
cannot be established without the diff.

| Path | Described responsibility |
|---|---|
| `pkg/sandbox/restricted.go` | Detect a candidate compatibility mode; a production detector needs disposable, operation-specific probes. |
| `pkg/procutils/proc_utils.go` | Avoid the namespace-based fake-root re-execution in compatibility mode. |
| `pkg/containerutils/container_utils.go` | Configure child launch without unsupported namespace/mapping operations and attempt direct-rootfs `exec`. |
| `pkg/containerutils/rootfs_utils.go` | Prepare selected directories and copied inputs; perform `chroot` and `chdir`; avoid mount and hostname setup. |
| `pkg/fileutils/file_utils.go` | Extract without restoring original ownership in compatibility mode. |

This specification is not a buildable patch. The unresolved `exec`, PTY,
credential, and logging limitations remain as stated in §4.

### B.2 Reference onelf entrypoint: `utils/onelf-entry`

This script assumes the reported `ONELF_DIR` interface, a trusted prepared bundle
with real `rootfs` and `rootfs/etc` directories, host shell utilities, and a usable
host `chroot`. It accepts an absolute command path inside the rootfs and inherits
the invoking environment. The static mount-table fixture offers only the narrow
compatibility described in §7.2. Full onelf integration is not validated by the
script's presence.

```sh
#!/bin/sh
set -eu

: "${ONELF_DIR:?onelf-entry: ONELF_DIR must name the extraction directory}"
case "$ONELF_DIR" in
    /*) ;;
    *) echo 'onelf-entry: ONELF_DIR must be absolute' >&2; exit 1 ;;
esac

bundle_dir=$(CDPATH= cd -P -- "$ONELF_DIR" && pwd -P)
rootfs_dir="$bundle_dir/rootfs"
test -d "$rootfs_dir"
test ! -L "$rootfs_dir"
test -d "$rootfs_dir/usr"
test -d "$rootfs_dir/etc"
test ! -L "$rootfs_dir/etc"

if [ -L "$rootfs_dir/etc/mtab" ]; then
    rm -f -- "$rootfs_dir/etc/mtab"
fi
if [ ! -e "$rootfs_dir/etc/mtab" ]; then
    printf 'none / none rw 0 0\n' > "$rootfs_dir/etc/mtab"
fi
test -f "$rootfs_dir/etc/mtab"

if [ "$#" -eq 0 ]; then
    set -- /bin/bash -l
fi
case "$1" in
    /*) ;;
    *) echo 'onelf-entry: command must be an absolute rootfs path' >&2; exit 1 ;;
esac

chroot_cmd=$(command -v chroot) || {
    echo 'onelf-entry: host chroot utility unavailable' >&2
    exit 1
}
exec "$chroot_cmd" "$rootfs_dir" "$@"
```
