# using the el9 build template

guide for adding a new package (or new kernel pairing) using the existing
`templates/el9/` template. read ARCHITECTURE.md first if you haven't, it
explains why the pipeline looks the way it does.

## what a template actually is

just two files copied into the package's dist-git checkout right before the
build step:

```
templates/<name>/
  build.sh    — mock build driver, parses --arch/--kernel, runs mock
  mock.cfg    — base mock chroot config
```

`templates/el9/` targets CentOS Stream/RHEL 9, it's the only one we've got.
generic across packages but one template dir per OS/kernel-ABI generation —
if you need EL8 or a kernel different enough that build.sh's assumptions
break, copy el9 to a new dir and adjust, don't overload el9.

## add a package manifest

create `packages/<name>-<version>.yaml`:

```yaml
package: <short-name>          # e.g. lustre
repository: <short-name>       # dist-git repo name on cgit, defaults to package
source:
  url: <immutable upstream SRPM URL, pinned to an exact version>
  sha256: <SHA-256 of that exact file>
build:
  template: el9
  kernel: <kernel-version>     # omit if package doesn't need a kernel
  rpm_repository_url: https://nexus.dug.com/repository/dug-el/9/dug/x86_64/
  mock_config: mock.cfg
  script: build.sh
publish:
  nexus_repository: rpm-hosted
```

always pin an exact immutable URL and check the SHA-256 yourself before
committing (download it, sha256sum it, compare against the project's own
published checksums if they have one). the workflow refuses to continue if
the digest doesn't match.

validate locally before opening a PR:

```sh
python3 scripts/read-manifest.py packages/<name>-<version>.yaml
```

prints the env vars the workflow will actually use (SRPM_URL, SRPM_SHA256,
BUILD_TEMPLATE, KERNEL_VERSION, etc) — catches typos before CI does.

## kernel-specific builds — what `--kernel` actually does

if `build.kernel` is set, build.sh:

1. adds a second legacy repo scoped to that exact kernel:
   `https://nexus.dug.com/repository/dug-el/kernel-<version>/dug/x86_64/`
   (derived from `rpm_repository_url`'s `dug-el/` prefix, you don't write
   this URL yourself)
2. installs `kernel-devel-<version>` and `kernel-headers-<version>` from it
3. creates `/lib/modules/<kernel>.<arch>/{source,build}` symlinks that
   kernel-devel doesn't provide (see ARCHITECTURE.md point 7)
4. defines the `kver` macro mock passes through
   (`--define 'kver <kernel>.<arch>'`) — most kernel-module specs read this
   via `%{kver}` for the `/lib/modules` path

if your package doesn't build kernel modules just skip `build.kernel`
entirely, build.sh skips all of the above.

### per-kernel Nexus repo naming

the legacy build-dep repo for a specific kernel has to exist at:

```
https://nexus.dug.com/repository/dug-el/kernel-<kernel-version>/dug/x86_64/
```

directory name is `kernel-<version>`, not bare `<version>`. build.sh builds
this automatically, you only ever type the generic `rpm_repository_url` in
the manifest. if a new kernel's packages don't resolve, check this repo
exists with the right naming before you go debug anything else.

## client vs server / `--without` flags

if upstream ships separable client/server subsets and your SRPM is the
client-only variant, check if the spec needs `--without <feature>` like
Lustre does (ARCHITECTURE.md point 10). currently hardcoded into
`templates/el9/build.sh`'s final mock call
(`--rpmbuild-opts="--without servers"`). if you add a package that needs a
different set of flags, don't hardcode a second condition into the shared
build.sh — add a manifest field instead (e.g. `build.rpmbuild_opts`), have
read-manifest.py pass it through as an env var, build.sh consumes it
generically. keeps the template package-agnostic.

## running the pipeline

- **automatic**: push to main touching `packages/`, `templates/`,
  `scripts/`, or `Containerfile` runs the build job against whatever
  manifest is the workflow's default (`.github/workflows/rpm-build.yml`'s
  `inputs.manifest` default — update this when a new package should be the
  main one built on push)
- **manual, any manifest**: GitHub Actions → "RPM manifest build and
  publish" → Run workflow → set `manifest` to `packages/<name>-<version>.yaml`
- **PRs**: only `validate` runs (schema/script check, no cluster creds, no
  build) — safe for untrusted contributions

## verifying a run actually worked

1. check the job's actually green (`gh run view <id> --json conclusion`)
2. check dist-git got the commit: `cgit.devops.svc.cluster.local` →
   `<repository>.git`, latest commit `Import <name>-<version>-<release>`
3. check Nexus actually has every RPM, not just the SRPM — this bit us once
   (ARCHITECTURE.md point 12) and it fails silently, job goes green but
   artifacts are just missing. don't trust the workflow, query Nexus
   directly:

   ```sh
   curl -s -u "$NEXUS_USERNAME:$NEXUS_PASSWORD" \
     "https://nexus.kube.dug.com/service/rest/v1/search?repository=rpm-hosted&name=<name>" \
     | jq '.items[].assets[].path'
   ```

   should show the `.src.rpm` AND every binary rpm the spec produces
   (kmod-*, userspace package, -devel, -debuginfo, however many subpackages)

## rebuilding the rpm-build builder image

the builder image (`registry.kube.dug.com/rpm-build:<tag>`) is NOT
Flux-managed, not auto-rebuilt by CI — it's a manual Kaniko Job, same
pattern as cgit's image build
(`dugeo/it-k8s`'s `kubernetes/apps/devops/cgit/app/image-build-job.yaml`).

rebuild whenever you touch the Containerfile, templates, or need base-image
updates:

1. bump the tag in both the Job's `--destination` and
   `.github/workflows/rpm-build.yml`'s two `container.image:` lines
   (validate + build jobs, keep them in sync)
2. push a ConfigMap with the build context (Containerfile, dugca-bundle.pem,
   templates/) into `devops`, run a Kaniko Job against it pushing the new
   tag, confirm it hits `Pushed <image>@sha256:...` in the logs
3. commit the tag bump in this repo, next workflow run picks up the new
   image

(there's a one-off helper manifest from the 0.1.1 rebuild at
`/opt/data/cache/scratch/rpm-build-image-build-job.yaml` — reuse its shape
instead of writing one from scratch)

## hard constraints, don't fight these

- mock needs `--privileged`, only works via the ARC hook extension
  (`dugeo/it-k8s`'s `rpm-build-hook-extension.yaml`). don't try the
  workflow's `container: options:`, it's ignored under kubernetes mode
- `rpkg --release` must be `rhel-<N>`, never `elN`
- Lustre (and probably other kernel-module packages) needs a version that
  actually matches the kernel's VFS ABI — matching version numbers isn't
  enough, verify an actual configure+make pass before assuming a
  version/kernel pairing works
