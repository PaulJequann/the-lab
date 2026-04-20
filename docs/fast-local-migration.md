# Fast Local Migration

This repo now stages fast-local PVCs separately from workload cutover.

Default behavior:

- `local-path-provisioner` and the destination fast-local PVCs can be deployed first
- workloads remain on the existing `nfs-csi` PVCs until an explicit `*_fast_local_enabled: true` flag is set in `config.yaml`

## Why This Is Two-Phase

The current source PVCs are dynamically provisioned by the live apps:

- `homeassistant/homeassistant`
- `media/sonarr`
- `media/radarr`
- `media/overseerr`

Changing a workload to use a new claim is a cutover, not an in-place mutation. The source apps must be stopped for a consistent copy because these workloads store mutable config and database files under `/config`.

## Recommended Sequence

1. Commit and push the staged storage changes with all `*_fast_local_enabled` flags still `false`.
2. Let Argo deploy:
   - `kubernetes/infrastructure/local-path-storage`
   - `kubernetes/apps/media`
   - `kubernetes/apps/homeassistant`
3. During a maintenance window, run:

```bash
task migrate-fast-local-pvc -- homeassistant
task migrate-fast-local-pvc -- sonarr
task migrate-fast-local-pvc -- radarr
task migrate-fast-local-pvc -- overseerr
```

By default, the migration script:

- scales the workload down
- writes a tar backup to `/tmp/fast-local-migration-<timestamp>/`
- copies data from the old NFS claim to the staged fast-local claim
- leaves the workload scaled down for cutover

Use `--restore-replicas` only for rehearsal. It is not appropriate for final cutover because the destination copy will become stale as soon as the app starts writing to the source PVC again.

4. Flip the relevant flags in `config.yaml`:

- `homeassistant_fast_local_enabled`
- `sonarr_fast_local_enabled`
- `radarr_fast_local_enabled`
- `overseerr_fast_local_enabled`

5. Run `task configure`, commit, and push.
6. Let Argo sync the updated workloads onto the fast-local PVCs.
7. Verify app health and data integrity.

## Notes

- The `fast-local` StorageClass uses `WaitForFirstConsumer`, so the migration pod and the cutover workload must use scheduler constraints, not `nodeName`.
- Home Assistant is pinned to `gpop`.
- Sonarr is pinned to `gpop`.
- Radarr and Overseerr are pinned to `jamahl`.
- Once cutover succeeds, Argo pruning will remove the old NFS-backed PVC objects from these apps.
