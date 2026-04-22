# UniFi Terraform Reconciliation

## Context

The repo's current UniFi Terraform does not reflect the current live controller. The live UniFi controller is now the source of truth.

Two constraints drive this plan:

1. We do not care about preserving the current Terraform state, whether local or Terraform Cloud.
2. We do want the repo to become an accurate, maintainable representation of what is currently configured in the live UniFi controller.

This plan keeps the cleanup split into two parts:

1. Repo and workflow normalization
2. Live controller reconciliation and fresh local-state adoption

## Working Decisions

| Decision | Resolution |
| --- | --- |
| Source of truth | Current live UniFi controller |
| Existing Terraform state | Discard it; do not migrate it |
| Terraform Cloud | Remove it from the UniFi workflow |
| Target state backend | Fresh local state, gitignored, same pattern as the rest of the repo |
| Reconciliation strategy | Import from the live controller into fresh local state where Terraform should continue to manage an object |
| Ownership model | Split controller-global UniFi config from per-host DHCP/client reservations |

## Goals

- Make the repo's UniFi Terraform reflect the live controller.
- Remove the old Terraform Cloud dependency from the UniFi root.
- Eliminate duplicate and conflicting UniFi ownership across Terraform roots.
- End with a clean, local-state-based Terraform workflow that can plan safely against the live controller.

## Non-Goals

- Preserve or migrate the current Terraform Cloud workspace state.
- Force all live UniFi objects into a single Terraform root if that makes ownership worse.
- Perform destructive cleanup on the live controller before the repo is ready to represent the intended state.

## Current State Summary

As of 2026-04-20, the live controller differs materially from the repo:

- The UniFi root in `terraform/unifi` is not currently valid Terraform.
- The UniFi root still uses Terraform Cloud.
- Other roots still reference the old `homelab-unifi` Terraform Cloud workspace.
- UniFi client reservations are managed across several Terraform roots.
- Some client reservations are duplicated between `terraform/unifi` and other roots.
- The live controller contains additional networks, SSIDs, devices, port profiles, firewall groups, and client reservations not fully represented in repo Terraform.

## Target Ownership Model

The repo should converge on this model.

### `terraform/unifi` should own

- Networks
- WLANs / SSIDs
- UniFi devices
- Port profiles
- Firewall groups
- Firewall rules
- Any other controller-global UniFi object not tied to a single host's provisioning lifecycle

### Other Terraform roots should own

- Host-specific `unifi_user` / client reservation objects created as part of provisioning a VM or LXC
- Examples:
  - `terraform/pi-hole`
  - `terraform/dev-server`
  - `terraform/proxmox-dbs`
  - `terraform/proxmox-nodes`
  - `terraform/honcho`
  - `terraform/glitchtip-data`
  - `terraform/infisical-data`
  - shared module `terraform/modules/proxmox-lxc-service`

### `terraform/unifi` should not continue to own

- Duplicate reservations already owned by other roots
- Per-host reservations that are better coupled to the lifecycle of the host that creates them

That means reservations such as `jayden`, `cedes`, `eyana`, and `gpop` should not exist in both `terraform/unifi` and `terraform/kubernetes-nodes`.

## Two-Part Cleanup Approach

## Part 1: Repo And Workflow Normalization

### Objective

Make the repo structurally sound before touching reconciliation imports.

### Why This Comes First

Importing live objects into a broken or ambiguously-owned Terraform layout will create a second mess instead of fixing the first one.

### Part 1 Deliverables

- Valid Terraform in `terraform/unifi`
- No Terraform Cloud backend in the UniFi root
- No stale dependency on the old UniFi Terraform Cloud workspace
- Clear ownership boundaries for UniFi resources across roots
- A stable import target layout for live objects

### Part 1 Work Items

#### 1. Remove Terraform Cloud from `terraform/unifi`

- Delete the `cloud` block from `terraform/unifi/main.tf`
- Reinitialize the root as local-state-only
- Confirm the repo's existing `.gitignore` coverage remains sufficient for local state artifacts

### Expected Result

- `terraform/unifi` no longer depends on `app.terraform.io`
- Fresh local state can be created without any backend migration steps

#### 2. Make `terraform/unifi` validate cleanly

- Fix the invalid firewall rule reference in `terraform/unifi/firewall-rules.tf`
- Review all hardcoded IDs and cross-resource references in the UniFi root
- Remove obviously dead or broken declarations before import work starts

