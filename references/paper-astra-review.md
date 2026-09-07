# Peer review of *Containers Without Privileges*

**Manuscript reviewed:** `paper.md`, version 1.0, 2026-09-06.  
**Review date:** 2026-09-07.  
**Recommendation:** Major revision before consideration as an empirical systems paper.

The manuscript contains a useful practical observation: extracting an image and
running selected programs can remain possible when a container tool's normal
launch path fails. Its attention to ownership restoration, supplementary groups,
missing filesystem interfaces, and packaging is valuable. The central result
needs a narrower interpretation, however. The working configurations use
privileged `chroot`, the reported experiments are not reproducible from the
attachment, and several explanations conflate an application error with its
underlying kernel cause.

I read the complete 730-line manuscript, including both appendices. The accompanying
`paper_v2.md` is a clean replacement manuscript: corrections are incorporated into
the relevant sentences, tables, and examples. It contains no revision chronology
or sequence of appended corrections. Missing empirical evidence is identified
as a methodological limitation rather than replaced with invented results.

## Assessment

| Criterion | Assessment |
|---|---|
| Practical relevance | Strong: restricted execution environments create useful compatibility problems. |
| Technical accuracy | Major corrections required in privilege semantics, causal attribution, and tool comparisons. |
| Empirical support | Selected excerpts support a limited case report; several broader conclusions are untested. |
| Reproducibility | Insufficient: logs, probes, patch, immutable inputs, and packaged artifact are missing. |
| Novelty | The particular case may be informative; a multi-engine compatibility design has substantial prior art. |
| Presentation | The troubleshooting narrative obscures the result; the clean v2 organizes claims by mechanism and evidence. |

## Major findings

### 1. The title and central privilege claim are incorrect

