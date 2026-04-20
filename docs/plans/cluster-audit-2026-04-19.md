# Cluster Audit — 2026-04-19

**Context:** Pre-A.9 cluster health assessment for the secret management redesign. All findings below were captured against the live cluster on 2026-04-19. Items 1 and 2 have since been resolved.

---

## Current Stage

The plan is through **A.8 (Canary Health Check) ✅** and ready to begin **A.9 (Migrate Kubernetes Secrets)**. Everything up through A.8 is complete and verified:

| Step | Status |
|---|---|
| Phase 0 (ARC retired, Deeptutor deferred) | ✅ |
| A.1 Bootstrap Contract | ✅ |
| A.2 Infisical Data LXC | ✅ |
| A.3 One-Command Bootstrap | ✅ |
| A.4 Infisical Server deployed | ✅ |
| A.4.5 Admin Identity bootstrapped | ✅ |
| A.4.7 Secret/Config Audit | ✅ |
| A.5 Secrets populated in Infisical | ✅ |
| A.6 Infisical Operator deployed | ✅ |
| A.7 Machine Identities created | ✅ |
| A.8 Canary validated | ✅ |
| **A.9 App Migration (cert-manager → glitchtip → deeptutor)** | **⬅ Next** |

---

## 🔴 Problems Requiring Attention

### 1. Node jamahl is NotReady (Kubelet dead) — ✅ RESOLVED

**Severity:** High — operational risk

Node `jamahl` (10.0.10.24) had been `NotReady` for at least 26 days. All conditions showed `Unknown` with message `"Kubelet stopped posting node status."` The kubelet process was unresponsive, though the node's Cilium agent and CSI daemonset pods were still technically running with old restarts.

**Impact cascade:**
- 6 pods stuck `Terminating` on jamahl — GlitchTip web/worker (2), cert-manager pods (3), and the GlitchTip bootstrap job pod — because the kubelet wasn't processing deletion requests
- GlitchTip's PVC `glitchtip-duckdb` stuck `Terminating` — the PVC has `kubernetes.io/pvc-protection` finalizer because the Terminating pods on jamahl still referenced it
- GlitchTip new pods `Pending` — they can't schedule because they need the PVC which is stuck Terminating
- GlitchTip was effectively down — no running web or worker pods

**Resolution:** Kubelet restarted on jamahl. Node is now `Ready`. Terminating pods cleared.

### 2. GlitchTip Down / Stray Resources in `default` Namespace — ✅ RESOLVED

**Severity:** High

GlitchTip had no running pods. The deployment showed 0/1 available for both web and worker. The chain: jamahl NotReady → old pods stuck Terminating on jamahl → PVC can't be deleted → new pods can't mount the PVC → Pending forever.

There was also a stray GlitchTip deployment in the `default` namespace — pods, services, deployments, and a `glitchtip-migrate` Job that failed. These appeared to be leftover from a Helm test or misconfigured release. The `default` namespace contained:
- 2 Pending GlitchTip pods
- 1 Terminating GlitchTip bootstrap pod (on jamahl)
- 1 `CreateContainerConfigError` GlitchTip bootstrap pod
- 1 `Error` `glitchtip-test-connection` pod
- GlitchTip services and deployments

**Resolution:** After jamahl was restored, stray GlitchTip resources were deleted from the `default` namespace. GlitchTip in the `glitchtip` namespace is now Running (1/1 web + worker).

---

## 🟡 Items to Address Before A.9 Migration

### 3. `core` AppProject Missing `InfisicalSecret` Whitelist

The plan's A.6 notes that "at minimum, update the `apps` AppProject before migrating GlitchTip." The `apps` project has the `InfisicalSecret` whitelist — good. But **cert-manager** is in the `core` project, and `core` has no `namespaceResourceWhitelist` at all (empty array). Currently the core project uses `"*":"*"` implicitly because it has no whitelist restriction.

This will work fine for cert-manager's InfisicalSecret CRD since there's no whitelist filtering. However, if you tighten the core project's RBAC in the future (which the plan mentions doing for apps), cert-manager's InfisicalSecret would be blocked. **Not blocking now, but worth noting.**

### 4. SealedSecrets Still Active — Expected at This Stage

