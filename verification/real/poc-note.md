# Build-in-container PoCs on the target (2026-09-07)

Ten distro images, end-to-end, via the published lilipod v2 patch
(`patches/lilipod-restricted-v2.diff`). PoCs 1-4 use bespoke scripts
(`poc1-build.sh`, `poc2-build.sh`, `poc3-run.sh`, `poc4-build.sh`); PoCs 5-10 use
one distro-detecting harness (`poc5-build.sh`) that applies per-package-manager
fixups, installs a C toolchain, and builds+runs a two-file make project
(expected exit 42; musl distros additionally build `-static`).

| # | Image | Package manager | Fixups required | Result |
|---|---|---|---|---|
| 1 | alpine:latest | apk | none | `cc -static` -> static-pie musl binary, no PT_INTERP, runs on host, exit 42 |
| 2 | debian:bookworm-slim | apt/dpkg | https sources + host CA + `APT::Sandbox::User=root` | curl 8.22.0 built from source (OpenSSL/3.0.20, nghttp2), fetches https://example.com |
| 3 | almalinux:9 | dnf | epel-release in a separate transaction | fastfetch 2.66.0 runs (sysinfo/netlink//etc sources; shows the shared host kernel) |
| 4 | archlinux:base-devel | pacman | comment `DownloadUser = alpm` (unmapped-uid chown) | cmake 4.4.3 builds fmtlib/fmt @ HEAD; program links against libfmt.a, exit 7 |
| 5 | voidlinux/voidlinux-musl | xbps | pin mirror to repo-default.voidlinux.org + host CA; **OCI whiteout handling** (see below) | dynamic + `-static` musl builds, exit 42 |
| 6 | ubuntu:latest (26.04) | apt/dpkg | https sources + host CA + `Sandbox::User=root` | build-essential -> make project, exit 42 |
| 7 | opensuse/leap:16.0 | zypper | http->https in the **RIS index** (`/usr/share/zypp/local/service/`), services, repos.d — zypper regenerates repos.d from the index on refresh, overwriting naive seds | gcc 15.2.0 -> make project, exit 42 |
| 8 | rockylinux:9 | dnf | **host resolv.conf** (image ships a baked `nameserver 192.168.122.1`, the libvirt NAT gateway) | gcc 11.5.0 -> make project, exit 42 |
| 9 | rockylinux:9-minimal | microdnf | host resolv.conf (as above) | gcc 11.5.0 -> make project, exit 42 |
| 10 | fedora:latest (44) | dnf5 | host resolv.conf (as above) | gcc 16.2.1 -> make project, exit 42 |

## New runtime findings from the extension

- **OCI whiteouts are load-bearing** (void): the image's layer 1 ships a
  self-referential `/var/cache/xbps -> /var/cache/xbps` symlink; layer 2 deletes
  it with a `.wh.xbps` marker. Plain `tar -x` ignores whiteouts, leaving the
  loop in place — `xbps` then dies with `failed to change dir to cachedir:
  Symbolic link loop`. lilipod v2.2 gained `ApplyOCIWhiteouts` (paper §10.4's
  requirement, now with a live failure case). `.wh..wh..opq` is noted-and-
  dropped: sequential extraction has no lower layer to hide.
- **Zypper's RIS index regenerates repos.d** (leap): seds on `/etc/zypp/repos.d`
  are overwritten by `refresh-services` from
  `/usr/share/zypp/local/service/openSUSE/repo/*.xml`; the fixup must target the
  index first, then services, then repos.d.
- **Images bake unreachable resolvers** (rocky family, likely others): a
  `nameserver 192.168.122.1` line is a build-host artifact. Docker never uses
  the image's resolv.conf; lilipod v2.3 adopts the same semantics (always
  install the host's), which also covers the empty-placeholder case (AlmaLinux).
- **tcp/80 egress remains the invariant** behind every repo-protocol fixup
  (debian/ubuntu sources, leap RIS, void mirror); https + a real CA bundle
  resolves all of them. Void's `alpha.de` mirror also serves a mismatched
  certificate subject from this network — pinning to `repo-default` fixes it.
- **dpkg/rpm/xbps chown failures remain warnings**; none of the ten distros
  hit a fatal ownership wall at install time once extraction was
  ownership-neutral.
