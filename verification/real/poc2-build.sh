#!/bin/sh
# PoC 2: Debian, install build tools, build curl from source (dynamic ok).
set -e
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -o APT::Sandbox::User=root -o Acquire::https::CaInfo=/src/ca-certificates.crt"

echo "=== sources: plain http egress is broken here; use https"
sed -i 's|http://deb.debian.org|https://deb.debian.org|g' /etc/apt/sources.list.d/*.sources /etc/apt/sources.list 2>/dev/null || true
echo "=== apt: update"
$APT update -qq 2>&1 | grep -vE '^E: (setgroups|setegid|seteuid)' | tail -2
echo "=== apt: installing build tools"
$APT install -y -qq --no-install-recommends build-essential libssl-dev zlib1g-dev libnghttp2-dev libpsl-dev pkg-config wget ca-certificates 2>&1 | tail -2
echo "=== toolchain:"
gcc --version | head -1
make --version | head -1
echo "=== fetching curl source"
cd /usr/local/src
wget -q https://curl.se/download/curl-8.22.0.tar.xz
tar xf curl-8.22.0.tar.xz
cd curl-8.22.0
echo "=== configure"
./configure --with-openssl --with-nghttp2 --prefix=/usr/local/curl > /tmp/conf.log 2>&1 || { tail -20 /tmp/conf.log; exit 1; }
echo "configure: $(grep -E '^  (SSL|Protocols)' /tmp/conf.log | tr '\n' ' ')"
echo "=== make -j$(nproc)"
make -s -j"$(nproc)" > /tmp/make.log 2>&1 || { tail -20 /tmp/make.log; exit 1; }
echo "=== build result:"
./src/curl --version
echo "=== real usage: fetch a page with the built curl"
./src/curl -fsS https://example.com | grep -o '<title>.*</title>' | head -1
mkdir -p /out
cp ./src/.libs/curl /out/curl
echo "BUILD-OK"
