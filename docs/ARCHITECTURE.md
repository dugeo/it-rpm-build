# RPM Build Pipeline — how it works

Quick writeup of how `dugeo/it-rpm-build` turns a pinned SRPM into built,
verified RPMs on Nexus. Covers the flow, why some of it is weird, and where
stuff actually lives.

Reference build: Lustre client 2.16.1-1 against kernel
`5.14.0-570.26.1.2.dug.el9`. Built and published 2026-10-29, this is what
the doc is based on.

## why this matters

old way of building an RPM: ssh into a build box, clone the spec, fiddle with
mock configs by hand, run mock, scp the result to Nexus yourself, hope you
remember what you did next time a new version drops. all manual, all
tribal knowledge, breaks the moment the person who did it last isn't around.

new way: nobody ssh's into anything. you write a manifest (pinned URL +
sha256 + which template + which kernel if any), push it, CI does the rest —
import, build, verify, publish. want to rebuild the same package again, or
build it for a different kernel? edit the manifest, push, done. the whole
build is reproducible from git history, not from someone's memory of what
flags they used.

so adding/rebuilding a package is now a config change, not an op. see the
template guide for the actual "push this and it builds" steps.

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

## netboot image pipeline (new, scaffolded, not wired up yet)

same repo, same manifest-driven idea, but this one just triggers an existing
`dugeo/ansible` playbook instead of running mock. reasoning for keeping it
here instead of a new repo: it's the same lifecycle as the RPM pipeline —
bump Lustre, rebuild the image that ships it. splitting them into two repos
just means cross-referencing two CI systems for one change. they share
nothing at execution time (no mock, no cgit, no rpkg) but share everything
at the "why does this exist" level.

```
images/<name>.yaml
  │
  ▼
validate job — schema check, same pattern as packages/
  │
  ▼
build job, on rpm-build-runners:
  1. checkout this repo (manifest)
  2. checkout dugeo/ansible pinned to the manifest's ansible.ref
  3. ansible-playbook <manifest's playbook> against target.host,
     with --vault-password-file and an ssh key
```

that's it. no mock, no Nexus upload (yet), no cgit. the playbook
(`roles/local/boot-image-9/{image-create,image-init,image-bundle}` in
`dugeo/ansible`) already does everything: chroot build via systemd-nspawn on
the target host, on that host's own ZFS pool, writing the final
`image.tar.gz`/`vmlinuz`/`initrd.img` + a `current` symlink + `.image_version`
timestamp file right there. since `ppxe0001` builds and serves from the same
box today, there's nothing to "publish" — the artifact already lands where
PXE reads it.

### why this pipeline looks different from the RPM one

- **no mock, no privileged container.** the actual heavy lifting
  (`systemd-nspawn`, `zfs create`, `dnf install` in a chroot) all happens on
  the target host over ssh, not in the runner's job container. the runner
  just needs `ansible-playbook` + an ssh key + git, nothing privileged.

- **rollback already exists, it's just not ZFS-based at the artifact
  level.** the role's `zfs snapshot {{ osimage_pool }}@{{ image_date }}`
  snapshots the raw chroot build dir, for cheaply resuming/retrying a build —
  it's not what versions the shipped artifact. the shipped artifacts are
  already timestamped (`image.tar.gz.<date>`, `vmlinuz.<date>`,
  `initrd.img.<date>`) with a `current`-style symlink and a `.image_version`
  file, both inside and outside the image. rollback today = point the
  symlink at an older date. nothing new needed for that as long as
  `ppxe0001` keeps doing the serving.

