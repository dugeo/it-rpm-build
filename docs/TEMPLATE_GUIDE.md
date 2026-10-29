# Using the `el9` build template

This guide is for adding a **new package** (or a new kernel pairing for an
existing package) to the pipeline using the existing `templates/el9/`
template. Read `docs/ARCHITECTURE.md` first if you haven't — it explains why
the pipeline is shaped this way.

## 1. What a template actually is

A template is a pair of files copied verbatim into the package's dist-git
checkout right before the build step:

```
templates/<name>/
  build.sh    — the mock build driver (parses --arch/--kernel, runs mock)
  mock.cfg    — the base mock chroot configuration
```

`templates/el9/` targets CentOS Stream/RHEL 9 and is currently the only
template. It's generic across *packages* but **one template directory per
distinct OS/kernel-ABI generation** — if you need to build against, say, an
EL8 target or a kernel so different that `build.sh`'s assumptions no longer
hold, copy `templates/el9/` to a new directory (e.g. `templates/el8/`) and
adjust rather than overloading `el9`.

## 2. Add a package manifest

Create `packages/<name>-<version>.yaml`:

```yaml
package: <short-name>          # e.g. lustre
repository: <short-name>       # dist-git repo name on cgit; defaults to package
source:
  url: <immutable upstream SRPM URL, pinned to an exact version>
  sha256: <SHA-256 of that exact file>
build:
  template: el9
  kernel: <kernel-version>     # omit entirely for a kernel-independent package
  rpm_repository_url: https://nexus.dug.com/repository/dug-el/9/dug/x86_64/
  mock_config: mock.cfg
  script: build.sh
publish:
  nexus_repository: rpm-hosted
```

