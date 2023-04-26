NODE = the node that is getting the new IP.
CLUSTER = all other Proxmox nodes that will maintain quorum and can talk to one another throughout this procedure.
ONE CLUSTER = any one single node within CLUSTER

On NODE

1. Edit /etc/pve/corosync.conf.
2. Update the IP for NODE.
3. Increment

```
config_version:
```

This change should push out a new corosync.conf to all nodes in CLUSTER. Confirm all nodes in CLUSTER have the new /etc/pve/corosync.conf. At this point the cluster will be broken. If you run

```
 pvecm status
```

on the NODE, you will see it can't find the rest of the nodes in the cluster. If you run

```
 pvecm status
```

on CLUSTER you will see they can all see each other but NODE is missing.

Still on NODE

1. Edit /etc/network/interfaces and update the IP to the desired IP.
2. Edit /etc/hosts and update the IP to the new IP.
3.

```
ifdown vmbr0; ifup vmbr0
```

to get your interface to have the new static IP. Change "vmbr0" to the name of your interface. 4. Restart corosync and pve-cluster.

```
systemctl restart corosync
systemctl restart pve-cluster
```

On CLUSTER

1. Restart corosync on EVERY member of CLUSTER.

```
systemctl restart corosync
```

At this point

```
pvecm status
```

should show all nodes as being in the cluster, good quorum, and NODE has its proper IP. Be patient as this can take a minute. To be extra sure, run

```
cat /etc/pve/.members
```

on NODE and this should show all the correct IPs.

Additional cleanup.

On NODE:

1. Optional: Edit /etc/issue. Update to the new IP on NODE. This ensures the console login screen shows the right IP.
2. Edit /etc/pve/storage.cfg and update any references to the old NODE IP - likely only an issue if you run PVE and PBS next to each other.
3. Optional: Edit /etc/pve/priv/known_hosts and update the IP of NODE.
