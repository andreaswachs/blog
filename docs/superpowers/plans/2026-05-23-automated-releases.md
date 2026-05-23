# Automated Releases via Conventional Commits — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fully automate Docker image and Helm chart releases via conventional commits using semantic-release, chained across two GitHub Actions workflows.

**Architecture:** Two chained workflows — `image-release.yaml` triggers on push to main, runs semantic-release to compute the next version, builds/pushes the Docker image, scans with Trivy, then creates a GitHub Release. The release event triggers `chart-release.yaml` which packages and pushes the Helm chart with the new version. A third `pr-check.yaml` workflow enforces conventional commit format on PR titles.

**Tech Stack:** semantic-release (Node.js), GitHub Actions, Docker Buildx (multi-arch), Trivy, Helm, yq

**Design refinement:** The spec's `.releaserc.js` lists only `commit-analyzer` and `release-notes-generator`. However, semantic-release needs at least one plugin with a `publish` step for the action to report `new_release_published='true'`. Add `@semantic-release/exec` with a no-op `publishCmd` to satisfy this requirement.

---

### Task 1: Add Node.js package config and dependencies

**Files:**
- Create: `package.json`
- Create: `package-lock.json` (generated)
- Create: `commitlint.config.js`
- Create: `.nvmrc`
- Modify: `.gitignore`

- [ ] **Step 1: Add `node_modules/` to `.gitignore`**

Append to `.gitignore`:

```
node_modules/
```

- [ ] **Step 2: Write `package.json`**

```json
{
  "name": "blog",
  "private": true,
  "devDependencies": {
    "@commitlint/cli": "^19.8.0",
    "@commitlint/config-conventional": "^19.8.0",
    "@semantic-release/commit-analyzer": "^13.0.1",
    "@semantic-release/exec": "^7.0.3",
    "@semantic-release/release-notes-generator": "^14.0.3",
    "semantic-release": "^24.2.3"
  }
}
```

- [ ] **Step 3: Write `commitlint.config.js`**

```js
module.exports = {
  extends: ['@commitlint/config-conventional'],
};
```

- [ ] **Step 4: Write `.nvmrc`**

```
22
```

- [ ] **Step 5: Install dependencies to generate lockfile**

```bash
npm install
```

Expected: `package-lock.json` created, `node_modules/` populated.

- [ ] **Step 6: Verify commitlint works on a valid PR title**

```bash
echo "feat: add dark mode" | npx commitlint --verbose
```

Expected: PASS (exit code 0)

- [ ] **Step 7: Verify commitlint rejects an invalid PR title**

```bash
echo "added dark mode" | npx commitlint --verbose; echo "exit: $?"
```

Expected: FAIL (non-zero exit code)

- [ ] **Step 8: Commit**

```bash
git add package.json package-lock.json commitlint.config.js .nvmrc .gitignore
git commit -m "chore: add Node.js deps for semantic-release and commitlint"
```

---

### Task 2: Add PR check workflow

**Files:**
- Create: `.github/workflows/pr-check.yaml`

- [ ] **Step 1: Write `pr-check.yaml`**

```yaml
name: PR Check

on:
  pull_request:
    types: [opened, edited, synchronize, reopened]
    branches:
      - main

jobs:
  lint-pr-title:
    name: Lint PR title
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version-file: .nvmrc
          cache: npm

      - name: Install dependencies
        run: npm ci

      - name: Validate PR title
        run: echo "${{ github.event.pull_request.title }}" | npx commitlint
```

- [ ] **Step 2: Verify workflow YAML is valid**

```bash
npx --yes action-validator .github/workflows/pr-check.yaml 2>/dev/null || echo "action-validator not available, manually review YAML syntax"
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/pr-check.yaml
git commit -m "ci: add PR title conventional-commit validation"
```

---

### Task 3: Add semantic-release config

**Files:**
- Create: `.releaserc.js`

- [ ] **Step 1: Write `.releaserc.js`**

```js
module.exports = {
  branches: ['main'],
  plugins: [
    '@semantic-release/commit-analyzer',
    '@semantic-release/release-notes-generator',
    [
      '@semantic-release/exec',
      {
        publishCmd: 'echo "Version ${nextRelease.version} (${nextRelease.type})"',
      },
    ],
  ],
};
```

The `@semantic-release/exec` plugin with `publishCmd` is required so semantic-release has a publish step. Without it, `cycjimmy/semantic-release-action` would report `new_release_published='false'` even when commits warrant a release. The echo command is a no-op — the actual publishing (Docker push, GitHub Release) happens in the workflow itself.

- [ ] **Step 2: Commit**

```bash
git add .releaserc.js
git commit -m "chore: add semantic-release config"
```

---

### Task 4: Remove old release machinery

**Files:**
- Remove: `image.yaml`
- Remove: `.github/workflows/release.yaml`

- [ ] **Step 1: Remove old files**

```bash
git rm image.yaml .github/workflows/release.yaml
```

- [ ] **Step 2: Commit**

```bash
git commit -m "chore: remove manual release files, replaced by automated workflows"
```

---

### Task 5: Add image release workflow

**Files:**
- Create: `.github/workflows/image-release.yaml`

- [ ] **Step 1: Write `image-release.yaml`**

