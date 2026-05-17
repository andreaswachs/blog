# Blog Bootstrap — Design Spec

Date: 2026-05-17

## Overview

Bootstrap a Hugo-based personal blog repository with full containerization, a Helm chart for Kubernetes deployment (homelab), and CI/CD that builds and publishes both container image and Helm chart to GHCR.

## Repository Structure

```
blog/
  archetypes/              # Hugo archetypes
  assets/                  # Hugo assets
  content/                 # Blog posts (markdown)
  data/                    # Hugo data files
  layouts/                 # Theme overrides (empty initially)
  static/                  # Static files
  themes/                  # .gitignored, populated by Hugo Modules
  chart/                   # Helm chart
    Chart.yaml             # name: blog, version + appVersion
    values.yaml            # defaults: domain, gateway ref, image
    templates/
      deployment.yaml
      service.yaml
      httproute.yaml
  hugo.toml                # Hugo config + theme module
  image.yaml               # Container metadata source of truth
  Dockerfile               # Multi-stage: hugo build -> nginx:alpine
  compose.yaml             # Local dev: hugo server --watch on :1313
  Makefile                 # dev, build, clean targets
  .github/workflows/
    release.yaml           # Tag-driven: build image + helm -> GHCR
  .dockerignore
  .gitignore
```

## Architecture

```
git push (tag v*) -> GitHub Actions
  -> Build Hugo site
  -> Build multi-arch container image -> push to ghcr.io/andreaswachs/blog:<version>
  -> Package Helm chart -> push OCI to ghcr.io/andreaswachs/charts/blog:<version>
  -> Trivy scan

Separately: Flux (in homelab GitOps repo) pulls Helm chart from GHCR
  -> Deploys Deployment, Service, HTTPRoute to k3s cluster
  -> HTTPRoute attaches to existing Envoy Gateway
  -> TLS terminated at Gateway level
  -> Publicly accessible
```

## Image Tags

`image.yaml` is the canonical source of truth:

```yaml
name: blog
version: 0.1.0
registry: oci://ghcr.io/andreaswachs/blog
platforms: linux/arm64,linux/amd64
```

## Helm Chart

`chart/Chart.yaml`:

```yaml
apiVersion: v2
name: blog
version: 0.1.0
appVersion: 0.1.0
```

Pushes to `oci://ghcr.io/andreaswachs/charts/blog`.

### Helm Templates

- **Deployment**: 1 replica, image from values, probes on /
- **Service**: ClusterIP on port 8080
- **HTTPRoute**: Attaches to existing Gateway (configurable via values), routes Host header to Service

### Values

```yaml
image:
  repository: ghcr.io/andreaswachs/blog
  tag: 0.1.0
  pullPolicy: IfNotPresent

domain: blog.example.com

gateway:
  name: envoy-gateway
  namespace: envoy-gateway-system
```

## Hugo

- Theme: `janraasch/hugo-bearblog` via Hugo Modules
- Config: `hugo.toml` (baseURL, language, module declaration)
- Content: `content/posts/YYYY-MM-DD-slug.md`
- No custom theme overrides initially

## Dockerfile

Multi-stage:
1. `hugo:extended` — builds site to `/public`
2. `nginx:alpine` — copies `/public`, minimal nginx config, serves on 8080

## Local Dev

`compose.yaml`: mounts project into `hugo:extended`, runs `hugo server --bind 0.0.0.0 --port 1313 --buildDrafts`. Accessible at `http://localhost:1313`. Live reload.

Makefile targets: `dev` (compose up), `build` (docker build), `clean` (compose down).

## CI/CD

`.github/workflows/release.yaml` — mirrors cobbleverse structure:

| Job | Purpose |
|-----|---------|
| validate | Placeholder |
| build | Hugo build, multi-arch Docker build+push, Trivy scan, Helm package+push |
| summary | Release summary + scan results |

Triggers: push on `v*` tags, `workflow_dispatch`.

Build job steps:
1. Checkout
2. Set up Hugo CLI
3. Hugo build
4. QEMU + Buildx setup
5. GHCR login
6. Read image.yaml metadata
7. Docker build-push (multi-arch, provenance off)
8. Trivy vulnerability scan + artifact upload
9. Helm package + push to GHCR OCI

No Flux repo update — Flux handles GitOps independently.

## Versioning Workflow

1. Bump versions in `image.yaml` and `chart/Chart.yaml`
2. Tag commit: `git tag v0.1.0`
3. Push: `git push --tags`
4. CI builds and publishes both artifacts with matching version

## Exclusions

- No custom theme overrides (initially)
- No Flux repo manifest updates from CI
- No TLS cert handling (terminated at Gateway level outside this chart)
- No comments, analytics, or third-party scripts (Bear Blog theme is privacy-focused)
