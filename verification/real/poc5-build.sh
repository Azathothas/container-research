#!/bin/sh
# Generic PoC: distro-detect, apply package-manager fixups, install a C
# toolchain, then build+run a two-file make project (exit 42 expected).
# musl distros additionally build a -static binary.
set -e
. /etc/os-release
echo "=== distro: $PRETTY_NAME (ID=$ID)"
fixups="none"

case "$ID" in
voidlinux|void)
  fixups="mirror pinned to repo-default.voidlinux.org, host CA bundle"
  sed -i 's|alpha.de.repo.voidlinux.org|repo-default.voidlinux.org|g' /usr/share/xbps.d/*.conf /etc/xbps.d/*.conf 2>/dev/null || true
  cp /src/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
  xbps-install -Su xbps -y >/dev/null 2>&1 || true
  xbps-install -S -y base-devel >/dev/null
  ;;
ubuntu)
  fixups="http->https sources, host CA, APT::Sandbox::User=root"
  sed -i 's|http://archive.ubuntu.com|https://archive.ubuntu.com|g; s|http://security.ubuntu.com|https://security.ubuntu.com|g' \
    /etc/apt/sources.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
  export DEBIAN_FRONTEND=noninteractive
  APT="apt-get -o APT::Sandbox::User=root -o Acquire::https::CaInfo=/src/ca-certificates.crt"
  $APT update -qq 2>&1 | grep -vE '^E: (setgroups|setegid|seteuid)' | tail -1
  $APT install -y -qq --no-install-recommends build-essential 2>&1 | tail -1
  ;;
opensuse-leap)
  fixups="http->https in RIS index+services+repos (zypper regenerates repos.d from /usr/share/zypp/local/service), gpg auto-import"
  sed -i 's|http://cdn.opensuse.org|https://cdn.opensuse.org|g' /usr/share/zypp/local/service/openSUSE/repo/*.xml /etc/zypp/services.d/*.service /etc/zypp/repos.d/*.repo 2>/dev/null || true
  zypper --non-interactive refresh-services >/dev/null 2>&1 || true
  sed -i 's|http://cdn.opensuse.org|https://cdn.opensuse.org|g' /etc/zypp/repos.d/*.repo 2>/dev/null || true
  zypper --non-interactive --gpg-auto-import-keys refresh >/dev/null 2>&1
  zypper --non-interactive install -y gcc gcc-c++ make glibc-devel 2>&1 | tail -1
  ;;
rockylinux|rocky|almalinux|alma|fedora)
  if command -v microdnf >/dev/null 2>&1; then
    fixups="none (microdnf)"
    microdnf install -y gcc gcc-c++ make 2>&1 | tail -1
  else
    fixups="none (dnf; v2.3 installs host resolv.conf - image ships 192.168.122.1)"
    dnf install -y -q gcc gcc-c++ make glibc-devel 2>&1 | tail -1
  fi
  ;;
*)
  echo "unknown distro ID=$ID"; exit 1 ;;
esac
echo "=== fixups: $fixups"
echo "=== toolchain: $(gcc --version | head -1)"

mkdir -p /build && cd /build
cat > mathx.c <<'CEOF'
int square(int x) { return x * x; }
CEOF
cat > app.c <<'CEOF'
#include <stdio.h>
int square(int);
int main(void) {
#ifdef APP_TAG
    printf("%s: square(6)=%d\n", APP_TAG, square(6));
#else
    printf("square(6)=%d\n", square(6));
#endif
    return 42;
}
CEOF
cat > Makefile <<'CEOF'
app: app.c mathx.c
	$(CC) $(CFLAGS) -DAPP_TAG="\"$(TAG)\"" -o $@ app.c mathx.c
clean:
	rm -f app
CEOF
make TAG="$PRETTY_NAME" >/dev/null
rc=0; ./app || rc=$?
echo "exit=$rc (expect 42)"

case "$ID" in
voidlinux|void)
  make clean >/dev/null; make TAG="$PRETTY_NAME static" CFLAGS=-static >/dev/null
  rc=0; ./app || rc=$?
  echo "static exit=$rc (expect 42)"
  ;;
esac
echo "DISTRO-OK"
