# RPM Build Pipeline — Architecture & Flow

This document explains how `dugeo/it-rpm-build` turns a pinned upstream SRPM
into signed, verified RPMs published to Nexus, fully automated on GitHub
Actions self-hosted runners. It covers the end-to-end flow, the infrastructure
it depends on, every non-obvious fix baked into the pipeline, and where things
live across repositories.

Reference build: **Lustre client 2.16.1-1** against kernel
`5.14.0-570.26.1.2.dug.el9`, built and published 2026-10-29. Everything below
is written against that proven run.

## Related repositories

| Repo | Role |
|---|---|
| [`dugeo/it-rpm-build`](.) (this repo) | Source of truth: package manifests, build templates, the GitHub Actions workflow, the `rpm-build` builder image's `Containerfile`. |
| `dugeo/it-k8s` | Cluster GitOps (Flux). Owns the ARC (`actions-runner-controller`) `HelmRelease`s for both runner scale sets, the DUGCA trust bundle (`talos/all/70-registries.yaml`), namespaces, secrets wiring. |
| `dugeo/it-k8s` (cgit app) | Hosts the internal cgit Git server (`cgit.devops.svc.cluster.local`) that stores one dist-git repository per package (e.g. `lustre.git`). |
| Nexus (`nexus.kube.dug.com`) | Final artifact store. Hosted repo `rpm-hosted` receives built SRPMs/RPMs via plain `PUT`. |
| Nexus (`nexus.dug.com`) | Legacy DUG EL build-dependency repository (`dug-el/9/dug/x86_64` and per-kernel `dug-el/kernel-<ver>/dug/x86_64`), consumed only at build time by `mock`/`dnf`, never published to. |
| `downloads.whamcloud.com` | Upstream, immutable source of the Lustre client SRPM. |

## High-level flow

```
manifest (packages/*.yaml)
  │
  ▼
validate (schema + script check)         — runs on every PR, cheap, no cluster creds
  │
  ▼
build job (push to main / workflow_dispatch), on rpm-build-runners:
  1. download SRPM, verify pinned SHA-256
  2. ensure cgit dist-git repo exists (`newrepo` over a restricted SSH key)
  3. `rpkg import --offline` the verified SRPM into dist-git, commit + push
     (original SRPM retained under SOURCES/ in the dist-git repo)
  4. copy the build template (build.sh + mock.cfg) into the dist-git checkout
  5. `rpkg srpm` — regenerate the buildable SRPM from dist-git
  6. `build.sh` — run `mock` (privileged) to produce binary RPMs
  7. verify every RPM/SRPM (`rpm -K`, digest check)
  8. upload SRPM + every binary RPM to Nexus rpm-hosted (idempotent)
```

Everything after step 1 runs inside the ARC "build" job container, on a
Kubernetes-backed ephemeral runner (`containerMode: kubernetes`) with a
10Gi Ceph-RBD scratch PVC and `--privileged` set via an ARC hook extension.

## Why it's built this way (the non-obvious decisions)

These are the decisions that are **not** visible just from reading the
workflow file, each forced by a real failure encountered while building this
pipeline:

1. **ARC runner mode: `containerMode: kubernetes`, not dind.**
   The original docker-in-docker runner mode silently tore down
   `/workspace` between steps. Kubernetes mode runs the job container as a
   real sibling Pod container sharing a PVC — no bind-mount translation, no
   teardown.

2. **Image pull secrets must be attached to the `arc-runners` namespace's
   `default` ServiceAccount, not just the runner pod template.** ARC's
   container-hook-spawned `*-workflow` pod runs under SA `default` and does
   **not** inherit `template.spec.imagePullSecrets` from the runner's own
   pod spec. See `dugeo/it-k8s`:
   `kubernetes/apps/arc-runners/default-sa-pull-secret.yaml`.

3. **`mock` needs a privileged container, which `container: options:
   --privileged` in the workflow YAML does NOT provide** under
   `containerMode: kubernetes` — that field is silently ignored for the
   job-container pod. The real mechanism is an ARC **hook extension**:
   a ConfigMap holding a PodSpec fragment, wired in via
   `ACTIONS_RUNNER_CONTAINER_HOOK_TEMPLATE`. See `dugeo/it-k8s`:
   `kubernetes/apps/arc-systems/gha-runner-scale-set/app/rpm-build-hook-extension.yaml`
   and the corresponding `helmrelease-rpm-build.yaml` volume/env wiring.

4. **`rpkg --release` is a *global* option** (must precede the subcommand,
   e.g. `rpkg --release rhel-9 srpm ...`, not `rpkg srpm --release rhel-9`),
   and its value must match pyrpkg's `rhel-\d.*$` regex — `el9` is rejected,
   `rhel-9` is accepted.

5. **`rpkg srpm --builddir X` does not write the final `.src.rpm` into
   `X`** — it lands in the current working directory. The workflow
   explicitly `mv`s it into `results/srpm/` afterward.

6. **EPEL inside the mock chroot must use the `mirrors.fedoraproject.org`
   mirrorlist**, not a single hardcoded `download.fedoraproject.org`
   baseurl — the latter was unreachable from inside the chroot even though
   CentOS Stream mirrors resolved fine. `skip_if_unavailable=1` is also set
   so a future EPEL hiccup doesn't block the whole chroot.

