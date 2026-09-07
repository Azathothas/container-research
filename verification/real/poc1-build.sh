#!/bin/sh
# PoC 1: Alpine, install build tools, build a static musl binary.
set -e
echo "=== apk: installing build tools"
apk add --no-cache build-base file 2>&1 | tail -2
echo "=== toolchain:"
cc --version | head -1
mkdir -p /out
cat > /hello.c <<'CEOF'
#include <stdio.h>
int main(void) {
    printf("hello from a static musl binary built inside a namespace-less chroot\n");
    return 42;
}
CEOF
echo "=== building: cc -static"
cc -static -o /out/hello /hello.c
echo "=== verify inside:"
file /out/hello
rc=0; /out/hello || rc=$?
echo "run-exit=$rc (expect 42)"
echo "BUILD-OK"
