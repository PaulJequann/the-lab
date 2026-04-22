# UniFi Reconciliation Matrix

## Snapshot

This matrix is based on a fresh read of the live UniFi controller on 2026-04-20.

The live controller is the source of truth.

This document is not the final desired architecture document. It is the operational ledger for the reconciliation pass:

- what exists live
- where it should be owned in Terraform
- what action should be taken
- what is safe to patch now versus defer to the import phase

## Action Legend

| Action | Meaning |
| --- | --- |
| `patch-now` | Safe repo change that should be made immediately before imports |
| `import` | Object should be imported into fresh local Terraform state |
| `add+import` | Object exists live but is not yet declared in Terraform; add it, then import it |
| `other-root` | Object should remain managed outside `terraform/unifi` |
| `defer` | Object exists live but needs an explicit ownership or support decision before changing code |
| `leave-unmanaged` | Object should remain outside Terraform for now |

## Controller-Global Objects

### Networks

| Live Name | Purpose | Live ID | Current Repo Status | Target Owner | Action | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `the-lab` | `corporate` | `5eb4c3cdb9e3ae02cf49f2cf` | Not declared in `terraform/unifi` | `terraform/unifi` | `defer` | Still used as `default_network_id`; legacy default LAN |
| `IoTings` | `corporate` | `610143c46410df0439003a01` | Not declared | `terraform/unifi` | `defer` | Legacy network backing legacy SSID `IoTings` |
| `Jaydens-World` | `guest` | `610150526410df0439003e91` | Not declared | `terraform/unifi` | `defer` | Live-only legacy guest network |
| `Guest` | `corporate` | `6101524f6410df0439003f20` | Not declared | `terraform/unifi` | `defer` | Live-only legacy network backing `StackSeason` SSID |
| `VPN Server` | `remote-user-vpn` | `63d68f104112fc088beb7d98` | Not declared | `terraform/unifi` | `defer` | Needs provider-capability confirmation before adding |
| `trusted` | `corporate` | `6445cb95b3a9fe1157bda051` | Declared | `terraform/unifi` | `import` | Repo already matches live intent closely |
| `security` | `corporate` | `6445cb95b3a9fe1157bda053` | Declared | `terraform/unifi` | `import` | Repo already matches live intent closely |
| `iotings` | `guest` | `6445cb95b3a9fe1157bda056` | Declared | `terraform/unifi` | `import` | Repo purpose has been corrected to match live |
| `lab-internal` | `corporate` | `6445cb96b3a9fe1157bda058` | Declared | `terraform/unifi` | `import` | Current repo aligns with live network intent |
| `lab-public` | `corporate` | `6445cb96b3a9fe1157bda05a` | Declared | `terraform/unifi` | `import` | Current repo aligns with live network intent |
| `stack-season` | `guest` | `6445cb96b3a9fe1157bda05c` | Declared | `terraform/unifi` | `import` | Repo purpose has been corrected to match live |

### WLANs / SSIDs

| Live Name | Live Network ID | Current Repo Status | Target Owner | Action | Notes |
| --- | --- | --- | --- | --- | --- |
| `IoTings` | `610143c46410df0439003a01` | Not declared | `terraform/unifi` | `defer` | Legacy SSID on legacy network |
| `TheLab` | `5eb4c3cdb9e3ae02cf49f2cf` | Not declared | `terraform/unifi` | `defer` | Legacy default-LAN SSID |
| `StackSeason` | `6101524f6410df0439003f20` | Not declared | `terraform/unifi` | `defer` | Legacy SSID on legacy `Guest` network |
| `IotNew` | `6445cb95b3a9fe1157bda056` | Declared as `unifi_wlan.iot` | `terraform/unifi` | `import` | Repo already models live SSID |

### Devices

| Live Name | MAC | Model | Current Repo Status | Target Owner | Action | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `Switch - 48 POE` | `e0:63:da:20:a9:ba` | `US48P500` | Declared | `terraform/unifi` | `import` | Repo now includes the missing live port override on port 43 |
| `AP - Living Room` | `74:83:c2:7d:74:07` | `U7NHD` | Declared | `terraform/unifi` | `import` | Repo name already matches live |
| `AP - Hallway` | `74:83:c2:77:fd:10` | `U7NHD` | Declared | `terraform/unifi` | `import` | Repo name has been corrected to match live |
| `Leila` | `e0:63:da:e4:6d:51` | `UDMPRO` | Not declared | `terraform/unifi` | `defer` | Managing the gateway device needs explicit comfort level |
| `U7 Pro` | `0c:ea:14:1b:38:1d` | `U7PRO` | Not declared | `terraform/unifi` | `add+import` | Straightforward candidate if device management is desired |
| `Living Room Switch` | `60:22:32:4f:c3:08` | `USMINI` | Not declared | `terraform/unifi` | `add+import` | Straightforward candidate if device management is desired |

