---
title: "Secrets in Kubernetes: sourcing and distribution with 1password and external-secrets"
date: 2026-05-17
draft: false
---

# Managing Secrets with 1Password and External Secrets

This guide walks through setting up automated secret management in Kubernetes using [1Password Connect](https://developer.1password.com/docs/connect/) and the [External Secrets Operator](https://external-secrets.io/). Once configured, you can define `ExternalSecret` resources that reference items in your 1Password vault — the operator syncs them into native Kubernetes [Secrets](https://kubernetes.io/docs/concepts/configuration/secret/) automatically.

## Foreword

This post has been adapted from [this](https://rcwz.pl/2025-10-13-managing-secrets-with-1password-and-external-secrets/) source post by [Artur Rychlewicz](https://www.linkedin.com/in/artur-rychlewicz/). I am very grateful for the post but had to adapt the contents for my own homelab setup. Steps to get the 1password operator and external-secrets to play together has been adapted from the source post.

## Overview

The setup involves two components deployed into your Kubernetes cluster:

- **1Password Connect** — An in-cluster bridge that syncs secrets from your 1Password account and exposes them via a REST API. It runs two containers: `connect-api` (the HTTP server) and `connect-sync` (a background process that keeps local state in sync with 1Password). See the [Connect architecture docs](https://developer.1password.com/docs/connect/architecture/) for details.
- **External Secrets Operator (ESO)** — Watches `ExternalSecret` and `ClusterSecretStore` [Custom Resources](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/), fetches secrets from providers like 1Password Connect, and creates corresponding Kubernetes `Secret` objects. See the [ESO API overview](https://external-secrets.io/latest/api/).

The data flow: you define an `ExternalSecret` → it references a `ClusterSecretStore` → the store points ESO at your 1Password Connect server → Connect fetches from your 1Password vault → ESO creates/updates a Kubernetes `Secret`.

## Prerequisites

- **A running Kubernetes cluster** — This guide assumes you already have a cluster. If you're setting up a homelab, options include [k3s](https://k3s.io/), [k3d](https://k3d.io/) (k3s in Docker for local dev), [Talos](https://www.talos.dev/), or [microk8s](https://microk8s.io/).
- **`kubectl`** [installed](https://kubernetes.io/docs/tasks/tools/) and configured to access your cluster (`kubectl cluster-info` should succeed).
- **[Helm](https://helm.sh/)** v3+ [installed](https://helm.sh/docs/intro/install/).
- **A 1Password account** with the [`op` CLI](https://developer.1password.com/docs/cli/get-started/) installed and authenticated.
- **Administrator access** to your 1Password account (needed to create Connect servers and access tokens).

### Pre-flight checks

Before starting, verify your environment is ready:

```sh
kubectl cluster-info
```

```sh
helm version --short
```

```sh
op whoami
```

The `op whoami` output should show your account details. If you're not signed in, use `op signin` (or `eval $(op signin)` ) first — see the [1Password CLI sign-in docs](https://developer.1password.com/docs/cli/sign-in-manually/).

## Step 1: Deploy 1Password Connect

### 1.1 Create the namespace

Namespaces isolate workloads in Kubernetes. We place 1Password Connect in its own namespace for clean separation:

```sh
kubectl create namespace 1password
```

### 1.2 Generate Connect server credentials

A "Connect server" is a logical entity in 1Password that represents your in-cluster deployment. Creating one generates an encrypted credentials file that the Connect pod uses to authenticate with 1Password.

Run the following, replacing `<your-server-name>` with a descriptive name for your server (e.g. `homelab-connect`) and `<your-vault>` with the name of the vault whose secrets you want to sync:

```sh
op connect server create <your-server-name> --vaults <your-vault>
```

This command does two things:
1.  **Creates a 1Password item** in `<your-vault>` named after your server. This item stores the Connect server's credentials.
2.  **Writes a file** named `1password-credentials.json` to your current working directory.

> [!NOTE]
> If `--vaults` doesn't resolve by name, use the vault UUID instead (find it with `op vault list`).

After creating the server, confirm the 1Password item was created (the item name should match `<your-server-name>`):

```sh
op item list --vault <your-vault> | grep <your-server-name>
```

Store the credentials as a Kubernetes Secret in the `1password` namespace. Use `op read` to retrieve the credentials directly from the 1Password item (this avoids keeping the file on disk):

```sh
kubectl create secret generic 1password-credentials \
  --from-literal=1password-credentials.json="$(op read "op://<your-vault>/<your-server-name>/1password-credentials.json")" \
  -n 1password
```

> [!NOTE]
> `op read` fetches the value of the `1password-credentials.json` field from the Connect server item in your vault. The output is piped into `kubectl create secret`, which creates a Kubernetes Secret named `1password-credentials` with a single key (`1password-credentials.json`) holding the credentials. The secret is created in the `1password` namespace (`-n 1password`).

Verify the secret was created:

```sh
kubectl get secret 1password-credentials -n 1password
```

The output should list the secret with `TYPE: Opaque` and `DATA: 1`.

### 1.3 Install the Helm chart

Add the 1Password Helm repository and install the Connect chart. The Helm chart deploys the Connect pod (with both `connect-api` and `connect-sync` containers):

```sh
helm repo add 1password https://1password.github.io/connect-helm-charts/
```

```sh
helm repo update
```

```sh
helm upgrade --install 1password 1password/connect \
  --namespace 1password \
  --set connect.credentialsName=1password-credentials \
  --set acceptanceTests.enabled=false \
  --set acceptanceTests.healthCheck.enabled=false
```

Explanation of the flags:

| Flag | Purpose |
|---|---|
| `connect.credentialsName` | Tells the chart which Kubernetes Secret contains the `1password-credentials.json` file. This must match the secret name from step 1.2. |
| `acceptanceTests.enabled` | Disables post-install test pods (unnecessary for our setup). |
| `acceptanceTests.healthCheck.enabled` | Disables a health check test pod. |

### 1.4 Verify Connect is running

```sh
kubectl get pods -n 1password
```

You should see one pod with `2/2` in the `READY` column, indicating both containers (`connect-api` and `connect-sync`) are running. The pod name follows the pattern `1password-connect-<hash>`.

Check the sync container logs to confirm successful connection to 1Password:

```sh
kubectl logs -n 1password deploy/1password-connect -c connect-sync
```

Look for log lines indicating that the initial vault sync completed successfully — typically a message like `"sync complete"` or similar. If you see connection errors, verify your credentials secret is correct (see [Troubleshooting](#troubleshooting)).

## Step 2: Install External Secrets Operator

### 2.1 Create the namespace

```sh
kubectl create namespace external-secrets
```

### 2.2 Install the Helm chart

```sh
helm repo add external-secrets https://charts.external-secrets.io
```

```sh
helm repo update
```

```sh
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --set installCRDs=true
```

The `installCRDs=true` flag ensures the [CustomResourceDefinitions](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/#customresourcedefinitions) for `ExternalSecret`, `ClusterSecretStore`, `SecretStore`, and other ESO resource types are installed alongside the operator. Without these CRDs, your cluster won't recognize the YAML manifests in later steps.

For full installation options, see the [ESO Helm chart docs](https://external-secrets.io/latest/introduction/getting-started/#installing-with-helm).

### 2.3 Verify ESO is running

```sh
kubectl get pods -n external-secrets
```

Expect a pod named `external-secrets-<hash>` with `1/1 Ready`. Also confirm the CRDs were installed:

```sh
kubectl get crd | grep external-secrets.io
```

## Step 3: Create a Connect Access Token for ESO

External Secrets Operator needs its own access token to authenticate against the 1Password Connect server. This is a separate credential from the Connect server credentials created in Step 1.

### 3.1 Generate the token

Run the following, using the same `<your-server-name>` and `<your-vault>` from Step 1:

```sh
op connect token create kubernetes --server <your-server-name> --vault <your-vault>
```

This command outputs a long JWT token string to your terminal. The token:
- Is scoped to the named Connect server and vault(s).
- Is named `kubernetes` — this is a label that appears in 1Password's UI for identifying the token's purpose.
- **Cannot be retrieved again** after this command finishes. You must capture it now.

### 3.2 Save the token to 1Password (optional but recommended)

To avoid losing the token, save it as a 1Password item. The simplest approach is to create a new Password item in the 1Password desktop or web app:

1. Open the 1Password app and navigate to `<your-vault>`.
2. Create a new item of type **Password**, titled **Kubernetes Connect Token**.
3. Paste the JWT token from 3.1 into the **password** field.
4. Save the item.

Once saved, you can retrieve the token at any time with `op read`:

```sh
op read "op://<your-vault>/Kubernetes Connect Token/password"
```

> [!TIP]
> If you prefer creating the item via the command line:
> ```sh
> # Capture token from step 3.1 (if still in terminal scrollback) or paste it:
> TOKEN="paste-your-jwt-here"
>
> # Create a Password item with the token stored in the password field:
> op item create \
>   --category Password \
>   --title "Kubernetes Connect Token" \
>   --vault <your-vault> \
>   "password=$TOKEN"
> ```
> The exact syntax for `op item create` varies between CLI versions — the `"password=..."` field assignment format works with `op` v2. If it errors, fall back to the GUI method above.

> [!TIP]
> If you prefer, you can skip saving to 1Password altogether and pipe the token directly to `kubectl` in the next step. The save-to-1Password approach gives you a backup if the Kubernetes Secret is ever accidentally deleted.

### 3.3 Create the Kubernetes Secret

Storing the token in your cluster as a Secret lets the `ClusterSecretStore` reference it without hardcoding credentials in YAML files:

```sh
kubectl create secret generic 1password-kubernetes-token \
  --from-literal=token="$(op read "op://<your-vault>/Kubernetes Connect Token/password")" \
  -n 1password
```

Or, if you still have the token in your clipboard and want to enter it manually:

```sh
kubectl create secret generic 1password-kubernetes-token \
  --from-literal=token='<paste-the-token-here>' \
  -n 1password
```

> [!IMPORTANT]
> The secret is created in the `1password` namespace. The `ClusterSecretStore` in the next step will reference it by name and namespace, so it must exist in this exact namespace.

### 3.4 Verify the token secret

```sh
kubectl get secret 1password-kubernetes-token -n 1password
```

## Step 4: Create a ClusterSecretStore

The `ClusterSecretStore` tells External Secrets Operator how to reach your 1Password Connect server, which vault(s) to read from, and which credentials to use for authentication. Because it's a `ClusterSecretStore` (not a namespaced `SecretStore`), any `ExternalSecret` in any namespace can reference it.

Save the following as `homelab-cluster-secret-store.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: homelab
spec:
  provider:
    onepassword:
      connectHost: http://1password-connect.1password.svc.cluster.local:8080
      vaults:
        <your-vault>: 1
      auth:
        secretRef:
          connectTokenSecretRef:
            name: 1password-kubernetes-token
            namespace: 1password
            key: token
```

Key fields explained:

| Field | Purpose |
|---|---|
| `connectHost` | The internal Kubernetes DNS name for the Connect service. The pattern is `<release>-<chart>.<namespace>.svc.cluster.local`. Since we installed the Helm chart with release name `1password` and chart name `connect`, the service resolves to `1password-connect.1password.svc.cluster.local`. Port `8080` is the default for the Connect API. See [Kubernetes DNS for Services](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/). |
| `vaults` | Maps 1Password vault names (or UUIDs) to a numeric priority. `1` is the default priority. Replace `<your-vault>` with your actual vault name. |
| `auth.secretRef.connectTokenSecretRef` | Points to the Kubernetes Secret containing the Connect access token (created in Step 3.3). |

Apply it:

```sh
kubectl apply -f homelab-cluster-secret-store.yaml
```

### Verify

```sh
kubectl get clustersecretstore homelab
```

The output should show `STATUS: Valid` and `READY: True`. If `STATUS` is not `Valid`, check with:

```sh
kubectl describe clustersecretstore homelab
```

Look at the `Status` section in the output for error messages — common causes include a wrong `connectHost` URL or an invalid access token.

> [!NOTE]
> For troubleshooting, see the [ESO Status Specification](https://external-secrets.io/latest/api/store-status/) for how to interpret store status conditions.

## Step 5: Creating ExternalSecrets

With the `ClusterSecretStore` in place, you can create `ExternalSecret` resources to sync individual secrets from 1Password into Kubernetes `Secret` objects. The operator polls 1Password at the configured `refreshInterval` and updates the Kubernetes Secret whenever the source changes.

### Simple example: a secret with a single field

This syncs the `myNote` field from a 1Password item named `test`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: yabadaba
spec:
  refreshInterval: "5m"
  secretStoreRef:
    kind: ClusterSecretStore
    name: homelab
  target:
    name: yabadaba
    creationPolicy: Owner
  data:
    - secretKey: my-secret-note
      remoteRef:
        key: test
        property: myNote
```

Key fields:

| Field | Purpose |
|---|---|
| `refreshInterval` | How often ESO checks 1Password for changes. The default `5m` is reasonable for most secrets. |
| `secretStoreRef` | References the `ClusterSecretStore` from Step 4. |
| `target.name` | The name of the Kubernetes `Secret` that ESO will create. |
| `target.creationPolicy: Owner` | ESO "owns" the Secret — if you delete the `ExternalSecret`, ESO will also delete the Kubernetes Secret. The alternative `Orphan` leaves the Secret behind. |
| `data[].secretKey` | The key inside the resulting Kubernetes Secret. |
| `data[].remoteRef.key` | The name of the 1Password item. |
| `data[].remoteRef.property` | The field within the 1Password item. See the [mapping table](#how-secrets-map-to-1password) below. |

Apply it:

```sh
kubectl apply -f external-secret-example.yaml
```

### Multi-property example

To sync multiple fields from a single 1Password item (e.g., API credentials with a key, secret, and consumer key), define multiple `data` entries. Each entry maps one 1Password field to one key in the resulting Kubernetes Secret:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ovh-dns-credentials
spec:
  refreshInterval: "5m"
  secretStoreRef:
    kind: ClusterSecretStore
    name: homelab
  target:
    name: ovh-dns-credentials
    creationPolicy: Owner
  data:
    - secretKey: ovh_application_key
      remoteRef:
        key: ovh-external-dns
        property: app_key
    - secretKey: ovh_application_secret
      remoteRef:
        key: ovh-external-dns
        property: app_secret
    - secretKey: ovh_consumer_key
      remoteRef:
        key: ovh-external-dns
        property: consumer_key
```

The resulting Kubernetes Secret will have three data keys (`ovh_application_key`, `ovh_application_secret`, `ovh_consumer_key`), each mapped to the corresponding 1Password field.

### Namespaced example

For secrets tied to a specific namespace, include the `namespace` in the `metadata`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: github-webhook-token
  namespace: flux-system
spec:
  refreshInterval: 5m
  secretStoreRef:
    kind: ClusterSecretStore
    name: homelab
  target:
    name: github-webhook-token
    creationPolicy: Owner
  data:
    - secretKey: token
      remoteRef:
        key: flux-github-webhook
        property: token
```

### Verify

List all ExternalSecrets across all namespaces:

```sh
kubectl get externalsecret -A
```

Each ExternalSecret should show `STATUS: SecretSynced` and `READY: True`. If `STATUS` is not `SecretSynced`, inspect the resource:

```sh
kubectl describe externalsecret <name> -n <namespace>
```

To confirm the resulting Kubernetes Secret was created and is managed by ESO:

```sh
kubectl get secret yabadaba -o yaml
```

Verify it has the label `reconcile.external-secrets.io/managed: "true"`, which indicates ESO is actively managing this Secret.

For full ExternalSecret API reference, see the [ESO ExternalSecret spec](https://external-secrets.io/latest/api/externalsecret/).

## How Secrets Map to 1Password

The `key` in the `remoteRef` corresponds to the 1Password item name. The `property` corresponds to a field on that item. Property names are lowercased with underscores:

| 1Password field type | `remoteRef.property` |
|---|---|
| Password field | `password` |
| Username field | `username` |
| A custom field labeled "API Key" | `api_key` |
| A custom field labeled "Consumer Key" | `consumer_key` |
| Notes (plain text) | `notesPlain` |
| Attached file "config.xml" | `config.xml` |

For files attached to a 1Password item, use the filename (without path) as the property. See the [1Password provider docs](https://external-secrets.io/latest/provider/1password/) for all supported field types.

## Summary

At this point you have:

- **1Password Connect** running in-cluster, syncing your vault items
- **External Secrets Operator** creating and maintaining Kubernetes Secrets from those vault items
- A **ClusterSecretStore** connecting the two, usable by any namespace

You can now create `ExternalSecret` resources for any application that needs secrets — API keys, certificates, tokens, configuration files — and they will be automatically synced from 1Password.

## Troubleshooting

### Connect pod fails to start (CrashLoopBackOff or Error)

Check the sync container logs:

```sh
kubectl logs -n 1password deploy/1password-connect -c connect-sync --tail=50
```

Common causes:
- **Invalid credentials**: The `1password-credentials.json` in the Kubernetes Secret is malformed or empty. Re-run the `kubectl create secret` command in Step 1.2.
- **Wrong vault name**: The Connect server was created with a vault that doesn't exist or the name doesn't match. Verify with `op vault list`.
- **Network connectivity**: The pod cannot reach 1Password's servers. Check if your cluster has outbound internet access.

### ClusterSecretStore status is not Valid

```sh
kubectl describe clustersecretstore homelab
```

Check the `Status.Conditions` section. Common error messages:

- **`connect token is invalid`**: The access token in `1password-kubernetes-token` is expired or wrong. Regenerate it with `op connect token create` (Step 3.1) and update the secret.
- **`connection refused`**: The `connectHost` URL is wrong. Verify the service exists: `kubectl get svc -n 1password`. The service should be named `1password-connect`.
- **`no such host`**: The Kubernetes DNS name in `connectHost` doesn't resolve. Confirm the service name follows the pattern `<release>-<chart>.<namespace>.svc.cluster.local`.

### ExternalSecret stays in "SecretSyncedError"

```sh
kubectl describe externalsecret <name> -n <namespace>
```

Common causes:
- **1Password item not found**: The `remoteRef.key` doesn't match any item in the vault(s) configured in your `ClusterSecretStore`. Verify the item exists: `op item get <item-name>`.
- **Property not found**: The `remoteRef.property` doesn't match any field on the item. Check the item's fields: `op item get <item-name> --format json | jq '.fields[].label'`.
- **No access to vault**: The Connect token doesn't have access to the vault containing the item. Verify token scope: `op connect token list --server <your-server-name>`.

### Recreating credentials

If you need to regenerate the Connect server credentials (e.g., after rotating secrets), be aware that the Kubernetes Secret must also be updated:

```sh
kubectl create secret generic 1password-credentials \
  --from-literal=1password-credentials.json="$(op read "op://<your-vault>/<your-server-name>/1password-credentials.json")" \
  -n 1password \
  --dry-run=client -o yaml | kubectl apply -f -
```

Then restart the Connect pod to pick up the new credentials:

```sh
kubectl rollout restart deploy/1password-connect -n 1password
```
