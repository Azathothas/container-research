# Build-in-container PoCs on the target (2026-09-07)

Two end-to-end proofs that image-derived userspaces on this runtime can compile real
software, using the published lilipod v2.1 patch:

1. **Alpine -> static musl binary** (`poc1-alpine.txt`, `poc1-build.sh`):
   `apk add build-base` inside the chroot, `cc -static` hello world; the artifact
   is a fully static PIE (no PT_INTERP), runs on the host, returns the expected
   exit code 42.

2. **Debian bookworm-slim -> curl from source** (`poc2-debian.txt`, `poc2-build.sh`):
   `apt-get install build-essential libssl-dev ...` (dpkg logs chown warnings for
   unmapped owners but proceeds), fetch curl-8.22.0, configure with OpenSSL +
   nghttp2, `make -j`, and the freshly built curl fetches `https://example.com`.

Runtime-specific workarounds encoded in the scripts:

- plain-HTTP egress (tcp/80) from the sandbox returns garbage: Debian sources are
  switched to https, with the host CA bundle copied in via the volume;
- `APT::Sandbox::User=root` (the `_apt` drop fails on unmapped ids);
- lilipod v2.1 provides a regular-file `/dev/null` shim (mknod denied);
- v2.1 also drops `CLONE_NEWNET` & friends in restricted mode: on this runtime
  those clones *succeed* and yield an empty network namespace, which silently
  broke all container networking (`ENETUNREACH`) — a concrete instance of the
  clone-vs-unshare asymmetry (paper §3.4) biting real tooling.
