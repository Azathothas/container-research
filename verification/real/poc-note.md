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

## Extended set (2026-09-07, later the same day)

3. **AlmaLinux 9 -> fastfetch** (`poc3-almalinux.txt`, `poc3-run.sh`): dnf +
   EPEL (two transactions — epel-release first), fastfetch 2.66.0 runs and
   reports OS/kernel/uptime/packages/interface via `sysinfo(2)`, netlink and
   `/etc` — no `/proc` needed. It truthfully shows the *host* kernel and IP.

4. **Arch Linux -> CMake project** (`poc4-arch.txt`, `poc4-build.sh`): pacman's
   shipped `DownloadUser = alpm` hits the unmapped-gid chown wall exactly as the
   model's §8.3 predicted (reproduced on the real image); after commenting it
   out, `pacman -S cmake git`, then `fmtlib/fmt` at HEAD: cmake 4.4.3 configure
   + build + a program linked against `libfmt.a` that runs and returns the
   expected exit code.

Additional target facts settled while extending:

- `umount2` is denied (EPERM) like mount — the filter list in paper §3.2 is now
  target-verified item by item (`probe-census.txt`).
- podman 5.8.2 on the target dies at init with a bare `no such file or
  directory` even with `--storage-driver vfs --root/--runroot`
  (`podman-vfs-target.txt`): the corpus §6 "vfs initializes" result is
  model-only (podman 4.3.1 there); the paper's layer-apply cascade is unchanged.
- Images that ship an empty `/etc/resolv.conf` placeholder (AlmaLinux) get no
  DNS until the host resolver is installed; lilipod v2.1 now copies the host
  resolv.conf unless a `nameserver` line already exists.