- **three things are still open, deliberately not solved yet:**
  1. `dugeo/ansible` access is restricted — the checkout step needs its own
     token/deploy key (`ANSIBLE_CHECKOUT_TOKEN`), not whatever credential
     this repo already uses for `dugeo/it-k8s` or cgit.
  2. the ansible vault password (`ANSIBLE_VAULT_PASSWORD`) and an ssh key to
     the target host (`ANSIBLE_SSH_PRIVATE_KEY`) aren't provisioned yet.
     `set -euo pipefail` + explicit `test -n` checks in the workflow make
     this fail loud instead of silently skipping, so it's obvious what's
     missing instead of someone debugging a no-op run later.
  3. the LDAP/root password (`pwhash_root_compute` in
     `inventory/group_vars/all/vault_teamit.yml`, currently decrypted via
     ansible-vault at playbook runtime) might move to SOPS eventually, to
     line up with how `dugeo/it-k8s` already manages secrets. not scoped
     yet — vault-based decryption keeps working as-is until this is
     revisited.

- **not targeting `ppxe0001` specifically by design.** the manifest's
  `target.host` is just a value, not a hardcoded assumption — if the build
  moves off `ppxe0001` (e.g. a dedicated build host, or eventually an
  in-cluster PXE deployment in `dugeo/it-k8s`), only the manifest changes.
  that's also when the currently-unused `publish.nexus_repository` field in
  the image manifest schema becomes relevant: once build and serve aren't
  the same host anymore, you need a durable versioned copy in between
  (Nexus raw hosted repo, not Docker/OCI — these are plain tarballs/kernel
  images, no layering benefit from an image format, and it reuses the exact
  auth/trust/idempotent-upload pattern already proven in the RPM pipeline's
  `upload_if_absent`). PXE's actual hard constraint at that point is
  networking (TFTP/DHCP needs L2 proximity to the boot VLAN, or a DHCP
  relay), not storage — scope that separately before building it.

## where stuff actually lives

- **manifests** (source pin + build config) — this repo, `packages/*.yaml`
  and `images/*.yaml`
- **build templates** (`build.sh`, `mock.cfg` per OS/kernel gen, RPM
  pipeline only) — this repo, `templates/<name>/`
- **dist-git** (imported spec + sources, full history, RPM pipeline only) —
  cgit, one repo per package, e.g. `lustre.git`, created on demand via
  restricted `newrepo` key
- **build artifacts** (final SRPM + binary RPMs) — Nexus `rpm-hosted`
- **netboot image artifacts** — host-local today (`ppxe0001`'s ZFS pool),
  not yet in Nexus
- **the actual image-build logic** (chroot creation, package lists, bundling)
  — `dugeo/ansible`, `roles/local/boot-image-9/*`. this repo only pins a ref
  and triggers it, doesn't duplicate any of that logic
- **runner infra** (ARC scale sets, hook extension, pull secrets, DUGCA
  bundle, PVC) — `dugeo/it-k8s`, GitOps/Flux
- **builder image** (`registry.kube.dug.com/rpm-build:<tag>`) — built from
  this repo's Containerfile via a one-off Kaniko Job in `devops` namespace.
  not Flux-managed, bump tag and rebuild manually when Containerfile or
  templates change (see guide)

## required secrets (on `dugeo/it-rpm-build`)

```
# RPM pipeline
CGIT_SSH_PRIVATE_KEY          clone/push key for dist-git
CGIT_REPO_ADMIN_PRIVATE_KEY   restricted key, only runs newrepo on cgit
CGIT_KNOWN_HOSTS              pinned cgit host key, checked against a fixed
                               fingerprint in the workflow
NEXUS_USERNAME / NEXUS_PASSWORD               publish creds (rpm-hosted)
LEGACY_NEXUS_USERNAME / LEGACY_NEXUS_PASSWORD build dep creds (dug-el)

# netboot image pipeline (not provisioned yet, see above)
ANSIBLE_CHECKOUT_TOKEN        read-only access to dugeo/ansible
ANSIBLE_SSH_PRIVATE_KEY       ssh key to the target host
ANSIBLE_VAULT_PASSWORD        ansible-vault password
```

## runner labels, don't mix these up

```yaml
# dugeo/it-k8s   (cluster infra CI)
runs-on: it-k8s-runners

# dugeo/it-rpm-build (this repo)
runs-on: rpm-build-runners
```
never use `ppltk8s-arc-runner` or `k8s-runner` — wrong/old labels.