### Default-Network Hardware Client Records

These are the `unifi_user` records tied to adopted hardware on the default LAN.

| Live Name | MAC | Current Repo Status | Target Owner | Action | Notes |
| --- | --- | --- | --- | --- | --- |
| `AP - Office` | `74:83:c2:77:fd:10` | Declared | `terraform/unifi` | `import` | Live client record still uses the older name even though the adopted device is `AP - Hallway` |
| `AP - Living Room` | `74:83:c2:7d:74:07` | Declared | `terraform/unifi` | `import` | No naming drift |
| `Switch - 48 POE` | `e0:63:da:20:a9:ba` | Declared | `terraform/unifi` | `import` | No naming drift |

### Port Profiles

| Live Name | Live ID | Current Repo Status | Target Owner | Action | Notes |
| --- | --- | --- | --- | --- | --- |
| `trusted-devices` | `6445cb96b3a9fe1157bda063` | Declared | `terraform/unifi` | `import` | Current repo intent matches live |
| `cameras-security` | `6445cb96b3a9fe1157bda064` | Declared | `terraform/unifi` | `import` | Current repo intent matches live |
| `Lab Hardware` | `6445cb97b3a9fe1157bda068` | Declared | `terraform/unifi` | `import` | Repo port profile has been corrected to match live |
| `Lab Hardware Test` | `6445d6b4b3a9fe1157bda62b` | Not declared | `terraform/unifi` | `defer` | Live-only profile; unclear if intentional or experimental |

### Firewall Groups

| Live Name | Type | Current Repo Status | Target Owner | Action | Notes |
| --- | --- | --- | --- | --- | --- |
| `RFC1918` | `address-group` | Declared | `terraform/unifi` | `import` | Current repo matches live contents |
| `Secure Internal Gateways` | `address-group` | Declared | `terraform/unifi` | `import` | Current repo matches live contents |
| `IoT and StackSeason` | `address-group` | Declared but missing `10.10.20.0/25` | `terraform/unifi` | `defer` | Live group depends on legacy `Guest` network not yet modeled |
| `LabPublic, Trusted, StackSeason` | `address-group` | Declared | `terraform/unifi` | `import` | Current repo matches live members |
| `HTTP, HTTPS, SSH` | `port-group` | Declared | `terraform/unifi` | `import` | Current repo matches live members |
| `Plex Group` | `port-group` | Declared | `terraform/unifi` | `import` | Current repo matches one of the live duplicates |
| `Plex` | `port-group` | Not declared | `terraform/unifi` | `defer` | Live duplicate of `Plex Group`; decide whether to prune later |
| `Hoodflix` | `address-group` | Not declared | `terraform/unifi` | `defer` | Live-only group; unclear if intentional |

### Firewall Rules

| Live Status | Current Repo Status | Target Owner | Action | Notes |
| --- | --- | --- | --- | --- |
| No custom rules returned by `/rest/firewallrule` | Repo declares 2 rules | `terraform/unifi` | `defer` | Import is blocked on confirming whether controller version stores custom rules elsewhere or whether the repo rules are simply stale |

## Per-Host Reservations

These should remain owned by the Terraform root that provisions the corresponding system.

### Expected Other-Root Ownership

