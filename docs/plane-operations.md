# Plane Operations

This document captures decisions and deferred setup notes for the Plane
Enterprise deployment.

## Current Intended Deployment

- Edition: Plane Enterprise.
- Hostname: `plane.local.bysliek.com`.
- Namespace: `plane`.
- Ingress: repo-owned Cilium Ingress.
- TLS: existing cert-manager `cloudflare-cluster-issuer`, secret `plane-tls`.
- Postgres: external database on `services-data`.
- Valkey: dedicated chart-managed Plane Valkey.
- RabbitMQ: dedicated chart-managed Plane RabbitMQ with credentials sourced
  from Infisical.
- MinIO: dedicated chart-managed Plane MinIO for uploads.
- OpenSearch: disabled.
- Plane AI/PI: disabled.
- Silo: enabled.
- Silo connectors: disabled.
- Email/SMTP: disabled.
- Secrets: Infisical path `/kubernetes/plane`.

## Secret Handling

Plane secrets belong in Infisical at:

```text
/kubernetes/plane
```

Do not commit plaintext secrets. Do not paste secret values into chat, logs, or
docs.

Expected secret categories:

- App signing/runtime secrets.
- Live service secret.
- Silo encryption/HMAC secrets.
- Postgres password.
- MinIO/doc-store credentials.
- RabbitMQ credentials.
- Future connector credentials.
- Future SMTP credentials.
- Future AI provider credentials.

Required initial keys:

- `SECRET_KEY`
- `LIVE_SERVER_SECRET_KEY`
- `AES_SECRET_KEY`
- `PI_INTERNAL_SECRET`
- `SILO_HMAC_SECRET_KEY`
- `POSTGRES_PASSWORD`
- `MINIO_ROOT_USER`
- `MINIO_ROOT_PASSWORD`
- `RABBITMQ_DEFAULT_USER`
- `RABBITMQ_DEFAULT_PASS`

## Enabling Silo Connectors Later

Silo remains enabled, but all connectors are disabled initially.

The Plane Enterprise chart supports:

- Slack
- GitHub
- GitLab

Before enabling a connector:

1. Create the OAuth app or GitHub App in the provider.
2. Set callback/redirect URLs according to Plane's current documentation.
3. Add the provider credentials to Infisical under `/kubernetes/plane`.
4. Update `config.yaml` connector flags.
5. Update the Plane values template if new non-secret metadata is required.
6. Run `task configure`.
7. Render with `helm template` and verify no secret values appear in generated
   files.
8. Commit and let ArgoCD sync.

### Slack

Expected secret keys when enabled:

- `SLACK_CLIENT_ID`
- `SLACK_CLIENT_SECRET`

### GitHub

Expected secret keys when enabled:

- `GITHUB_CLIENT_ID`
- `GITHUB_CLIENT_SECRET`
- `GITHUB_APP_NAME`
- `GITHUB_APP_ID`
- `GITHUB_PRIVATE_KEY`

Prefer a GitHub App over a broad OAuth app if Plane supports both for the target
workflow. Keep the private key only in Infisical.

### GitLab

Expected secret keys when enabled:

- `GITLAB_CLIENT_ID`
- `GITLAB_CLIENT_SECRET`

## Enabling Email Later

Email/SMTP is deferred for the first deployment.

Before enabling email:

1. Confirm Plane Enterprise's current SMTP environment variables in the chart or
   upstream docs.
2. Store SMTP credentials in Infisical under `/kubernetes/plane`.
3. Add non-secret SMTP config to `config.yaml`.
4. Extend the Plane InfisicalSecret template to materialize the required secret
   keys.
5. Enable any chart service flags if Plane's `email_service` is required.
6. Run `task configure`.
7. Validate with `helm template`.
8. Test invite, notification, and password-reset flows after ArgoCD sync.

Do not reuse GlitchTip email secrets directly. If the same SMTP provider is used,
duplicate or reference the provider credentials through Infisical policy, not by
copying rendered Kubernetes Secrets between namespaces.

## Enabling Plane AI / PI Later

Plane AI/PI is disabled initially.

Before enabling:

1. Choose provider: OpenAI, Claude, Groq, Cohere, custom LLM, or another
   supported provider.
2. Store provider API keys in Infisical under `/kubernetes/plane`.
3. Decide whether PI needs a separate Postgres database. The chart has separate
   PI database settings.
4. Add any required database/user to the `services-data` Ansible flow.
5. Enable PI flags in `config.yaml`.
6. Extend Plane values and InfisicalSecret templates.
7. Include `/pi/` in the custom Ingress only when PI is enabled.
8. Render and validate with `helm template`.

## Enabling OpenSearch Later

OpenSearch is disabled initially.

The Plane Enterprise chart's local OpenSearch defaults are relatively heavy:

- Memory request: `2Gi`
- Memory limit: `3Gi`
- CPU request: `500m`
- CPU limit: `750m`
- Storage: `5Gi`

Before enabling:

1. Confirm live cluster headroom with `kubectl top nodes`.
2. Decide between chart-managed OpenSearch and an external OpenSearch service.
3. Store OpenSearch credentials in Infisical if using external credentials.
4. Enable `services.opensearch.local_setup` or configure remote OpenSearch in
   Plane values.
5. Add `/kubernetes/plane` secret keys required by the chart.
6. Render and validate that OpenSearch StatefulSets and secrets are correct.

## Routine Validation

Useful commands after deployment:

```bash
kubectl -n plane get pods,svc,ingress,certificate,pvc
kubectl -n argocd get application plane
curl -skI https://plane.local.bysliek.com/
```

For failures, check:

```bash
kubectl -n plane get events --sort-by=.lastTimestamp
kubectl -n plane logs deployment/plane-app-api-wl
kubectl -n plane logs deployment/plane-app-worker-wl
kubectl -n plane logs deployment/plane-app-silo-wl
```

Do not print Kubernetes Secret contents while debugging.