```yaml
name: Image Release

on:
  push:
    branches:
      - main
  workflow_dispatch:

jobs:
  release:
    name: Build and release image
    runs-on: ubuntu-latest
    permissions:
      contents: write
      packages: write
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version-file: .nvmrc
          cache: npm

      - name: Install dependencies
        run: npm ci

      - name: Run semantic-release
        id: semrel
        uses: cycjimmy/semantic-release-action@v4
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Set up QEMU
        if: steps.semrel.outputs.new_release_published == 'true'
        uses: docker/setup-qemu-action@v3

      - name: Set up Docker Buildx
        if: steps.semrel.outputs.new_release_published == 'true'
        uses: docker/setup-buildx-action@v3

      - name: Login to GitHub Container Registry
        if: steps.semrel.outputs.new_release_published == 'true'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push image
        if: steps.semrel.outputs.new_release_published == 'true'
        uses: docker/build-push-action@v6
        with:
          context: .
          file: Dockerfile
          platforms: linux/arm64,linux/amd64
          push: true
          load: false
          provenance: false
          tags: |
            ghcr.io/andreaswachs/blog:${{ steps.semrel.outputs.new_release_version }}
            ghcr.io/andreaswachs/blog:latest
          build-args: |
            BUILD_DATE=${{ github.event.repository.updated_at }}
            VCS_REF=${{ github.sha }}
            VERSION=${{ steps.semrel.outputs.new_release_version }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Run Trivy vulnerability scanner
        if: steps.semrel.outputs.new_release_published == 'true'
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ghcr.io/andreaswachs/blog:${{ steps.semrel.outputs.new_release_version }}
          format: table
          exit-code: '0'
          ignore-unfixed: true
          vuln-type: os,library
          severity: CRITICAL,HIGH
          output: trivy-results.txt

      - name: Upload Trivy scan results
        if: steps.semrel.outputs.new_release_published == 'true'
        uses: actions/upload-artifact@v4
        with:
          name: trivy-results-blog
          path: trivy-results.txt

      - name: Display Trivy results
        if: steps.semrel.outputs.new_release_published == 'true'
        run: |
          echo "## Trivy Scan Results for blog" >> $GITHUB_STEP_SUMMARY
          echo '```' >> $GITHUB_STEP_SUMMARY
          cat trivy-results.txt >> $GITHUB_STEP_SUMMARY
          echo '```' >> $GITHUB_STEP_SUMMARY

      - name: Create GitHub Release
        if: steps.semrel.outputs.new_release_published == 'true'
        run: |
          gh release create "v${{ steps.semrel.outputs.new_release_version }}" \
            --title "v${{ steps.semrel.outputs.new_release_version }}" \
            --generate-notes
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 2: Verify workflow YAML is valid**

```bash
npx --yes action-validator .github/workflows/image-release.yaml 2>/dev/null || echo "action-validator not available, manually review YAML syntax"
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/image-release.yaml
git commit -m "ci: add automated image release workflow"
```

---

### Task 6: Add chart release workflow

**Files:**
- Create: `.github/workflows/chart-release.yaml`

- [ ] **Step 1: Write `chart-release.yaml`**

```yaml
name: Chart Release

on:
  release:
    types:
      - published

jobs:
  release:
    name: Package and push chart
    runs-on: ubuntu-latest
    permissions:
      packages: write
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Get release version
        id: version
        run: |
          TAG="${{ github.event.release.tag_name }}"
          VERSION="${TAG#v}"
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"

      - name: Set up Helm
        uses: azure/setup-helm@v4
        with:
          version: v3.17.1

      - name: Install yq
        uses: mikefarah/yq@v4

      - name: Update Chart.yaml with release version
        run: |
          yq -i ".version = \"${{ steps.version.outputs.version }}\"" chart/Chart.yaml
          yq -i ".appVersion = \"${{ steps.version.outputs.version }}\"" chart/Chart.yaml

      - name: Package and push Helm chart
        run: |
          helm registry login ghcr.io -u ${{ github.actor }} -p ${{ secrets.GITHUB_TOKEN }}
          helm package chart/ --version "${{ steps.version.outputs.version }}"
          helm push "blog-${{ steps.version.outputs.version }}.tgz" oci://ghcr.io/andreaswachs/charts
```

- [ ] **Step 2: Verify workflow YAML is valid**

```bash
npx --yes action-validator .github/workflows/chart-release.yaml 2>/dev/null || echo "action-validator not available, manually review YAML syntax"
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/chart-release.yaml
git commit -m "ci: add automated chart release workflow"
```

---

### Task 7: Final verification

**Files:** None

- [ ] **Step 1: Verify all files exist and old files are removed**

```bash
echo "=== Files that should exist ==="
ls -la .github/workflows/image-release.yaml \
      .github/workflows/chart-release.yaml \
      .github/workflows/pr-check.yaml \
      .releaserc.js \
      package.json \
      commitlint.config.js \
      .nvmrc

echo ""
echo "=== Files that should NOT exist ==="
ls image.yaml 2>&1 && echo "ERROR: image.yaml still exists" || echo "OK: image.yaml removed"
ls .github/workflows/release.yaml 2>&1 && echo "ERROR: release.yaml still exists" || echo "OK: release.yaml removed"
```

- [ ] **Step 2: Verify commitlint still works after all changes**

```bash
echo "feat: add something" | npx commitlint --verbose
echo "exit: $?"
```

Expected: PASS (exit code 0)

- [ ] **Step 3: Verify chart/Chart.yaml is still valid Helm chart**

```bash
helm lint chart/
```

Expected: No errors (may warn about missing values like `.Values.gateway.sectionName`, which is fine).

- [ ] **Step 4: Review the commit log to ensure clean history**

```bash
git log --oneline -10
```

Expected: Tasks 1-6 commits visible, no WIP/squash-needed commits.
