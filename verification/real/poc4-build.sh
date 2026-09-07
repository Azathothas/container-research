#!/bin/sh
# PoC 4: Arch Linux -> CMake project (fmtlib/fmt from upstream HEAD).
set -e
echo "=== os:"
head -2 /etc/os-release
echo "=== pacman: the shipped DownloadUser=alpm chowns to an unmapped uid -> EINVAL"
grep -n "^DownloadUser" /etc/pacman.conf
sed -i "s/^DownloadUser/#DownloadUser/" /etc/pacman.conf
pacman -Sy --noconfirm 2>&1 | tail -1
pacman -S --noconfirm --needed cmake git 2>&1 | tail -1
echo "=== toolchain:"
cmake --version | head -1
gcc --version | head -1
echo "=== fetching fmt (cmake project under test)"
cd /tmp && rm -rf fmt && git clone -q --depth 1 https://github.com/fmtlib/fmt.git
cd fmt && git log -1 --format="fmt @ %h (%cd)" --date=short
echo "=== cmake configure + build"
cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release -DFMT_TEST=OFF -DFMT_DOC=OFF > /tmp/cm.log 2>&1
echo "configure: $(grep -c 'Configuring done' /tmp/cm.log)"
cmake --build build -j"$(nproc)" > /tmp/build.log 2>&1
echo "artifact: $(ls -la build/libfmt.a)"
echo "=== compile & run a program against the built library"
cat > /tmp/use_fmt.cpp <<'CEOF'
#include <fmt/core.h>
int main() { fmt::print("fmt {} works inside a namespace-less chroot\n", FMT_VERSION); return 7; }
CEOF
g++ -Iinclude -Isrc /tmp/use_fmt.cpp build/libfmt.a -o /tmp/use_fmt
rc=0; /tmp/use_fmt || rc=$?
echo "exit=$rc (expect 7)"
mkdir -p /out && cp build/libfmt.a /tmp/use_fmt /out/
echo "BUILD-OK"
