#!/bin/bash
# el9 mock build driver, selected by manifest `build.template: el9`.
#
# Usage: build.sh --arch <arch> [--kernel <kernel-version>]
#
# Expects to run with cwd = the package's dist-git checkout (/workspace/package),
# with the base mock config already copied in alongside this script
# (see MOCK_CONFIG). The SRPM produced by `rpkg srpm` is expected at
# /workspace/results/srpm/*.src.rpm. Built RPMs land in /workspace/results/rpm.
set -euo pipefail

arch="x86_64"
kernel=""
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) arch="$2"; shift 2 ;;
    --arch=*) arch="${1#*=}"; shift ;;
    --kernel) kernel="$2"; shift 2 ;;
    --kernel=*) kernel="${1#*=}"; shift ;;
    *) echo "build.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

: "${MOCK_CONFIG:=mock.cfg}"
: "${RPM_REPOSITORY_URL:?RPM_REPOSITORY_URL is required}"
: "${LEGACY_NEXUS_USERNAME:?LEGACY_NEXUS_USERNAME is required}"
: "${LEGACY_NEXUS_PASSWORD:?LEGACY_NEXUS_PASSWORD is required}"

test -f "$MOCK_CONFIG"

srpm_file=$(find /workspace/results/srpm -maxdepth 1 -type f -name '*.src.rpm' | head -n1)
if [ -z "$srpm_file" ]; then
  echo "build.sh: no SRPM found under /workspace/results/srpm" >&2
  exit 1
fi

configdir=/etc/mock
install -d -m 0755 "$configdir"
cp "$MOCK_CONFIG" "$configdir/rpm-ci-build.cfg"

# The legacy DUG repository (and, when a specific kernel is pinned, its exact
# kernel-devel package) is only known/credentialed at build time, so it is
# appended to the mock config here instead of being committed to git.
{
  printf "config_opts['dnf.conf'] += \"\"\"\n"
  printf '[legacy]\n'
  printf 'name=legacy DUG EL\n'
  printf 'baseurl=%s\n' "$RPM_REPOSITORY_URL"
  printf 'enabled=1\n'
  printf 'gpgcheck=0\n'
  printf 'username=%s\n' "$LEGACY_NEXUS_USERNAME"
  printf 'password=%s\n' "$LEGACY_NEXUS_PASSWORD"
  printf '\"\"\"\n'
} >> "$configdir/rpm-ci-build.cfg"

if [ -n "$kernel" ]; then
  printf "config_opts['chroot_setup_cmd'] += ' kernel-devel-%s'\n" "$kernel" >> "$configdir/rpm-ci-build.cfg"
fi

mkdir -p /workspace/results/rpm

mock_args=(-r rpm-ci-build --resultdir=/workspace/results/rpm --arch "$arch")
if [ -n "$kernel" ]; then
  mock_args+=(--define "kver ${kernel}.${arch}")
fi

mock "${mock_args[@]}" --rebuild "$srpm_file"