### Expected Result

- `terraform -chdir=terraform/unifi validate` succeeds

#### 3. Remove stale Terraform Cloud consumers elsewhere in the repo

The repo still contains roots that reference the old `homelab-unifi` workspace even if those outputs are no longer actively used.

- Remove or replace `data "terraform_remote_state"` blocks that point to the UniFi Terraform Cloud workspace
- Update any comments or examples that still imply Terraform Cloud output dependencies for UniFi

### Expected Result

- No Terraform root depends on the old `homelab-unifi` Terraform Cloud workspace

#### 4. De-duplicate UniFi client reservation ownership

- Inventory all `unifi_user` resources across the repo
- Classify them as either:
  - controller-global mistake living in the wrong root
  - valid per-host reservation coupled to a provisioning root
  - duplicate definition that must be removed
- Remove duplicates from `terraform/unifi`

### Expected Result

- Each live reservation has at most one Terraform owner

#### 5. Normalize hardcoded UniFi network references

Today many non-UniFi roots use hardcoded network IDs rather than derived references.

- Keep hardcoded live IDs temporarily where needed to avoid widening the scope too early
- Record which roots should eventually read a canonical local source of truth for shared network IDs
- Decide whether to expose canonical network IDs from `terraform/unifi` outputs for local cross-root use later

### Expected Result

- No immediate import blocker caused by shared network ID confusion
- Follow-up work is documented instead of hidden

#### 6. Add first-class workflow support for the UniFi root

- Add UniFi-specific `task` entries if the repo should support a standard `task terraform:init-unifi`, `plan-unifi`, `apply-unifi` flow
- Keep behavior aligned with how the rest of the repo runs Terraform

### Expected Result

- UniFi root is operated consistently with the rest of the repo

### Part 1 Checkpoint

Do not start live imports until all of the following are true:

- `terraform/unifi` validates
- Terraform Cloud is removed from the UniFi root
- No other root still depends on the old UniFi Terraform Cloud workspace
- Duplicate resource ownership has been eliminated or explicitly deferred with written rationale

## Part 2: Live Controller Reconciliation And Fresh Local-State Adoption

### Objective

Rebuild Terraform state from the live controller, using the cleaned repo structure from Part 1.

### Strategy

Treat live controller objects as authoritative, then decide object by object whether they should be:

- represented and imported into Terraform
- represented in a different Terraform root than today
- left unmanaged but documented
- removed later as intentional cleanup after repo convergence

### Part 2 Deliverables

- Fresh local Terraform state for the UniFi root
- Imported live objects for supported controller-global resources
- Updated Terraform definitions that match the live controller
- Reconciled host-specific reservation roots
- A final plan showing either no changes or only explicitly intended follow-up changes

### Part 2 Work Items

#### 1. Freeze a controller inventory snapshot

Before imports begin, capture the live object inventory used as the import source.

At minimum capture:

- Networks
- WLANs / SSIDs
- Devices
- Port profiles
- Firewall groups
- Firewall rules
- Client reservations / `unifi_user` objects with fixed IPs or explicit network bindings

### Expected Result

- A dated inventory snapshot exists and can be compared against later plans

#### 2. Build the reconciliation matrix

For each live object, record:

- live identifier
- human-readable name
- live attributes that matter
- target Terraform address
- owning root
- action:
  - import
  - keep unmanaged
  - remove from repo
  - remove later from controller

### Expected Result

- No import is performed ad hoc
- Every live object in scope has an explicit disposition

#### 3. Reconcile controller-global UniFi objects into `terraform/unifi`

##### Networks

- Update `terraform/unifi/terraform.tfvars` and resource declarations to match live network intent
- Reflect live `purpose` values where the controller differs from repo assumptions
- Decide how to represent legacy live networks that currently exist but are not in repo

##### WLANs

- Add or update SSID declarations so the repo matches the live controller for in-scope wireless networks
- Preserve live-to-network mappings

##### Devices

- Update names to match live controller naming where the controller is now authoritative
- Add missing adopted devices if Terraform should manage them

##### Port profiles

- Make the Terraform declarations match live profile behavior exactly before considering any cleanup
- Do not "correct" live settings during the reconciliation pass unless explicitly intended

##### Firewall groups and rules

- Represent the live groups that are intended to remain managed
- Investigate any live group duplicates and classify them
- Confirm how the current controller version exposes custom firewall rules and reconcile from that source

