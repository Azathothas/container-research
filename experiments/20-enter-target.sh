#!/usr/bin/env bash
# Question: can a container supply the target runtime's kernel-visible shape —
# its mount topology, its partial ID map, its seccomp filter and its write
# policy — and which parts does this host refuse?
#
#   ./20-enter-target.sh                     interactive shell inside the reconstruction
#   ./20-enter-target.sh -- id               run one command inside it
#   ./20-enter-target.sh --stage ./podbox \
#       -- /workspace/podbox probe           stage your own binary and run it
#   ./20-enter-target.sh --raw -- sh         the container without the confinement,
#                                            for setting fixtures up
#
# --stage copies a file or directory into what becomes /workspace, which is one
# of the four writable paths inside. Repeatable. This is how you run something
# that is not part of this repository against the reconstructed runtime — which
# is the point of the script for anyone implementing against it.
#
# Exit: 0 the payload ran, its own code otherwise, 2 could not run.
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO="$(CDPATH= cd -- "$HERE/.." && pwd)"
IMAGE="${TARGET_IMAGE:-container-research/target:1}"
STAGE="${TARGET_STAGE:-$REPO/experiments/.stage}"

RAW=0
STAGE_IN=()
ARGS=()
while [ "$#" -gt 0 ]; do
	case "$1" in
	--raw) RAW=1; shift ;;
	--stage) STAGE_IN+=("${2:?--stage needs a path}"); shift 2 ;;
	--) shift; ARGS=("$@"); break ;;
	*) ARGS+=("$1"); shift ;;
	esac
done
[ "${#ARGS[@]}" -eq 0 ] && ARGS=(/bin/sh)

command -v docker >/dev/null 2>&1 || { echo "SKIP: docker not on PATH" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "SKIP: docker daemon not reachable" >&2; exit 2; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
	echo "SKIP: $IMAGE not built. Run ./experiments/10-build-target-image.sh" >&2
	exit 2
}

# ------------------------------------------------------------------ staging
# The harness is built on the host and staged into what becomes /workspace,
# because inside the reconstruction /workspace is one of only four writable
# paths and the toolchain there must not be needed to bootstrap the tools that
# measure it.
command -v go >/dev/null 2>&1 || { echo "SKIP: go is required to build the harness" >&2; exit 2; }
mkdir -p "$STAGE/.harness"
( cd "$REPO/verification/confine" && CGO_ENABLED=0 go build -o "$STAGE/.harness/confine" . )
( cd "$REPO/verification/probe"   && CGO_ENABLED=0 go build -o "$STAGE/.harness/probe" . )
if command -v gcc >/dev/null 2>&1; then
	gcc -O2 -static -o "$STAGE/.harness/cprobe" "$REPO/verification/cprobe/cprobe.c"
fi

# enter.sh runs as the last step of targetfs.sh, inside the pivoted root. It
# composes the three mechanisms and says which ones it actually got.
cat > "$STAGE/.harness/enter.sh" <<'ENTER'
#!/bin/sh
# Applies N, F and (where the kernel has Landlock) M, then execs the payload.
set -eu
H=/workspace/.harness

CONFINE_USERNS=1
CONFINE_MOUNTNS=1
CONFINE_MAP_HOSTID="${TARGET_HOST_UID:-1000}"
CONFINE_EXTRA_GROUP=42
CONFINE_SECCOMP=1
CONFINE_DENY_PROCESS_VM=1
export CONFINE_USERNS CONFINE_MOUNTNS CONFINE_MAP_HOSTID CONFINE_EXTRA_GROUP \
       CONFINE_SECCOMP CONFINE_DENY_PROCESS_VM

# M is optional because the kernel may not carry Landlock at all. Ask before
# applying, and say what happened either way: a mechanism that is silently
# absent is worse than one that is loudly missing.
if "$H/probe" check 'landlock_create_ruleset(VERSION)' 2>/dev/null | grep -q ' OK'; then
	CONFINE_LANDLOCK=/tmp:/dev/shm:/workspace:/state
	export CONFINE_LANDLOCK
	echo "target: N+F+M (landlock write-allowlist active)" >&2
else
	echo "target: N+F only — M: unavailable (no CONFIG_SECURITY_LANDLOCK on this kernel);" >&2
	echo "        writes outside /tmp /dev/shm /workspace /state will NOT be denied" >&2
fi

exec "$H/confine" "$@"
ENTER
chmod 0755 "$STAGE/.harness/enter.sh"

# Anything the caller asked to bring along. It lands at /workspace/<basename>.
for p in ${STAGE_IN+"${STAGE_IN[@]}"}; do
	[ -e "$p" ] || { echo "SKIP: --stage $p does not exist" >&2; exit 2; }
	cp -a -- "$p" "$STAGE/$(basename -- "$p")"
done

# The uid-1000-owned-directory fixture: the census cannot build it itself,
# because chown to an unmapped id is exactly what the runtime denies.
mkdir -p "$STAGE/.fixtures/squash-probe"
chown -R 1000:1000 "$STAGE/.fixtures" 2>/dev/null || true
chown -R 1000:1000 "$STAGE" 2>/dev/null || true

# ------------------------------------------------------------------ run
DOCKER_ARGS=(
	--rm -i
	--privileged                 # mount(2) and pivot_root(2) build the topology
	--security-opt seccomp=unconfined
	-v "$STAGE:/stage"
	-e "TARGET_HOST_UID=1000"
	-e "TARGET_WORKSPACE=/stage"
)
[ -t 0 ] && DOCKER_ARGS+=(-t)

if [ "$RAW" = 1 ]; then
	exec docker run "${DOCKER_ARGS[@]}" --entrypoint /bin/sh "$IMAGE" -c \
		'cp -a /stage/. /target-stage 2>/dev/null; exec "$@"' -- "${ARGS[@]}"
fi

echo "== reconstruction conditions" >&2
printf 'date              %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
printf 'host kernel       %s\n' "$(uname -r)" >&2
printf 'image             %s\n' "$(docker image inspect -f '{{.Id}}' "$IMAGE")" >&2

exec docker run "${DOCKER_ARGS[@]}" "$IMAGE" "${ARGS[@]}"