UID 0 with a working `chroot` is not a zero-privilege execution environment.
`chroot` requires `CAP_SYS_CHROOT` in the applicable user namespace. It supplies
neither process nor network isolation, and Linux explicitly does not present it
as a security sandbox. The title should describe **limited privileges and denied
namespace creation**, not the absence of privileges or namespaces. Every Linux
process already belongs to namespaces. [Linux `chroot(2)`](https://man7.org/linux/man-pages/man2/chroot.2.html)

The statement that capability bits are fictitious is also wrong. Capabilities,
seccomp, mappings, and filesystem restrictions act together. Skipping capability
reduction may preserve authority over operations that remain permitted; seccomp
does not make that authority irrelevant. V2 states this as a limitation of the
described patch. [Linux capabilities](https://man7.org/linux/man-pages/man7/capabilities.7.html)

### 2. The manuscript does not identify the source of every denial

`Seccomp: 2` establishes filter mode, not the content of the filter or the source
of each errno. A high `max_user_namespaces` value likewise does not prove that
seccomp caused a namespace failure. [Kernel seccomp documentation](https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html)

Unmapped IDs are a documented explanation for `EINVAL` from `setuid` and `chown`.
An inherited `/proc/self/setgroups` value of `deny` can explain the empty-group
failure. These are alternative hypotheses, not diagnoses established by the
attachment. Supply UID/GID maps, the setgroups setting, relevant namespace
identifiers, policy information, and exact probe programs. [Linux
`setuid(2)`](https://man7.org/linux/man-pages/man2/setuid.2.html), [Linux
`chown(2)`](https://man7.org/linux/man-pages/man2/chown.2.html), [Linux user
namespaces](https://man7.org/linux/man-pages/man7/user_namespaces.7.html)

The table also overgeneralizes from tested examples to every namespace flag,
nonzero owner, and ptrace operation. A mount utility's exit status 32 is not a
syscall errno. V2 reports the narrower operations actually represented by the
excerpts and leaves their enforcement mechanism unresolved.

### 3. The claimed evidence package is absent

Only `paper.md` was supplied. The 93 transcript files, probe code, full patch,
sanitizing script, rootfs, and 225,641,729-byte executable are unavailable. Appendix A
is an index, not the underlying experiment record. The text also includes ellipses,
filtered output, and earlier excerpts, so the blanket verbatim-output claim is
inaccurate.

The version table does not pin the experiment: `alpine:latest`, `continuous`,
abbreviated commits, and version labels without asset hashes leave mutable inputs.
The patch summary lists **five source paths**, despite claiming four changed files;
neither the insertion/deletion count nor the implementation can be validated.

V2 retains reported results with explicit provenance, removes the exact patch-size
claim, and states data availability directly. This editorial correction does not
resolve the missing replication package.

### 4. The Go spawn explanation overlooks a supported alternative

Go's Linux spawn implementation can skip `setgroups` using
`Credential.NoSetGroups`; it also contains a GID-mapping exception. Omitting
`Credential` is one option when identity is already correct, not an architectural
requirement. Retaining identity also retains supplementary-group access when it
cannot be cleared. [Go Linux spawn source](https://go.dev/src/syscall/exec_linux.go)

The generic `fork/exec …: operation not permitted` message can arise during child
creation or subsequent preparation. It is not sufficient to pinpoint `clone`.
The namespace probe itself also has side effects if it succeeds and should run
in a disposable helper, with Go thread behavior considered.

### 5. Podman and Apptainer are assessed beyond the tested stopping points

Podman reports an unidentified missing path under UID 0. These commands do not
constitute a completed rootless test. Its storage, state, and temporary paths are
configurable, so missing defaults do not prove universal impossibility. Expected
mount or namespace barriers should be described conditionally. [Podman command
reference](https://docs.podman.io/en/latest/markdown/podman.1.html)

Apptainer stops during ownership restoration, before a completed SIF build. The
conclusion's claim of a full SIF build contradicts the shown failure. Its documented
fakeroot modes use user mappings and/or fakeroot; the paper does not substantiate
its claimed built-in PRoot fallback. Directory images, setuid setup, and image
mounting must be distinguished, and untested paths must not be counted as observed
failures. [Apptainer fakeroot documentation](https://apptainer.org/docs/user/main/fakeroot.html)

A direct Go syscall is outside ordinary libc interposition, but that does not make
the unpacker unmodifiable. V2 limits the conclusion to that interception boundary
and the observed extraction failure.

### 6. The extraction-error diagnosis is unsupported and numerically wrong

On Linux x86-64, `ENODEV` is 19; 20 is `ENOTDIR`. More fundamentally, a negative
library return value cannot be assumed to encode errno. Libarchive defines
`ARCHIVE_WARN` as `-20`, and provides separate error-detail functions. The exact
DwarFS call site is needed before identifying the status in this particular log.
[Libarchive status definitions](https://github.com/libarchive/libarchive/blob/master/libarchive/archive.h)

The 64 MB temporary filesystem is also smaller than the reported 298 MB rootfs.
That makes capacity an obvious uncontrolled factor, not a proven alternative
diagnosis. Free-space/inode measurements and complete extraction diagnostics are
required. V2 removes the causal claim about tmpfs rejecting a `copy_file_range` or
`sendfile` source.

### 7. The filesystem preparation and symlink explanation need correction

The §7.2 command writes to `/etc/mtab` while it is still a symlink. I reproduced
the local filesystem behavior: writing through the dangling
`etc/mtab -> ../proc/self/mounts` link fails with `ENOENT`. The link must be
removed before a regular file is written.

That relative target resolves within the rootfs; it is not an example of lexical
escape from the package root. Dangling targets, valid absolute links in a chroot,
and extraction-time confinement are different questions. The missing 26-link
transformation manifest prevents auditing the claimed sanitization.

V2 fixes the preparation example and supplies a bounded reference entrypoint. Its
static mount-table fixture does not invent a `/tmp` mount or assume a portable ZFS
device number. This is still a compatibility fixture, not a substitute for live
kernel mount information.

### 8. Workload and lifecycle success are overstated

| Claim in the submission | Evidence-supported assessment |
|---|---|
| Fully functional Arch Linux | Selected utilities and package operations are reported; procfs, devices, identity changes, and services remain restricted. |
| Verified package management across listed repositories | Repository provenance, exit statuses, trust configuration, and transaction records are absent. |
| Signature verification follows from `getrandom` | Randomness availability does not establish signature enforcement or TLS configuration. |
| `logs` works | An empty result from a silent command does not demonstrate output capture. |
| Volumes work | The described feature copies inputs; live mounts and read-only mount semantics are absent. |
| PTYs are impossible | The tested path fails; allocating and passing a PTY before chroot remains untested. |
| `exec` localized to configuration/environment | The root cause is unresolved; absolute `/bin/sh` lookup does not depend on searching `PATH`. |
| runimage native package management succeeds | Its normal launcher never reaches the payload on this target. |

The absolute-path distinction follows directly from Go's executable lookup code.
[Go lookup implementation](https://go.dev/src/os/exec/lp_unix.go)

V2 applies one evidence convention throughout the comparison: success in the
reported test, failure in the reported test, not reached, or not tested.

### 9. Packaging and timing claims need controlled definitions

The exact reported size converts to **215.1887216568 MiB** or **225.641729 MB**.
Calling it 215 MB conflates binary and decimal units. The 298 MB rootfs and
603.7 MB pack input also require consistent measurement methods and a file
manifest before the increase can be explained.

The 3.8 s value lacks repetition counts, variability, host-load information, and
a precise timed boundary. Deleting an extraction cache does not clear the kernel
page cache. The 0.088 s lilipod invocation and onelf launch are not comparable
benchmarks. V2 calls the latter a reported fresh-extraction launch.

The shell entrypoint depends on host `/bin/sh`, `chroot`, privilege, and writable
storage. Cache-mode persistence changes an extracted tree; it does not prove that
the distributed executable is updated. Full self-containment, cleanup guarantees,
and concurrent mutation safety remain unestablished.

### 10. The proposed design needs narrower claims and stronger prior-art coverage

Namespaces alone do not establish full isolation. Falling back to chroot or libc
interposition must satisfy an explicitly requested compatibility mode, rather than
silently reducing the isolation a workload expects.

The proposed shim is not validated by chroot success: kernel path resolution under
chroot also works for direct syscalls, while ordinary `LD_PRELOAD` interception
does not. Loader startup, static and dynamic direct-syscall paths, symlinks,
directory-relative calls, device access, and process supervision remain separate
engineering problems. Faking UID answers does not change kernel credentials.

[Fakechroot](https://github.com/dex4er/fakechroot) directly implements the relevant
libc-interposition approach, and [udocker](https://github.com/indigo-dc/udocker)
already combines image management with multiple engines including Fakechroot and
PRoot. Both are essential baselines. [Sharun](https://github.com/VHSgunzo/sharun)
is an ELF interpreter/library launcher, not evidence of complete filesystem
virtualization. V2 narrows the novelty claim and retains the design as untested.

## Validation performed and limits

| Check | Result |
|---|---|
| Complete manuscript read | All 730 lines, including the log index and entrypoint. |
| Primary-source review | Linux documentation, Go source, official tool documentation, libarchive, OCI, and relevant upstream projects consulted. |
| Size arithmetic | 225,641,729 bytes = 215.1887216568 MiB = 225.641729 MB. |
| Errno values | Local Linux headers and Python agree: `ENODEV=19`, `ENOTDIR=20`. |
| Capability mask | The displayed mask contains 41 set bits. |
| Original mtab write | A local fixture reproduces `ENOENT` through the dangling symlink. |
| Revised shell snippets | All four shell blocks pass `/bin/sh -n`. |
| Revised entrypoint fixture | Replaces the dangling link, preserves an existing regular fixture, forwards arguments correctly, and rejects a relative command; a stub replaces `chroot`, so this is not an integration test. |
| Docker availability | `docker` and `dockerd` are not exposed on the accessible executable paths; commands return “command not found.” No daemon could be started. |
| Target-runtime reproduction | Not performed: the accessible kernel reports `6.18.35`, not the paper's `6.18.39-gentoo-dist-bin`, and the experimental artifacts are absent. |

The Docker check does not show that Docker is absent from an inaccessible outer
host, and it does not establish a failure of Docker Engine. Docker's documented
manual startup requires an available `dockerd` binary. [Docker daemon startup](https://docs.docker.com/engine/daemon/start/)

The cited onelf page and exact lilipod source revision could not be retrieved in
this review. The listed experimental builds and measurements are therefore not
independently authenticated. Source review and local snippet checks must not be
represented as reproduction of the lilipod patch, Apptainer, runimage, or onelf
experiments.

## Evidence needed for a publishable empirical claim

1. Supply the raw logs, probe programs, actual patch, checksummed artifacts, image
   digests, package versions, and symlink-transformation manifest.
2. Separate policy effects from UID/GID mappings and filesystem constraints with
   individual probes and an appropriate control environment.
3. Test each claimed feature with a positive workload and recorded exit status,
   including nonempty logs, lifecycle survival, actual package transactions, and
   explicit mount/copy semantics.
4. Define and repeat timing experiments with cache state, payload state, resource
   consumption, and variability recorded.
5. Evaluate the relevant fakechroot/udocker alternatives before claiming a new
   general compatibility architecture.

The clean v2 is a more accurate, evidence-limited case study. The missing
experiments and artifacts remain necessary to substantiate stronger empirical
claims.
