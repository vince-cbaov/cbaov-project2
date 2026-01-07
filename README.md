# CBAOV Website — Advanced Jenkins Pipeline

This project hosts a static website with **three versions** and an advanced Jenkins pipeline covering:

- **Branch tagging rules**: `main → v1`, `develop → v2`, else `v3` (when `VERSION=auto`)
- **Auto-promotion**: promote `v2` to `v1` on main builds when digests differ
- **Digest guardrail**: fail if `v2` digest equals `v1`, or `v3` equals `v2`
- **Azure Web App deployment** (supports GHCR private repos)
- **NGINX reverse-proxy reload** over SSH
- **Multibranch PR preview**: per-PR tag, dynamic port, and printed preview URL

## Versions & Assets

- **v1**: `index.html`, `cbaov_logo.png`
- **v2**: `index.html`, `base.html`, `about.html`, `cbaov_logo.png`, `prototype1.png`, `prototype2.png`, `prototype3.png`
- **v3**: `index.html`, `base.html`, `about.html`, `contact.html`, `cbaov_logo.png`, `prototype1.png`, `prototype2.png`, `prototype3.png`

## Docker

- Base: `nginx:alpine`
- Build arg: `SITE_SRC=web/<version>` selects which set of files to copy.

## Jenkins pipeline (jenkins/Jenkinsfile)

### Parameters
- `VERSION`: `auto|v1|v2|v3` (auto derives from branch)
- `PUSH_TO_REGISTRY`: push to GHCR and pull on VM; if false, stream over SSH
- `GHCR_PRIVATE`: set to true if your GHCR repo is private (Azure needs registry creds)

### Environment & credentials
Update IDs to match your Jenkins:
- `IMAGE_NAME = ghcr.io/vince-cbaov/cbaov-site`
- `DOCKER_HOST_IP` (Secret Text) → **DOCKERVM_IP** credential
- `NGINX_HOST_IP` (Secret Text) → **NGINXIP** credential
- SSH agent creds: **docker-agents** (Docker VM), **NGINX_SSH** (NGINX host)
- Azure SP: **AZURE_CLIENT_ID**, **AZURE_CLIENT_SECRET**, **AZURE_TENANT_ID**, **AZURE_SUBSCRIPTION_ID**
- GHCR PAT: **GITHUB_TOKEN** with `read:packages` + `write:packages`

### Multibranch PR preview
- If `CHANGE_ID` is present, a preview tag `pr-<id>` is created and deployed to a derived port in `8100–8999`.
- Jenkins prints `Preview URL: http://<DOCKER_HOST_IP>:<port>/`.

### Digest guardrails
- After push, pipeline pulls prior images and compares RepoDigests.
- Fails if `v2 == v1` or `v3 == v2` (no change).

### Auto-promotion
- On `main`, pipeline retags and pushes `v2 → v1` if digests differ.

### Azure Web App
- If GHCR is private, the pipeline passes registry URL/user/password to `az webapp config container set`.
- App is restarted post-config.

## Job setup
- Definition: *Pipeline script from SCM* → Script Path: `jenkins/Jenkinsfile`
- Agent: a label with Docker, SSH, and Azure CLI available (e.g., `docker`).

## Run examples
- **Main build (prod)**: `VERSION=auto` on branch `main` → builds `v1`, compares digests, deploys prod, promotes if appropriate, deploys to Azure, reloads NGINX.
- **Develop build (staging)**: `VERSION=auto` on branch `develop` → builds `v2`, compares against `v1`, deploys to VM port 8080 if promoted later.
- **PR build (preview)**: multibranch PR → builds version derived by `VERSION` or defaults to `v3`, tags `pr-<id>`, deploys on a preview port and prints a URL.

## Troubleshooting
- Docker permission issues: ensure Jenkins user is in `docker` group; restart Jenkins.
- GHCR unauthorized: verify PAT scopes and that image path uses your namespace.
- SSH failures: confirm keys and firewall rules (TCP/22 to VM and NGINX host).
- Azure CLI missing: install `az` on the agent.
- Preview port conflicts: adjust the port derivation logic if needed.

© 2026 CBAOV — Advanced pipeline generated 2026-01-01T19:42:57.212999+00:00