Three `SealedSecret` resources exist: `cert-manager/cloudflare-api-token`, `glitchtip/glitchtip-secrets`, `deeptutor/deeptutor-secrets`. The Sealed Secrets controller is running and healthy. This is correct — A.12.2 removes Sealed Secrets **after** A.9 replaces them with InfisicalSecret CRDs. The `SealedSecret` OutOfSync diffs on cert-manager and glitchtip are the expected nondeterministic encryption churn that the plan is designed to eliminate.

### 5. `storage` App SyncError — Pre-existing, Not Infisical-Related

The `storage` ArgoCD Application shows `SyncError: auto-sync will wipe out all resources`. The diff shows the child `csi-driver-nfs` Application as entirely OutOfSync (live has `managedFields`/`status` that git doesn't). ArgoCD's safety mechanism refuses auto-sync to prevent accidental deletion.

This is a pre-existing issue unrelated to the Infisical migration. The NFS driver is running fine (4/5 DaemonSet pods Ready). Fix would be to either sync manually with `--force` or adjust the Application's sync options.

---

## 🟢 Things That Are Working Well

| Component | Status |
|---|---|
| **Infisical Server** | 1/1 Running, `/api/status` returns `200`, ingress works, TLS valid |
| **Infisical Operator** | 1/1 Running, 36Mi memory, reconciling canary every 60s |
| **Canary InfisicalSecret** | Synced/Healthy, `heartbeat: ok` confirmed in managed Secret |
| **K8s Auth identity** | Operator authenticates successfully via TokenReview, `projectId` resolved from slug `the-lab-kjtq` |
| **ArgoCD resource exclusion** | Correctly configured — `app.kubernetes.io/managed-by: infisical-operator` label-based exclusion in place |
| **Deeptutor** | 1/1 Running, rollout successful, 102 days uptime |
| **All TLS certificates** | `Ready=True` for all 8 certificates including the new `infisical-tls` |
| **Infisical data host** | Server connected to external PostgreSQL on `10.0.10.85` (confirmed by `redisConfigured: true` in status) |

---

## 💡 Observations & Improvement Opportunities

### 6. Infisical Server Memory Usage is High

The Infisical pod is using **822Mi** of its **1Gi limit** (~80%). The original plan specified 512Mi, and the git values show `limits.memory: 1Gi` with `requests.memory: 512Mi` — so the limit was already raised from the plan's 512Mi. But 80% utilization with no CPU pressure suggests the server may be approaching memory pressure under load. Consider monitoring this and potentially raising the limit to 1.5Gi as a buffer, or setting up alerts at 85%.

### 7. Cilium Test Namespace (`cilium-test-1`) is Stale

This namespace has been running for 304 days with 10 pods (host-netns DaemonSet, echo services, clients). These appear to be leftover Cilium connectivity tests. They're consuming resources and cluttering the cluster. If Cilium is verified working, this namespace could be cleaned up.

### 8. `cilium-secrets` Namespace is Empty

An empty namespace consuming no resources but adding clutter to `kubectl get ns`. Can be deleted.

### 9. `root-app` OutOfSync — Missing Finalizers on Media Apps

The `root-app` shows overseerr, radarr, and sonarr as OutOfSync because the live resources have `finalizers: [resources-finalizer.argocd.argoproj.io]` that aren't in the git manifests. This is a cosmetic issue — the finalizers were likely added by ArgoCD itself or an earlier config version. If these finalizers are intentional, add them to git. If not, they can be removed from the live resources.

### 10. K3s Version is Old (v1.30.4)

All nodes run K3s `v1.30.4+k3s1` which is ~10 months old. Kubernetes 1.30 went out of upstream support in February 2026. This is outside the scope of the secret management plan but worth tracking for a future maintenance window.

### 11. ArgoCD `ExcludedResourceWarning` on Infisical Token-Reviewer Secret

The `infisical` ArgoCD Application shows `ExcludedResourceWarning` for `infisical-token-reviewer-token`. This is a false positive — the secret doesn't have the `app.kubernetes.io/managed-by: infisical-operator` label, so it's not actually being excluded by the Infisical exclusion rule. This warning is likely triggered by a broader exclusion rule (perhaps the `argocd-secret` exclusion). Not harmful but slightly noisy.

### 12. ReplicaSets from Old Infisical Deployments

The Infisical namespace shows 5 ReplicaSets — evidence of multiple redeployments during bootstrap. Only 1 is active. Old ReplicaSets are normal Kubernetes behavior and will be cleaned up by the deployment revision history limit, but the count suggests the bootstrap went through several iterations. No action needed.