| Live Name | Fixed IP | Live Network ID | Target Owner | Action | Notes |
| --- | --- | --- | --- | --- | --- |
| `cedes` | `10.0.10.26` | `6445cb96b3a9fe1157bda058` | `terraform/kubernetes-nodes` | `other-root` | Already the sole repo owner after Part 1 cleanup |
| `eyana` | `10.0.10.28` | `6445cb96b3a9fe1157bda058` | `terraform/kubernetes-nodes` | `other-root` | Already the sole repo owner after Part 1 cleanup |
| `jayden` | `10.0.10.25` | `6445cb96b3a9fe1157bda058` | `terraform/kubernetes-nodes` | `other-root` | Already the sole repo owner after Part 1 cleanup |
| `gpop` | `10.0.10.29` | `6445cb96b3a9fe1157bda058` | `terraform/kubernetes-nodes` | `other-root` | Already the sole repo owner after Part 1 cleanup |
| `jamahl` | `10.0.10.24` | `6445cb96b3a9fe1157bda058` | `terraform/kubernetes-nodes` | `other-root` | Already owned outside `terraform/unifi` |
| `pihole` | `10.0.10.101` | `6445cb96b3a9fe1157bda058` | `terraform/pi-hole` | `other-root` | Current repo aligns with live |
| `dev` | `10.0.10.99` | `6445cb96b3a9fe1157bda058` | `terraform/dev-server` | `other-root` | Current repo aligns with live |
| `glitchtip-data` | `10.0.10.83` | `6445cb96b3a9fe1157bda058` | `terraform/glitchtip-data` | `other-root` | Current repo aligns with live |
| `honcho` | `10.0.10.84` | `6445cb96b3a9fe1157bda058` | `terraform/honcho` | `other-root` | Current repo aligns with live |
| `infisical-data` | `10.0.10.85` | `6445cb96b3a9fe1157bda058` | `terraform/infisical-data` | `other-root` | Current repo aligns with live |
| `Wendy-1` | `10.0.10.80` | `6445cb96b3a9fe1157bda058` | `terraform/proxmox-dbs` | `other-root` | Live has two MAC records for same name/IP; needs import hygiene |
| `Wendy-2` | `10.0.10.81` | `6445cb96b3a9fe1157bda058` | `terraform/proxmox-dbs` | `other-root` | Current repo aligns with live |
| `Wendy-3` | `10.0.10.82` | `6445cb96b3a9fe1157bda058` | `terraform/proxmox-dbs` | `other-root` | Current repo aligns with live |

### Live Reservations Not Currently Owned In Repo

| Live Name | Fixed IP | Current Status | Action | Notes |
| --- | --- | --- | --- | --- |
| `pjdotdev-admin` | `10.0.10.5` | No Terraform owner found | `defer` | Likely intentional admin host reservation |
| `tailscale` | `10.0.10.75` | No Terraform owner found | `leave-unmanaged` | No clear infrastructure owner yet |
| unnamed host | `10.0.10.164` | No Terraform owner found | `defer` | Related to live `Hoodflix` firewall group |
| `Mia` | `10.0.0.27` | No Terraform owner found | `defer` | Legacy default-LAN reservation |
| legacy `Jayden` | `10.0.0.5` | No Terraform owner found | `defer` | Separate from current lab-internal `jayden` |
| unnamed host | `10.0.0.74` | No Terraform owner found | `defer` | Legacy default-LAN reservation |
| unnamed host | `10.10.10.133` | No Terraform owner found | `leave-unmanaged` | Legacy network |
| unnamed host | `10.10.10.50` | No Terraform owner found | `leave-unmanaged` | Legacy network |
| `Kash's TV` | `10.10.20.74` | No Terraform owner found | `leave-unmanaged` | Legacy network |

### Repo Reservations Not Seen Live

These are likely stale Terraform declarations that should not be imported as-is.

| Repo Object | Current Owner | Action | Notes |
| --- | --- | --- | --- |
| `Rocket-1` | `terraform/proxmox-nodes` | `defer` | Not present in current live controller snapshot |
| `Rocket-2` | `terraform/proxmox-nodes` | `defer` | Not present in current live controller snapshot |
| `Rocket-3` | `terraform/proxmox-nodes` | `defer` | Not present in current live controller snapshot |
| `KK-1` | `terraform/proxmox-nodes` | `defer` | Not present in current live controller snapshot |
| `KK-2` | `terraform/proxmox-nodes` | `defer` | Not present in current live controller snapshot |
| `KK-3` | `terraform/proxmox-nodes` | `defer` | Not present in current live controller snapshot |

## Immediate Patch Set

These low-risk repo changes have already been applied:

1. Changed `iotings` network purpose from `corporate` to `guest`
2. Changed `stack-season` network purpose from `corporate` to `guest`
3. Renamed the adopted device from `AP - Office` to `AP - Hallway` in the UniFi root while keeping the separate hardware client record as `AP - Office` to match live
4. Removed the stale tagged network from the `Lab Hardware` port profile
5. Added the missing live switch port override on port 43 for `Switch - 48 POE`

## Deferred Decisions

These should be resolved before the import phase is complete, but they are not safe to guess in the first patch set:

1. Whether to fully model legacy live networks and SSIDs in `terraform/unifi`
2. Whether to manage `Leila` in Terraform as a UniFi device resource
3. Whether to add `U7 Pro` and `Living Room Switch` immediately or defer until after the first clean import pass
4. Whether to keep or prune duplicate live firewall groups `Plex` and `Plex Group`
5. How to handle the live-only `Hoodflix` firewall group and the unnamed `10.0.10.164` reservation it references
6. How to confirm the effective source of custom firewall rules on this controller version
7. How to reconcile duplicate live records for `Wendy-1`
