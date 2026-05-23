# Automated Releases via Conventional Commits

## Summary

Refactor the release pipeline from manual version bumps in `image.yaml` and `chart/Chart.yaml` to fully automated semantic versioning driven by conventional commits. Image and chart share the same version number, and releases are split across two chained workflows.

## Motivation

- Manual version management in `image.yaml` and `chart/Chart.yaml` is error-prone (chart already drifted to 0.1.4 while image is at 0.1.2)
- No git tags are created, making it hard to track what version is deployed
- Want to be forced to use conventional commits (enforces good changelog hygiene)

## Design

### File changes

| Action | Path | Notes |
|--------|------|-------|
| Remove | `image.yaml` | Version, image name, registry, and platforms are now hardcoded in the workflow or derived from semantic-release output |
| Remove | `.github/workflows/release.yaml` | Replaced by two focused workflows |
| Add | `.github/workflows/image-release.yaml` | Image build + GitHub Release on push to main |
| Add | `.github/workflows/chart-release.yaml` | Chart package + push, triggered by image release |
| Add | `.github/workflows/pr-check.yaml` | Commitlint validation on PR titles |
| Add | `.releaserc.js` | semantic-release config (commit analysis only) |
| Add | `package.json` | Dev dependency for semantic-release |
| Modify | `chart/Chart.yaml` | `version` and `appVersion` set dynamically during chart release |

### Workflow: image-release.yaml

**Trigger:** `push` to `main` branch, `workflow_dispatch`

**Steps:**

1. **Checkout** — `fetch-depth: 0` (semantic-release needs full git history)
2. **Setup Node.js + npm ci** — install semantic-release packages
3. **Run semantic-release** via `cycjimmy/semantic-release-action@v4` — computes next version, outputs `new_release_published` (boolean) and `new_release_version` (string)
4. **Setup QEMU, Buildx, GHCR login** — same as current workflow
5. **Build and push Docker image** (conditional: `new_release_published == 'true'`)
   - Platform: `linux/arm64,linux/amd64`
   - Tags: `ghcr.io/andreaswachs/blog:X.Y.Z`, `ghcr.io/andreaswachs/blog:latest`
   - Build args: `BUILD_DATE`, `VCS_REF`, `VERSION`
   - Cache: gha type
6. **Trivy vulnerability scan** — same as current workflow
   - Severity: CRITICAL,HIGH
   - Exit code: 0 (non-blocking)
   - Upload artifact and post to step summary
7. **Create GitHub Release** — `gh release create vX.Y.Z --generate-notes`
   - This event triggers `chart-release.yaml`

### Workflow: chart-release.yaml

**Trigger:** `release: published` event (GitHub Release created by image workflow)

**Steps:**

1. **Checkout** — repository source
2. **Get release version** — read `github.event.release.tag_name`, strip `v` prefix
3. **Update Chart.yaml** — set `version` and `appVersion` to the release version via `yq`
4. **Helm login + package + push** — same as current workflow
   - Chart pushed to `oci://ghcr.io/andreaswachs/charts/blog:X.Y.Z`

### Workflow: pr-check.yaml

**Trigger:** `pull_request` opened/synchronized targeting `main`

**Steps:**

1. **Checkout**
2. **Run commitlint** — validates PR title follows conventional-commits format
   - Requires `@commitlint/config-conventional`
   - Blocks merge if PR title is non-conforming

Note: Squash-merging is assumed — the PR title becomes the commit message on main.

### `.releaserc.js`

```js
module.exports = {
  branches: ['main'],
  plugins: [
    '@semantic-release/commit-analyzer',
    '@semantic-release/release-notes-generator',
  ],
};
```

Minimal config — only commit analysis and release notes generation. Git tagging and GitHub Release creation are handled explicitly in the workflow to control ordering (image must be pushed and scanned before the release is created).

### Hardcoded values (replacing `image.yaml`)

The following values from `image.yaml` become workflow constants (they don't change between releases):

- Image name: `blog`
- Image registry: `ghcr.io/andreaswachs/blog`
- Platforms: `linux/arm64,linux/amd64`
- Chart registry: `oci://ghcr.io/andreaswachs/charts/blog`

### `package.json`

Minimal — exists only to provide the Node.js project context for semantic-release dependencies. No build scripts, no runtime code. Contains:

- `devDependencies`: `@semantic-release/commit-analyzer`, `@semantic-release/release-notes-generator`, `semantic-release`, `@commitlint/config-conventional`, `@commitlint/cli`

## Edge cases

### No release-worthy commits on main

`semantic-release` outputs `new_release_published='false'`. Image build and all subsequent steps are skipped. Nothing happens.

### Non-conventional commits on main

The `commit-analyzer` plugin ignores commits without `feat:`, `fix:`, or `BREAKING CHANGE:` in the message. No version bump, no release. PR title enforcement is the primary gate; this is a safety net.

### Image build succeeds, chart push fails

The GitHub Release is already created and the image is published. The chart workflow fails atomically (packaging + push in one step).
The user gets a GitHub Actions failure notification. Re-running the chart workflow will retry the chart release.

### First release version

Since no prior git tags exist, semantic-release's `commit-analyzer` defaults to a first release of `1.0.0`. This is intentional — the blog is live and functional at `wachs.software`, so `1.0.0` is an appropriate signal of maturity. The previous `0.1.x` versions are pre-automation artifacts.

### Existing version drift (chart 0.1.4 vs image 0.1.2)

Obsolete. Both image and chart will start fresh at the new computed version (likely `1.0.0`).

### Multiple commits pushed simultaneously

semantic-release analyzes all commits since the last git tag and computes the highest applicable bump (e.g., one `feat:` + two `fix:` → minor bump).

## Semantic version bump mapping

| Commit message | Bump |
|---------------|------|
| `fix: ...` | Patch (0.1.X → 0.1.X+1) |
| `feat: ...` | Minor (0.X.0 → 0.X+1.0) |
| `feat!: ...` or `BREAKING CHANGE:` in footer | Major (X.0.0 → X+1.0.0) |
| `chore:`, `docs:`, `style:`, `refactor:`, `test:`, `ci:` | No bump (no release) |
