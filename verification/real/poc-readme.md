# Bare-bones PoCs: real builds inside a namespace-less, mount-less runtime

Runtime: uid 0 in a user namespace (`uid_map 0→1000`), `setgroups` denied,
`chown` to unmapped ids `EINVAL`, `unshare`/`mount`/`pivot_root`/`ptrace`/`mknod`
denied — no device nodes, no `/proc` inside containers, plain `chroot` only.

Vehicle: lilipod (89luca89) with the restricted-runtime chroot patch
(`patches/lilipod-restricted-v2.diff` in the container-research corpus), built as
`lilipod-v2` (Go, static, CGO_ENABLED=0).

## PoC 1 — Alpine → musl static binary

```sh
./poc1-alpine-musl.sh
```

Pulls `alpine:latest`, `apk add build-base file`, compiles `hello.c` with
`cc -static`, verifies inside, extracts the artifact.

Result (captured 2026-09-07):

```
curl 8.22.0 ... (PoC 2, below)
$ file /workspace/poc/hello-musl-static
ELF 64-bit LSB pie executable ... static-pie linked
$ /workspace/poc/hello-musl-static ; echo $?
hello from a static musl binary built inside a namespace-less chroot
42
```

The binary runs on the host directly — fully static (no PT_INTERP), so it is
portable to any x86-64 Linux.

## PoC 2 — Debian → build curl from source

```sh
./poc2-debian-curl.sh
```

Pulls `debian:bookworm-slim` (layer extraction survives the chown wall via
ownership-neutral untar), installs `build-essential libssl-dev zlib1g-dev
libnghttp2-dev libpsl-dev pkg-config wget ca-certificates` through apt, fetches
`curl-8.22.0.tar.xz`, configures with OpenSSL + nghttp2, `make -j$(nproc)`, then
uses the freshly built curl to fetch a page over HTTPS.

Result (captured 2026-09-07):

```
=== build result:
curl 8.22.0 (x86_64-pc-linux-gnu) libcurl/8.22.0 OpenSSL/3.0.20 zlib/1.2.13
libpsl/0.21.2 nghttp2/1.52.0
Protocols: dict file ftp ftps gopher gophers http https imap imaps ... ws wss
=== real usage: fetch a page with the built curl
<title>Example Domain</title>
BUILD-OK
```

Artifact: `curl-built` — ELF pie, dynamically linked against the container's
Debian libs (static not required).

## Runtime-specific workarounds these PoCs encode

1. **apt over HTTPS with the host CA**: plain-HTTP egress (port 80) from this
   sandbox returns garbage ("does not have a Release file" / "Method http has
   died"), so sources are switched to `https://deb.debian.org` and apt is pointed
   at the host CA bundle copied in through the volume (`-v src:/src` volumes are
   snapshot copies in restricted mode).
2. **`-o APT::Sandbox::User=root`**: apt's default `_apt` privilege drop fails
   (`setuid`/`setgroups` to unmapped ids → EINVAL/EPERM) noisily; root skips it.
3. **`/dev/null` shim**: lilipod v2.1 creates a regular-file `/dev/null` in the
   rootfs (mknod is denied; writes succeed, reads return EOF) — apt/dpkg/bash
   redirections need it.
4. **No `CLONE_NEWNET` on entry**: on this runtime namespace clones *succeed*
   while unshare fails; an empty network namespace silently kills all networking
   (`ENETUNREACH`). The v2.1 patch keeps only `CLONE_NEWUTS` (probed), so
   containers share the host network and DNS works.
5. **dpkg chown failures are warnings here**: package files with unmapped owners
   log `W: chown ... failed ... (22: Invalid argument)` but installs proceed.

## Files

- `poc1-alpine-musl.sh` — standalone PoC 1 driver
- `poc2-debian-curl.sh` — standalone PoC 2 driver
- `src1/build.sh`, `src2/build.sh` — the in-container build scripts (copied in
  via `-v`)
- `hello-musl-static`, `curl-built` — the artifacts
- `evidence/` — mechanical captures of both runs
