#!/usr/bin/env bash
# Question: can a container image supply the target runtime's userspace — the
# toolchain it has (go, gcc, python3, tar, zstd) and the files it lacks
# (/etc/passwd, /run, /var, /dev/fuse)?
#
# Builds one image, pinned by base digest. Prints its own conditions.
# Exit: 0 built, 1 build failed, 2 could not run (no docker).
set -euo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
IMAGE="${TARGET_IMAGE:-container-research/target:1}"

command -v docker >/dev/null 2>&1 || { echo "SKIP: docker not on PATH" >&2; exit 2; }
docker info >/dev/null 2>&1 || {
	echo "SKIP: docker daemon not reachable. Start it (dockerd &) and retry." >&2
	exit 2
}

echo "== building $IMAGE"
docker build -f "$HERE/Dockerfile.target" -t "$IMAGE" "$HERE" || exit 1

echo
echo "== conditions"
printf 'date              %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'host kernel       %s\n' "$(uname -r)"
printf 'docker            %s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
printf 'image             %s\n' "$IMAGE"
printf 'image id          %s\n' "$(docker image inspect -f '{{.Id}}' "$IMAGE")"

echo
echo "== what the image has, and has not"
docker run --rm --entrypoint /bin/sh "$IMAGE" -c '
  printf "go                %s\n" "$(go version 2>/dev/null | cut -d" " -f3 || echo MISSING)"
  printf "gcc               %s\n" "$(gcc -dumpversion 2>/dev/null || echo MISSING)"
  printf "python3           %s\n" "$(python3 -V 2>&1 | cut -d" " -f2 || echo MISSING)"
  printf "tar               %s\n" "$(tar --version | head -1 | cut -d" " -f4)"
  printf "zstd              %s\n" "$(zstd --version 2>&1 | sed "s/.*v\([0-9.]*\).*/\1/")"
  printf "rustc             %s\n" "$(rustc --version 2>/dev/null || echo "MISSING (as on the target)")"
  printf "docker on PATH    %s\n" "$(docker --version 2>/dev/null || echo MISSING)"
'
echo
echo "next: ./experiments/20-enter-target.sh"
