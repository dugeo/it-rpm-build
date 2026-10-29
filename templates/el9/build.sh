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

# The legacy DUG repository (and, when a specific kernel is pinned, a
# second repository scoped to that exact kernel build) are only known or
# credentialed at build time, so they are appended to the mock config here
# instead of being committed to git.
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
  # Each kernel build gets its own package directory under dug-el, e.g.
  #   https://nexus.dug.com/repository/dug-el/9/dug/x86_64/            (generic)
  #   https://nexus.dug.com/repository/dug-el/kernel-<version>/dug/x86_64/ (per-kernel)
  # Derive the per-kernel URL from RPM_REPOSITORY_URL's dug-el/ prefix so the
  # kernel repo location never has to be duplicated in the manifest.
  repo_prefix="${RPM_REPOSITORY_URL%%dug-el/*}dug-el/"
  kernel_repo_url="${repo_prefix}kernel-${kernel}/dug/x86_64/"
  {
    printf "config_opts['dnf.conf'] += \"\"\"\n"
    printf '[legacy-kernel]\n'
    printf 'name=legacy DUG EL kernel %s\n' "$kernel"
    printf 'baseurl=%s\n' "$kernel_repo_url"
    printf 'enabled=1\n'
    printf 'gpgcheck=0\n'
    printf 'username=%s\n' "$LEGACY_NEXUS_USERNAME"
    printf 'password=%s\n' "$LEGACY_NEXUS_PASSWORD"
    printf '\"\"\"\n'
  } >> "$configdir/rpm-ci-build.cfg"
  # Lustre's spec resolves %{kdir}/%{kobjdir} from /lib/modules/%{kver}/{source,build},
  # which come from kernel-devel; kernel/kernel-headers are pulled in for
  # completeness since they share the same per-kernel repo.
  printf "config_opts['chroot_setup_cmd'] += ' kernel-devel-%s kernel-headers-%s'\n" "$kernel" "$kernel" >> "$configdir/rpm-ci-build.cfg"
fi

mkdir -p /workspace/results/rpm

mock_args=(-r rpm-ci-build --resultdir=/workspace/results/rpm --arch "$arch")
if [ -n "$kernel" ]; then
  mock_args+=(--define "kver ${kernel}.${arch}")
fi

dump_mock_logs() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    echo "build.sh: mock failed (exit $status); dumping build logs" >&2
    for log in root.log build.log state.log; do
      if [ -f "/workspace/results/rpm/$log" ]; then
        echo "===== $log =====" >&2
        tail -n 300 "/workspace/results/rpm/$log" >&2
      fi
    done
  fi
  return "$status"
}
trap dump_mock_logs EXIT

mock "${mock_args[@]}" --rebuild "$srpm_file"