7. **`kernel-devel` does not create `/lib/modules/<kver>/{source,build}`.**
   Those symlinks are normally created by the real `kernel` package's
   `%post`, which never runs inside a mock chroot. `build.sh` creates them
   explicitly (`mock --chroot -- ln -sfn ...`) between `mock --init` and
   `mock --rebuild`, otherwise Lustre's `configure --with-linux=...` fails
   with "Kernel source could not be found."

8. **`libmount-devel` must be in the chroot's base package set.** Lustre's
   `configure` requires it but the SRPM's declared `BuildRequires` doesn't
   list it, so `dnf builddep` alone won't pull it in.

9. **Lustre version must match the kernel's actual VFS ABI generation, not
   just its nominal upstream version.** `lustre-2.15.5`'s compat shims
   (`posix_acl_update_mode`, `capable_wrt_inode_uidgid`, xattr handlers,
   `vfs_getattr`) don't match `5.14.0-570.26.1.2.dug.el9`'s real headers —
   that vendor kernel has backported newer upstream VFS changes (idmapped
   mounts, xattr-handler refactor) ahead of a stock 5.14. `lustre-2.16.1`
   does, and currently builds clean. If you re-pin the kernel version,
   re-check this.

10. **Client-only Lustre builds need `--rpmbuild-opts="--without servers"`
    passed through `mock`.** `configure` correctly auto-disables
    ldiskfs/server support for a client SRPM, but the spec's own `%build`
    sanity check treats "server support configured but not found" as a hard
    error unless explicitly told `--without servers`. `mock` has no native
    `--without` passthrough — the flag is `--rpmbuild-opts`.

11. **The `rpm-build` builder image trusts the cluster's internal CA
    (DUGCA).** `nexus.kube.dug.com` serves a cert issued by the cluster's
    self-signed CA chain (`DUGCA_SVC` ← `DUGCA`), not in the stock CentOS
    Stream 9 trust store. The same bundle `dugeo/it-k8s` already uses for
    containerd image pulls (`talos/all/70-registries.yaml`) is baked into
    `/etc/pki/ca-trust/source/anchors/` at image build time
    (`dugca-bundle.pem` + `update-ca-trust extract` in the `Containerfile`).
    TLS verification stays **on** everywhere; nothing disables cert
    checking.

12. **Verify/upload steps must search `results/rpm`, not just the dist-git
    checkout.** `build.sh` invokes `mock` with
    `--resultdir=/workspace/results/rpm`, so that's where every compiled
    binary RPM actually lands. An earlier version of the workflow only
    searched `$workdir/package` — which silently matched zero binary RPMs
    (no error, since `find | while read` over an empty list just does
    nothing) — so only the two SRPMs were ever verified/published, never
    the real `kmod-lustre-client-*`, `lustre-client-*` etc. packages. Fixed
    by searching both `results/rpm` and `results/srpm`/`package` as
    appropriate.

13. **Nexus uploads must be idempotent.** `rpm-hosted` rejects re-uploading
    an unchanged path with HTTP 400 (no-redeploy policy on hosted repos).
    Re-running the pipeline against an already-published SRPM/RPM set must
    not fail — `upload_if_absent()` checks each destination URL first and
    skips (success) if it already returns 200.

## Where state actually lives

- **Package manifests** (immutable source pin + build config): this repo,
  `packages/*.yaml`.
- **Build templates** (`build.sh`, `mock.cfg` per OS/kernel generation):
  this repo, `templates/<template-name>/`.
- **Dist-git** (imported spec + sources, full history per package): cgit,
  one repo per package, e.g. `lustre.git`. Created on demand via a
  restricted `newrepo` SSH key.
- **Build artifacts** (final SRPM + binary RPMs): Nexus, `rpm-hosted`.
- **Runner infrastructure** (ARC scale sets, hook extension, pull secrets,
  the DUGCA trust bundle, PVC): `dugeo/it-k8s`, GitOps-managed by Flux.
- **Builder image** (`registry.kube.dug.com/rpm-build:<tag>`): built from
  this repo's `Containerfile` via a one-off Kaniko `Job` in the `devops`
  namespace (not a Flux-managed resource — bump the tag and rebuild
  manually when the `Containerfile`/templates change; see the guide below).

## Required GitHub Actions secrets (configured on `dugeo/it-rpm-build`)

```
CGIT_SSH_PRIVATE_KEY          clone/push key for dist-git repositories
CGIT_REPO_ADMIN_PRIVATE_KEY   restricted key, only runs `newrepo` on cgit
CGIT_KNOWN_HOSTS              pinned cgit host key (checked against a fixed
                               fingerprint in the workflow, not trusted blindly)
NEXUS_USERNAME / NEXUS_PASSWORD               publish credentials (rpm-hosted)
LEGACY_NEXUS_USERNAME / LEGACY_NEXUS_PASSWORD build-dependency credentials (dug-el)
```

## Runner labels (do not mix these up)

```yaml
# dugeo/it-k8s   (cluster infra CI)
runs-on: it-k8s-runners

# dugeo/it-rpm-build (this repo's build workflow)
runs-on: rpm-build-runners
```
Never use `ppltk8s-arc-runner` or `k8s-runner` — deprecated/wrong labels.