**Always pin an exact, immutable upstream URL and verify its SHA-256
yourself before committing** (download it once, `sha256sum` it, compare
against the project's own published checksums page if one exists). The
workflow refuses to proceed if the downloaded file's digest doesn't match.

Validate the manifest locally before opening a PR:

```sh
python3 scripts/read-manifest.py packages/<name>-<version>.yaml
```

This prints the resolved environment variables the workflow will use
(`SRPM_URL`, `SRPM_SHA256`, `BUILD_TEMPLATE`, `KERNEL_VERSION`, etc.) — a
quick way to catch typos before CI does.

## 3. Kernel-specific builds — what `--kernel` actually does

If `build.kernel` is set, `build.sh`:

1. Adds a **second** legacy repo scoped to that exact kernel build:
   `https://nexus.dug.com/repository/dug-el/kernel-<version>/dug/x86_64/`
   (derived automatically from `rpm_repository_url`'s `dug-el/` prefix —
   you don't need to spell this out in the manifest).
2. Installs `kernel-devel-<version>` and `kernel-headers-<version>` into the
   chroot from that repo.
3. Creates the `/lib/modules/<kernel>.<arch>/{source,build}` symlinks that
   `kernel-devel` doesn't provide on its own (see ARCHITECTURE.md point 7).
4. Defines the `kver` RPM macro mock passes through
   (`--define 'kver <kernel>.<arch>'`), which most kernel-module specs read
   via `%{kver}` to pick the right `/lib/modules` path.

If your package doesn't build kernel modules, just omit `build.kernel`
entirely — `build.sh` skips all of the above.

### Per-kernel Nexus repository naming

The legacy build-dependency Nexus repo for a specific kernel build **must**
exist at:

```
https://nexus.dug.com/repository/dug-el/kernel-<kernel-version>/dug/x86_64/
```

i.e. the directory name is `kernel-<version>`, not bare `<version>`. This is
handled automatically by `build.sh` — you never type this URL yourself in
the manifest, only the generic `rpm_repository_url`. If a new kernel's
packages aren't resolvable, check that this Nexus repo exists with that
exact naming convention before debugging anything else.

## 4. Client-vs-server / `--without` flags

If the upstream project ships separable client/server (or similarly split)
RPM subsets and your manifest's SRPM URL points at the client-only variant,
check whether its spec needs an explicit `--without <feature>` the way
Lustre does (see ARCHITECTURE.md point 10). This is currently hardcoded in
`templates/el9/build.sh`'s final `mock --rebuild` invocation
(`--rpmbuild-opts="--without servers"`). If you add a second package that
needs a *different* set of `--without`/`--with` flags, **do not hardcode a
second condition into the shared `build.sh`** — instead add a manifest field
(e.g. `build.rpmbuild_opts`) that `read-manifest.py` passes through as an
env var, and have `build.sh` consume it generically. This keeps the
template package-agnostic.

## 5. Running the pipeline

- **Automatic**: push to `main` with changes under `packages/`,
  `templates/`, `scripts/`, or `Containerfile` runs the `build` job against
  the manifest configured as the workflow's default
  (`.github/workflows/rpm-build.yml`'s `inputs.manifest` default — update
  this when adding a package you want to be the main one built on push).
- **Manual, any manifest**: GitHub Actions → "RPM manifest build and
  publish" → Run workflow → set `manifest` to
  `packages/<name>-<version>.yaml`.
- **Pull requests**: only the `validate` job runs (schema + script checks,
  no cluster credentials, no build) — safe for untrusted contributions.

## 6. Verifying a successful run

1. Check the job completed (`gh run view <id> --json conclusion`).
2. Confirm the dist-git repo got the commit: `cgit.devops.svc.cluster.local`
   → `<repository>.git`, latest commit `Import <name>-<version>-<release>`.
3. Confirm Nexus actually received every RPM, not just the SRPM — this bit
   the pipeline once (ARCHITECTURE.md point 12) and the failure mode is
   silent (job succeeds, artifacts are simply missing). Query Nexus
   directly rather than trusting the workflow's own success:

   ```sh
   curl -s -u "$NEXUS_USERNAME:$NEXUS_PASSWORD" \
     "https://nexus.kube.dug.com/service/rest/v1/search?repository=rpm-hosted&name=<name>" \
     | jq '.items[].assets[].path'
   ```

   You should see the `.src.rpm` **and** every binary `.rpm` the spec
   produces (kernel-module `kmod-*`, userspace package, `-devel`, `-debuginfo`,
   etc. — however many subpackages the spec defines).

## 7. Rebuilding the `rpm-build` builder image

The builder image (`registry.kube.dug.com/rpm-build:<tag>`) is **not**
Flux-managed or rebuilt by CI automatically — it's a manually-triggered
Kaniko `Job`, same pattern as cgit's image build
(`dugeo/it-k8s`'s `kubernetes/apps/devops/cgit/app/image-build-job.yaml`).

Rebuild it whenever you change the `Containerfile`, `templates/`, or need to
pick up new base-image package updates:

1. Bump the tag in both the `Job`'s `--destination` and in
   `.github/workflows/rpm-build.yml`'s two `container.image:` references
   (`validate` and `build` jobs — keep them in sync).
2. Push a `ConfigMap` with the build context (`Containerfile`,
   `dugca-bundle.pem`, `templates/`) into the `devops` namespace, run a
   Kaniko `Job` against it pushing to the new tag, confirm it reaches
   `Pushed <image>@sha256:...` in its logs.
3. Commit the tag bump in this repo. The next workflow run picks up the new
   image.

(A one-off helper manifest for this exists in
`/opt/data/cache/scratch/rpm-build-image-build-job.yaml` from the 0.1.1
rebuild — reuse its shape rather than writing one from scratch.)

## 8. Known hard constraints — don't fight these

- `mock` requires `--privileged`. This only works via the ARC hook
  extension (`dugeo/it-k8s`'s `rpm-build-hook-extension.yaml`) — do not try
  to set it via the workflow's `container: options:`, it's silently
  ignored under `containerMode: kubernetes`.
- `rpkg --release` must be `rhel-<N>`, never `elN`.
- Lustre (and likely other kernel-module packages) needs a version that
  actually matches the target kernel's VFS ABI — a nominal kernel-version
  match is not sufficient; verify an actual `configure`+`make` pass before
  assuming a version/kernel pairing works.
