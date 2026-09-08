#!/usr/bin/env bash
# Question: which implementation language can supply the four things podbox
# needs from one — and which cannot, measured rather than assumed?
#
#   A. a statically linked binary with no PT_INTERP (paper §8.4: the memfd
#      launch rung requires a dependency-free entrypoint)
#   B. a single-threaded process at main(), because the kernel refuses
#      unshare(CLONE_NEWUSER) to a multithreaded caller and PR_SET_PDEATHSIG
#      fires on the creating *thread* (paper §3.5 F11, §10.6)
#   C. an LD_PRELOAD interposer, which is the whole `interpose` tier
#      (paper §10.3, §5.5)
#   D. a small artefact, because it is packed into a single file
#
# Candidates: Rust (musl target), Go (CGO_ENABLED=0), C (the control — it can
# obviously do all four, and is here to prove the probes work).
#
# Nothing here is a benchmark: no timings are taken, and sizes are one build
# of one trivial program, quoted only as an order of magnitude.
#
# Exit: 0 the comparison ran, 1 a candidate failed a property it claims,
#       2 could not run (toolchain missing).
set -uo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SRC="$HERE/src/lang"
OUT="${OUT:-$HERE/.langbuild}"
mkdir -p "$OUT"

have() { command -v "$1" >/dev/null 2>&1; }
[ -d /root/.cargo/bin ] && PATH="/root/.cargo/bin:$PATH"

echo "== conditions"
printf 'date              %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'host kernel       %s\n' "$(uname -r)"
printf 'rustc             %s\n' "$(rustc --version 2>/dev/null || echo MISSING)"
printf 'go                %s\n' "$(go version 2>/dev/null | cut -d' ' -f3 || echo MISSING)"
printf 'gcc               %s\n' "$(gcc -dumpversion 2>/dev/null || echo MISSING)"
echo

have gcc || { echo "SKIP: gcc is the control; without it nothing here is interpretable" >&2; exit 2; }

# ------------------------------------------------------------------ A, B, D
echo "== A/B/D: static linkage, thread count at main, artefact size"
printf '%-8s %-10s %-24s %-10s %s\n' lang built PT_INTERP size probe

report() { # report <lang> <binary>
	local lang="$1" bin="$2"
	if [ ! -x "$bin" ]; then
		printf '%-8s %-10s %-24s %-10s %s\n' "$lang" no - - "(build failed)"
		return 1
	fi
	local interp size
	interp=$(readelf -l "$bin" 2>/dev/null | grep -c 'INTERP' || true)
	[ "$interp" = 0 ] && interp="absent (static)" || interp="present (needs loader)"
	size=$(du -h "$bin" | cut -f1)
	printf '%-8s %-10s %-24s %-10s %s\n' "$lang" yes "$interp" "$size" "$("$bin" | tr '\n' ' ')"
}

rc=0
if have rustc; then
	if rustc --edition 2024 -O -C strip=symbols --target x86_64-unknown-linux-musl \
		-C target-feature=+crt-static -o "$OUT/probe-rust" \
		"$SRC/rust-static/main.rs" 2>"$OUT/rust.log"; then :; else
		# older rustc: edition 2024 or the musl std may be absent
		rustc -O -o "$OUT/probe-rust" "$SRC/rust-static/main.rs" 2>>"$OUT/rust.log" || true
	fi
	report rust "$OUT/probe-rust" || rc=1
else
	printf '%-8s %-10s %s\n' rust no "(rustc missing; rustup target add x86_64-unknown-linux-musl)"
fi

if have go; then
	( cd "$SRC/go-static" && [ -f go.mod ] || printf 'module langprobe\n\ngo 1.21\n' > go.mod
	  CGO_ENABLED=0 go build -ldflags='-s -w' -o "$OUT/probe-go" . ) 2>"$OUT/go.log"
	report go "$OUT/probe-go" || rc=1
else
	printf '%-8s %-10s %s\n' go no "(go missing)"
fi

cat > "$OUT/probe-c.c" <<'EOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <sched.h>
#include <errno.h>
int main(void){
    FILE*f=fopen("/proc/self/status","r"); char l[256]; int t=0;
    while(f&&fgets(l,sizeof l,f)) if(sscanf(l,"Threads: %d",&t)==1) break;
    if(f) fclose(f);
    printf("lang c threads_at_main %d ",t);
    printf("unshare(NEWUSER) %s\n", unshare(CLONE_NEWUSER)==0?"OK":"FAIL");
    return 0;
}
EOF
gcc -O2 -static -o "$OUT/probe-c" "$OUT/probe-c.c" 2>"$OUT/c.log" && report c "$OUT/probe-c"

# ------------------------------------------------------------------ C
echo
echo "== C: does an LD_PRELOAD interposer built in this language reach a"
echo "      dynamically linked C payload's lchown?"

