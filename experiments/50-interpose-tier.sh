#!/usr/bin/env bash
# Question: does an off-the-shelf LD_PRELOAD path interposer give podbox's
# `interpose` tier what it needs on this runtime class — and which of the four
# walls does it NOT clear?
#
# Subject: VHSgunzo/pathmap, which ships both halves of the tier in one repo —
# an LD_PRELOAD library (path-mapping.so) and a ptrace tracer (pathmap) — so a
# single build measures both the surviving route and the dead one.
#
# Four measurements, each against a wall paper_final.md already names:
#   1. path mapping without mount(2)      — the volume problem (§10.7)
#   2. chown to an unmapped gid           — the ownership wall (§9.1)
#   3. the ptrace tracer                  — F denies ptrace and process_vm_* (§3.7a)
#   4. memfd_create + fexecve             — the memfd launch rung (§8.4)
#
# Every input is pinned to a commit. Exit: 0 ran, 1 a measurement failed to
# produce a verdict, 2 could not run.
set -uo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUT="${OUT:-$HERE/.interpose}"
STAGE="${TARGET_STAGE:-$HERE/.stage}"
mkdir -p "$OUT"

PATHMAP_REPO=https://github.com/VHSgunzo/pathmap
PATHMAP_COMMIT=98b3d2aef724249f71bb96d4235872407f21bf54

command -v gcc >/dev/null 2>&1 || { echo "SKIP: gcc required" >&2; exit 2; }

echo "== conditions"
printf 'date              %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'host kernel       %s\n' "$(uname -r)"
printf 'pathmap           %s @ %s\n' "$PATHMAP_REPO" "$PATHMAP_COMMIT"
echo

if [ ! -d "$OUT/pathmap/.git" ]; then
	git clone -q "$PATHMAP_REPO" "$OUT/pathmap" 2>/dev/null || {
		echo "SKIP: cannot fetch pathmap" >&2; exit 2; }
fi
( cd "$OUT/pathmap" && git checkout -q "$PATHMAP_COMMIT" ) || {
	echo "SKIP: pathmap commit $PATHMAP_COMMIT unavailable" >&2; exit 2; }
( cd "$OUT/pathmap" && make path-mapping.so >/dev/null 2>&1 && make pathmap >/dev/null 2>&1 )
[ -f "$OUT/pathmap/path-mapping.so" ] || { echo "SKIP: pathmap did not build" >&2; exit 2; }

printf 'interposed symbols %s\n' \
	"$(nm -D --defined-only "$OUT/pathmap/path-mapping.so" | awk '$2=="T"' | wc -l)"
printf 'ownership calls    %s\n' \
	"$(nm -D --defined-only "$OUT/pathmap/path-mapping.so" | grep -cE ' T (l?chown|fchownat)$')"
echo

# Stage into what becomes /workspace inside the reconstruction.
mkdir -p "$STAGE/.harness" "$STAGE/interpose"
cp "$OUT/pathmap/path-mapping.so" "$STAGE/interpose/"
[ -f "$OUT/pathmap/pathmap" ] && cp "$OUT/pathmap/pathmap" "$STAGE/interpose/"

cat > "$STAGE/interpose/walls.sh" <<'WALLS'
#!/bin/sh
# Runs *inside* the reconstruction. Each block prints one verdict line.
SO=/workspace/interpose/path-mapping.so
TR=/workspace/interpose/pathmap
mkdir -p /tmp/iv/real /tmp/iv/probe && echo REAL-CONTENT > /tmp/iv/real/marker

echo "--- 1. path mapping without mount(2)"
if out=$(PATH_MAPPING="/mapped:/tmp/iv/real" LD_PRELOAD="$SO" \
         /bin/cat /mapped/marker 2>&1); then
	case "$out" in
	REAL-CONTENT*) echo "    MAPPED    a path that does not exist resolved to the real one" ;;
	*)             echo "    UNMAPPED  $out" ;;
	esac
else
	echo "    UNMAPPED  $out"
fi

echo "--- 2. chown to an unmapped gid, under the interposer"
: > /tmp/iv/probe/f
bare=$(chown 0:42 /tmp/iv/probe/f 2>&1); bare_rc=$?
shim=$(LD_PRELOAD="$SO" chown 0:42 /tmp/iv/probe/f 2>&1); shim_rc=$?
echo "    bare rc=$bare_rc  ${bare:-(silent)}"
echo "    shim rc=$shim_rc  ${shim:-(silent)}"
if [ "$shim_rc" = 0 ] && [ "$bare_rc" != 0 ]; then
	echo "    CLEARED   the interposer answered the ownership wall"
else
	echo "    NOT CLEARED  path mapping is not ownership faking; the wall stands"
fi

echo "--- 3. the ptrace tracer half"
if [ -x "$TR" ]; then
	out=$(PATH_MAPPING="/mapped:/tmp/iv/real" "$TR" -- /bin/cat /mapped/marker 2>&1)
	case "$out" in
	REAL-CONTENT*) echo "    WORKS     $out" ;;
	*)             echo "    DEAD      $(echo "$out" | head -2 | tr '\n' ' ')" ;;
	esac
else
	echo "    NOT BUILT (tracer absent)"
fi

echo "--- 4. memfd_create + fexecve (the memfd launch rung)"
/workspace/.harness/probe check 'memfd_create+exec' 2>&1 | sed 's/^/    /'
WALLS
chmod 0755 "$STAGE/interpose/walls.sh"

echo "== inside the reconstruction"
"$HERE/20-enter-target.sh" -- /bin/sh /workspace/interpose/walls.sh
rc=$?

echo
echo "== reading"
echo "  The surviving half of this tier is the preload, not the tracer: the"
echo "  runtime's filter denies ptrace(2) and process_vm_readv(2), which is"
echo "  both of the tracer's channels (paper §3.7a)."
echo "  Path mapping and ownership faking are different jobs. An interposer"
echo "  that maps paths still passes the real uid/gid to the kernel, so §9.1"
echo "  stands until the same library also answers chown — which is the"
echo "  fakeroot half of TOOL.md's interposer spec, not the fakechroot half."
exit "$rc"
