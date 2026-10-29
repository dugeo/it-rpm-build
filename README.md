# RPM & Netboot Image Build Control Repository

This repository is the source of truth for two related, manifest-driven CI/CD
pipelines that share the same philosophy — pin a source, let CI do the rest,
never ssh in by hand:

1. **RPM pipeline**: SRPM import, mock builds, Nexus publication.
2. **Netboot image pipeline**: runs a pinned `dugeo/ansible` playbook to
   (re)build a bootable compute/desktop/storage image whenever the packages
   it ships (e.g. a new Lustre build from the RPM pipeline above) change.

It is intentionally separate from `dugeo/it-k8s`:

- this repository contains package/image manifests and build templates;
- `dugeo/it-k8s` contains cluster/GitOps configuration;
- cgit contains generated dist-git package repositories (RPM pipeline only);
- Nexus contains SRPM/RPM artifacts;
- `dugeo/ansible` contains the actual image-build playbooks and roles
  (`roles/local/boot-image-9/*`) — this repo only pins a ref and triggers it.

**See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** for the full pipeline
flow, why it's built the way it is, and every related repository/system it
touches. **See [`docs/TEMPLATE_GUIDE.md`](docs/TEMPLATE_GUIDE.md)** for a
step-by-step guide to adding a new package or kernel pairing.

## Add a package

Copy a manifest under `packages/`, set the immutable SRPM URL and SHA-256,
choose a build template, and open a pull request. A merged manifest change
becomes the input to the RPM build workflow.

## Add/rebuild a netboot image

Copy a manifest under `images/`, point it at the `dugeo/ansible` commit SHA
and playbook path to run, and open a pull request. A merged manifest change
becomes the input to the image-build workflow, which runs
`ansible-playbook` against the target host (currently `ppxe0001`, which
builds and serves from the same box — no separate publish step needed yet).
See `docs/ARCHITECTURE.md` for why this pipeline looks different from the
RPM one, and what's still open (vault password, SSH key, restricted
`dugeo/ansible` access, future in-cluster PXE serving + Nexus archival).

## Repository layout

```text
packages/                 RPM package manifests
images/                   Netboot image manifests
schemas/                  Manifest validation schemas (both pipelines)
templates/                Shared RPM build and mock templates
Containerfile             Runner-side RPM tool image
.github/workflows/        rpm-build.yml and image-build.yml, both on
                          `rpm-build-runners`
```

## Required CI secrets

Configure these in the `rpm-build` GitHub repository:

```text
CGIT_SSH_PRIVATE_KEY          key allowed to clone/push package repositories
CGIT_REPO_ADMIN_PRIVATE_KEY   restricted key allowed only to run newrepo
CGIT_KNOWN_HOSTS              pinned known_hosts entry for cgit.kube.dug.com
NEXUS_USERNAME                 publication Nexus username
NEXUS_PASSWORD                 publication Nexus password
LEGACY_NEXUS_USERNAME          legacy dependency Nexus username
LEGACY_NEXUS_PASSWORD          legacy dependency Nexus password
```

The build dependency repository is the legacy DUG EL repository at
`https://nexus.dug.com/repository/dug-el/9/dug/x86_64/`; credentials are supplied
only through the existing GitHub Actions secrets. Build publication remains on
`https://nexus.kube.dug.com/repository/rpm-hosted`, whose TLS certificate is
signed by the cluster's internal DUGCA chain — the `rpm-build` builder image
(`Containerfile`) bakes in `dugca-bundle.pem` via `update-ca-trust` so uploads
verify TLS normally, without `-k`/insecure flags.

The workflow uses the `rpm-build-runners` ARC label and performs the full
sequence without Kubernetes administrator credentials:

## Build contract

For every manifest the runner must:

1. validate the manifest and SHA-256 format;
2. create the cgit repository if it does not exist, or fail clearly if the
   restricted repository-admin key is not configured;
3. render the selected template into the cgit checkout;
4. download and verify the SRPM;
5. run `rpkg import`, commit, and push;
6. run `rpkg srpm` and `mock`;
7. verify RPM signatures/checksums;
8. upload RPMs and the SRPM to Nexus;
9. publish build logs and metadata as workflow artifacts.

The workflow stores the original verified SRPM under `SOURCES/` in the cgit
repository before committing the imported dist-git state. Nexus remains the
artifact publication destination for build outputs.

## Netboot image pipeline — status

`image-build.yml` is scaffolded but **not yet runnable end to end**. It needs:

```text
ANSIBLE_CHECKOUT_TOKEN   read-only token/deploy key for dugeo/ansible
                          (access is restricted, not covered by any
                          existing secret in this repo)
ANSIBLE_SSH_PRIVATE_KEY  key for ansible-playbook to reach the target host
ANSIBLE_VAULT_PASSWORD   vault password for pwhash_root_compute etc.
```

None of these exist yet — deliberately deferred. See `docs/ARCHITECTURE.md`
for the full reasoning (why `ppxe0001` needs no separate publish step today,
what changes once an in-cluster PXE deployment exists, and the planned move
of the LDAP password into SOPS).