# The payload forks. Every workload podbox interposes on does — tar, dpkg,
# rpm, apk, make, configure — so an interposer that only survives a
# straight-line program has not been tested at all. It also reports the host
# process's thread count, because a preloaded object that starts threads in
# its host changes that host's fork semantics.
cat > "$OUT/victim.c" <<'EOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
static int threads(void){
    FILE*f=fopen("/proc/self/status","r"); char l[256]; int t=0;
    while(f&&fgets(l,sizeof l,f)) if(sscanf(l,"Threads: %d",&t)==1) break;
    if(f) fclose(f); return t;
}
int main(void){
    printf("victim: threads=%d lchown rc=%d\n", threads(), lchown("/tmp/lang-shim-target",0,42));
    fflush(stdout);
    pid_t p = fork();
    if (p == 0) { int rc = lchown("/tmp/lang-shim-target",0,42);
                  printf("victim-child: lchown rc=%d\n", rc); fflush(stdout); _exit(0); }
    if (p < 0) { printf("victim: fork failed\n"); return 1; }
    int st = 0;
    if (waitpid(p, &st, 0) < 0) { printf("victim: waitpid failed\n"); return 1; }
    printf("victim: child exit=%d\n", WEXITSTATUS(st));
    return 0;
}
EOF
gcc -O2 -o "$OUT/victim" "$OUT/victim.c" || { echo "SKIP: cannot build the payload" >&2; exit 2; }
: > /tmp/lang-shim-target

shim_check() { # shim_check <lang> <so-path>
	local lang="$1" so="$2"
	if [ ! -f "$so" ]; then
		printf '  %-6s %-9s %-9s %-9s %s\n' "$lang" - - - "could not build a preloadable object"
		return 1
	fi
	local out size hooked forked threads
	size=$(du -h "$so" | cut -f1)
	out=$(timeout 20 env LD_PRELOAD="$so" "$OUT/victim" 2>&1)
	local rc=$?
	threads=$(printf '%s' "$out" | sed -n 's/.*threads=\([0-9]*\).*/\1/p' | head -1)
	printf '%s' "$out" | grep -q 'intercepted lchown' && hooked=yes || hooked=no
	if [ "$rc" = 124 ]; then
		forked="HUNG"
	elif printf '%s' "$out" | grep -q 'victim: child exit=0'; then
		forked=yes
	else
		forked=no
	fi
	printf '  %-6s %-9s %-9s %-9s %s\n' "$lang" "$hooked" "$forked" "${threads:-?}" "$size"
	[ "$hooked" = yes ] && [ "$forked" = yes ]
}

printf '  %-6s %-9s %-9s %-9s %s\n' lang intercepts 'survives' 'host' 'object'
printf '  %-6s %-9s %-9s %-9s %s\n' '' 'lchown' 'fork' 'threads' 'size' 

cat > "$OUT/c-shim.c" <<'EOF'
#define _GNU_SOURCE
#include <unistd.h>
int lchown(const char *p, uid_t u, gid_t g){
    (void)p;(void)u;(void)g;
    write(2,"c-shim: intercepted lchown\n",27); return 0;
}
EOF
gcc -O2 -shared -fPIC -o "$OUT/c-shim.so" "$OUT/c-shim.c" 2>/dev/null
shim_check c "$OUT/c-shim.so" || rc=1

if have rustc; then
	rustc --edition 2024 -O -C strip=symbols --crate-type=cdylib -o "$OUT/rust-shim.so" \
		"$SRC/rust-shim/lib.rs" 2>"$OUT/rust-shim.log" \
	|| rustc --edition 2021 -O -C strip=symbols --crate-type=cdylib -o "$OUT/rust-shim.so" \
		"$SRC/rust-shim/lib.rs" 2>>"$OUT/rust-shim.log" || true
	shim_check rust "$OUT/rust-shim.so" || rc=1
fi

# Go's answer is structural, not a build flag: -buildmode=c-shared produces a
# .so, but it embeds the Go runtime, whose initialiser runs in the host
# process at load time and starts threads there. Build it and let the result
# speak.
if have go; then
	mkdir -p "$OUT/go-shim"
	cat > "$OUT/go-shim/main.go" <<'EOF'
package main

import "C"
import "os"

//export lchown
func lchown(path *C.char, uid C.uint, gid C.uint) C.int {
	os.Stderr.WriteString("go-shim: intercepted lchown\n")
	return 0
}

func main() {}
EOF
	printf 'module goshim\n\ngo 1.21\n' > "$OUT/go-shim/go.mod"
	( cd "$OUT/go-shim" && CGO_ENABLED=1 go build -buildmode=c-shared -o "$OUT/go-shim.so" . ) \
		2>"$OUT/go-shim.log" || true
	if [ -f "$OUT/go-shim.so" ]; then
		shim_check go "$OUT/go-shim.so" || true
	else
		printf '  %-6s %-9s %-9s %-9s %s\n' go - - - \
			"c-shared build failed: $(tail -1 "$OUT/go-shim.log" 2>/dev/null)"
	fi
fi

echo
echo "== reading"
echo "  Static, PT_INTERP-free artefact: all three."
echo "  Single-threaded at main(): rust and c. Go starts its scheduler first,"
echo "    which is why a Go process cannot unshare(CLONE_NEWUSER) even"
echo "    unconfined (paper §3.5 F11) and why PR_SET_PDEATHSIG is unreliable"
echo "    in a Go supervisor (§10.6)."
echo "  LD_PRELOAD interposer: read the table above rather than this line —"
echo "    a Go c-shared object *does* hook the symbol, and the cost shows up"
echo "    in the host-threads and object-size columns, not in a yes/no."
echo "  Independent of all of it, paper §9.3: no preload of any language sees"
echo "    a Go *payload*'s lchown, cgo or not. The interpose tier's ceiling is"
echo "    a property of the payload, never of the interposer."
echo "  TOOL.md §3 carries the decision these rows support."
exit "$rc"
