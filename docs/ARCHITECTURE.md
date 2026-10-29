# RPM Build Pipeline — how it works

Quick writeup of how `dugeo/it-rpm-build` turns a pinned SRPM into built,
verified RPMs on Nexus. Covers the flow, why some of it is weird, and where
stuff actually lives.

Reference build: Lustre client 2.16.1-1 against kernel
`5.14.0-570.26.1.2.dug.el9`. Built and published 2026-10-29, this is what
the doc is based on.

## related repos

| Repo | What it's for |
|---|---|
| `dugeo/it-rpm-build` (this one) | manifests, build templates, the workflow, the builder image Containerfile |
| `dugeo/it-k8s` | cluster/GitOps, Flux. ARC runner HelmReleases, DUGCA trust bundle, namespaces, secrets |
| `dugeo/it-k8s` (cgit app) | internal cgit server, one dist-git repo per package (e.g. `lustre.git`) |
| Nexus `nexus.kube.dug.com` | final artifact store, `rpm-hosted` repo, plain PUT upload |
| Nexus `nexus.dug.com` | legacy DUG EL build deps, used only at build time, never published to |
| `downloads.whamcloud.com` | upstream pinned Lustre SRPM |

## the flow

```
manifest (packages/*.yaml)
  │
  ▼
validate job — schema + script check, runs on every PR, no cluster creds
  │
  ▼
build job (push to main / manual dispatch), on rpm-build-runners:
  1. download SRPM, check pinned SHA-256
  2. make sure cgit dist-git repo exists (newrepo via restricted ssh key)
  3. rpkg import --offline the SRPM into dist-git, commit + push
     (original SRPM kept under SOURCES/ in dist-git too)
  4. copy build template (build.sh + mock.cfg) into the dist-git checkout
  5. rpkg srpm — regenerate buildable SRPM from dist-git
  6. build.sh runs mock (privileged) → binary RPMs
  7. verify everything (rpm -K, digest check)
  8. upload SRPM + every binary RPM to Nexus rpm-hosted (idempotent)
```

Everything after step 1 runs in the ARC "build" job container, on a
kubernetes-mode ephemeral runner, 10Gi ceph-rbd scratch PVC, privileged via
an ARC hook extension.

## why it's built this way

stuff that isn't obvious just reading the workflow, each one burned us at
least once:

1. **ARC runner mode is `containerMode: kubernetes`, not dind.** dind mode
   was silently wiping `/workspace` between steps. kubernetes mode runs the
   job as a real sibling container on a shared PVC — no bind-mount
   translation, no teardown.

2. **image pull secrets have to go on the `arc-runners` namespace's
   `default` ServiceAccount**, not just the runner pod template. the
   container-hook-spawned `*-workflow` pod runs as SA `default` and does NOT
   inherit `imagePullSecrets` from the runner's own pod spec. see
   `dugeo/it-k8s`: `kubernetes/apps/arc-runners/default-sa-pull-secret.yaml`.