### Expected Result

- `terraform/unifi` describes the current live global UniFi configuration rather than an older intended design

#### 4. Reconcile per-host reservations in their owning roots

For each non-UniFi root that owns `unifi_user` resources:

- compare the Terraform declaration to the live controller object
- update names, fixed IPs, and network IDs to match live reality where the live controller is authoritative
- import the live reservation into fresh local state where that root should continue to manage it

This includes at least:

- `terraform/kubernetes-nodes`
- `terraform/pi-hole`
- `terraform/dev-server`
- `terraform/proxmox-dbs`
- `terraform/proxmox-nodes`
- `terraform/honcho`
- `terraform/glitchtip-data`
- `terraform/infisical-data`
- `terraform/modules/proxmox-lxc-service` consumers

### Expected Result

- Host-provisioning roots manage only their own reservations
- No reservation is imported into two different states

#### 5. Classify live-only objects not currently represented in repo

Some live controller objects exist but are not currently modeled in Terraform.

These must be classified into one of four buckets:

1. Import now because they are intentional infrastructure
2. Leave unmanaged for now because support or ownership is unclear
3. Add to a follow-up cleanup backlog
4. Remove later from the controller after repo convergence

Examples likely to fall into this review:

- legacy networks
- legacy SSIDs
- old firewall groups
- stale reservations for decommissioned systems

### Expected Result

- The repo no longer silently ignores live objects without an explicit decision

#### 6. Create fresh local state by import, not by apply-first guessing

For every in-scope object:

- initialize local state only after the config is ready
- import the live object into the correct address
- run plan immediately after import to identify attribute drift
- adjust config until plan is clean or only shows intended changes

### Expected Result

- State is rebuilt from the live controller rather than inferred from stale config

#### 7. Run final drift verification

After imports and config updates:

- run `terraform plan` for `terraform/unifi`
- run `terraform plan` for every other root that owns UniFi objects
- verify that any remaining changes are intentional and documented

### Expected Result

- Drift is reduced to either zero or an explicit backlog of conscious follow-up changes

## Proposed Execution Order

1. Clean `terraform/unifi`
2. Remove old Terraform Cloud references repo-wide
3. Remove duplicate UniFi ownership
4. Produce the reconciliation matrix from the live controller
5. Update `terraform/unifi` to match live global objects
6. Import fresh local UniFi state
7. Reconcile and import per-host reservation roots
8. Run final plans across all affected roots
9. Document deferred cleanup items

## Risk Register

### Risk: duplicate ownership causes conflicting imports

Mitigation:

- do not import until every object has a single owning Terraform address

### Risk: repo attempts to "correct" live settings during reconciliation

Mitigation:

- live controller remains authoritative for this pass
- first match live exactly, then do intentional cleanup later

### Risk: firewall rule support is controller-version-sensitive

Mitigation:

- validate provider behavior against live endpoints before promising full firewall-rule import coverage
- if provider support is incomplete, document the gap explicitly and leave those rules unmanaged short-term

### Risk: shared network IDs across multiple roots remain brittle

Mitigation:

- preserve known-good live IDs short-term
- schedule a follow-up to replace brittle hardcoding with a better local source of truth

### Risk: legacy live objects expand scope too far

Mitigation:

- classify every live object, but only import what has a clear ongoing owner
- keep a separate post-reconciliation cleanup backlog for questionable legacy objects

## Definition Of Done

This effort is done when all of the following are true:

- `terraform/unifi` uses local state only
- `terraform/unifi` validates cleanly
- no root depends on the old UniFi Terraform Cloud workspace
- each UniFi object in scope has a single Terraform owner
- the live controller inventory has been reconciled into repo config
- fresh local state has been created by import for in-scope objects
- plans are clean or only contain documented intentional changes
- deferred cleanup items are written down instead of hidden

## Follow-Up Backlog After Reconciliation

These are intentionally out of scope for the first pass unless they block clean reconciliation:

- replacing brittle hardcoded UniFi network IDs across roots
- consolidating shared network metadata into a better local source of truth
- pruning legacy live controller objects that are intentionally no longer desired
- improving task automation for import and verification
- deciding whether some per-host reservations should move into generated config rather than hand-maintained declarations

## Immediate Next Step

Execute Part 1 first. Do not import anything from the live controller until the repo layout, backend, and ownership model are clean enough to avoid recreating drift inside Terraform itself.
