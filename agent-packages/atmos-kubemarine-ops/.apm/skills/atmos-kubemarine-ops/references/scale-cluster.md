# Scale a cluster

Nodes are declared in `components.terraform.infra.vars.nodes` (usually `stacks/clusters/<cluster>.yaml`):
`name: { type: <node type>, [size|disk_size|labels|taints overrides] }`. A node type (`node_types`, base ones in
`stacks/catalog/node-types.yaml`) carries `roles`, `size` (a size class mapped by the provider's `sizes`, or a literal VM
size), `disk_size`, `labels`, `taints`. Node = type fields + its own fields (labels merge, taints replace).

## Before any node change

- `grep -rn '<node-name>' stacks/` - apps can pin to node names (e.g. kafka `storage.nodes` + `racks`, nodeSelectors).
  Removing or renaming a pinned node breaks them; update those lists in the same change.
- Count what must survive: control-planes stay odd (1, 3, 5); more than one control-plane needs a `balancer` node (or
  `vrrp_ips`); app replicas with required anti-affinity / pinning need enough schedulable workers. Tainted workers do not
  run untolerating pods.
- Running locally: the machine's public IP must be in `admin_cidr` (SSH 22, API 6443). If the egress IP changes per
  request (NAT pool), the whole pool must be allowed or SSH/API calls fail intermittently.

## Add a node (horizontal scale-out)

1. Add `worker-N: { type: worker }` to the cluster layer. Node names are kubernetes hostnames: lowercase, stable.
2. `atmos terraform plan infra -s <stack>` - expect only `+` for the new VM (and nothing replaced).
3. After approval: `atmos terraform apply infra -s <stack>` - creates the VM; `nodes` output now contains it.
4. `atmos kubemarine add_node -s <stack> --nodes worker-N --dry-run` - check the node is in procedure.yaml and absent
   from cluster.yaml. Then, after approval, the same without `--dry-run`.
5. Labels and taints are applied by kubemarine when the node joins.

## Remove a node (reverse order!)

1. While the VM still exists in the outputs: `atmos kubemarine remove_node -s <stack> --nodes worker-N` (dry-run first).
   Drain concerns (PDBs, local-path volumes on that node) belong to the user: say which pods / PVCs live there
   (`kubectl get pods,pvc -A -o wide | grep worker-N`). Data on local-path volumes is lost with the node.
2. Delete the node from the stack, `terraform plan` (expect exactly one VM destroyed), apply after approval.

## Resize (vertical)

- All nodes of a type: change `size`/`disk_size` of the type in the cluster layer (`node_types: { worker: { size: xlarge } }`),
  or change the class mapping for one placement in `providers/<cloud>/<cluster>.yaml` (`sizes: { large: ... }`).
- One node: put `size` on the node itself.
- A resize reboots the VM and terraform does all nodes of the type in parallel. Roll one node at a time:
  `atmos terraform apply infra -s <stack> -target='<vm resource>["worker-1"]'`, then the next, then a full apply.
  VM resource: aws `aws_instance.node`, azure `azurerm_linux_virtual_machine.node`, gcp `google_compute_instance.node`,
  openstack `openstack_compute_instance_v2.node`. Disks only grow. Check the cloud quota (vCPU per family/region) first.

## Change roles or node type of an existing node

Kubemarine cannot change roles in place: `remove_node`, change the stack, `add_node`. Changing only labels/taints of a
running node: update the stack (for future joins) and tell the user to apply them with `kubectl label` / `kubectl taint`.

## Topology rules of thumb

- Size classes keep clusters portable: prefer a class over a literal VM size in `clusters/*`.
- A new size class (e.g. `gpu`) needs a key in `sizes` of **every** provider `_defaults` the cluster is placed in.
- A new node type for all clusters → `catalog/node-types.yaml`; for one cluster → its `clusters/<cluster>.yaml`.
- Unknown `type` fails `terraform plan` (validation in the shared nodes module).