3. **`mock` needs `--privileged`, and the workflow's `container: options:
   --privileged` does nothing** under kubernetes mode — silently ignored.
   real fix is an ARC hook extension: a ConfigMap with a PodSpec fragment,
   wired via `ACTIONS_RUNNER_CONTAINER_HOOK_TEMPLATE`. see `dugeo/it-k8s`:
   `rpm-build-hook-extension.yaml` + the HelmRelease wiring.

4. **`rpkg --release` is global**, goes before the subcommand
   (`rpkg --release rhel-9 srpm ...`, not `rpkg srpm --release rhel-9`), and
   the value has to match `rhel-\d.*$` — `el9` gets rejected, `rhel-9` works.

5. **`rpkg srpm --builddir X` doesn't actually write the SRPM into X** — it
   lands in cwd instead. workflow `mv`s it into `results/srpm/` after.

6. **EPEL inside the mock chroot needs the fedoraproject mirrorlist**, not a
   hardcoded `download.fedoraproject.org` baseurl — that host just wasn't
   reachable from inside the chroot even though centos mirrors worked fine.
   also set `skip_if_unavailable=1` so a flaky EPEL doesn't kill the whole
   chroot.

7. **`kernel-devel` doesn't create `/lib/modules/<kver>/{source,build}`.**
   those symlinks normally come from the real `kernel` package's `%post`,
   which never runs in a mock chroot. `build.sh` makes them by hand between
   `mock --init` and `--rebuild`, otherwise Lustre's configure dies with
   "Kernel source could not be found."

8. **`libmount-devel` needs to be in the chroot base packages.** Lustre's
   configure wants it but it's not in the SRPM's declared BuildRequires, so
   `dnf builddep` alone won't grab it.

9. **Lustre version has to match the kernel's actual VFS ABI, not just the
   nominal version number.** lustre-2.15.5's compat shims
   (`posix_acl_update_mode`, `capable_wrt_inode_uidgid`, xattr handlers,
   `vfs_getattr`) don't line up with `5.14.0-570.26.1.2.dug.el9`'s real
   headers — this vendor kernel backported newer VFS stuff ahead of stock
   5.14. lustre-2.16.1 does match and builds clean. if the kernel changes,
   recheck this.

10. **client-only Lustre builds need `--rpmbuild-opts="--without servers"`
    through mock.** configure correctly turns off ldiskfs/server support
    for a client SRPM, but the spec's own %build sanity check treats that
    as a hard error unless you tell it `--without servers`. mock has no
    native `--without` flag, you pass it through `--rpmbuild-opts`.

11. **the rpm-build image trusts the cluster's internal CA (DUGCA).**
    `nexus.kube.dug.com`'s cert is signed by the cluster's self-signed chain
    (DUGCA_SVC ← DUGCA), not in stock CentOS Stream 9's trust store. same
    bundle `dugeo/it-k8s` already uses for containerd pulls
    (`talos/all/70-registries.yaml`) gets baked into
    `/etc/pki/ca-trust/source/anchors/` at image build time. TLS
    verification stays on, nothing's disabled.

12. **verify/upload has to search `results/rpm`, not just the dist-git
    checkout.** build.sh runs mock with `--resultdir=/workspace/results/rpm`
    — that's where the binary RPMs actually land. an earlier version of the
    workflow only looked in `$workdir/package`, which silently matched
    nothing (no error, `find | while read` over zero files just does
    nothing) — so only the two SRPMs ever got verified/uploaded, never the
    real `kmod-lustre-client-*` etc packages. fixed by searching both
    `results/rpm` and `results/srpm`/`package`.

13. **Nexus uploads need to be idempotent.** `rpm-hosted` rejects
    re-uploading an existing path with HTTP 400 (no-redeploy). re-running
    the pipeline against unchanged output can't fail because of that —
    `upload_if_absent()` checks the URL first, skips if it's already a 200.

## where stuff actually lives

- **manifests** (source pin + build config) — this repo, `packages/*.yaml`
- **build templates** (`build.sh`, `mock.cfg` per OS/kernel gen) — this
  repo, `templates/<name>/`
- **dist-git** (imported spec + sources, full history) — cgit, one repo per
  package, e.g. `lustre.git`, created on demand via restricted `newrepo` key
- **build artifacts** (final SRPM + binary RPMs) — Nexus `rpm-hosted`
- **runner infra** (ARC scale sets, hook extension, pull secrets, DUGCA
  bundle, PVC) — `dugeo/it-k8s`, GitOps/Flux
- **builder image** (`registry.kube.dug.com/rpm-build:<tag>`) — built from
  this repo's Containerfile via a one-off Kaniko Job in `devops` namespace.
  not Flux-managed, bump tag and rebuild manually when Containerfile or
  templates change (see guide)

## required secrets (on `dugeo/it-rpm-build`)

```
CGIT_SSH_PRIVATE_KEY          clone/push key for dist-git
CGIT_REPO_ADMIN_PRIVATE_KEY   restricted key, only runs newrepo on cgit
CGIT_KNOWN_HOSTS              pinned cgit host key, checked against a fixed
                               fingerprint in the workflow
NEXUS_USERNAME / NEXUS_PASSWORD               publish creds (rpm-hosted)
LEGACY_NEXUS_USERNAME / LEGACY_NEXUS_PASSWORD build dep creds (dug-el)
```

## runner labels, don't mix these up

```yaml
# dugeo/it-k8s   (cluster infra CI)
runs-on: it-k8s-runners

# dugeo/it-rpm-build (this repo)
runs-on: rpm-build-runners
```
never use `ppltk8s-arc-runner` or `k8s-runner` — wrong/old labels.
