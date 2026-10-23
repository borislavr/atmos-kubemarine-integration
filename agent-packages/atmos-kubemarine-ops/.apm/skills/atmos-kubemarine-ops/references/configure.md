# Change configuration

## 1. Locate, then choose the layer

1. Read the current value and its source: `atmos_stack_config_get(component, stack, path)` →
   `value (resolves from <file>:<line>)`. Without MCP: `atmos describe component <c> -s <stack> --process-functions=false`
   for the value, `grep -rn` over the stack's imports for the file.
2. Ask (or infer from the request) the scope, then edit that layer - not the file the value happens to resolve from:

| The user means | Edit |
|---|---|
| every cluster | `stacks/catalog/...` |
| every cluster using profile X | `stacks/catalog/<app>/<profile>.yaml` |
| this cluster, every cloud | `stacks/clusters/<cluster>.yaml` |
| this cloud, every cluster | `stacks/providers/<cloud>/_defaults.yaml` |
| exactly one stack | `stacks/providers/<cloud>/<cluster>.yaml` |

3. Overriding part of a list means repeating the whole list in the higher layer.
4. Check the blast radius: every stack whose import chain contains the edited file (`atmos list stacks` +
   `describe_affected`) - and describe the component in each.

## 2. Apply it the right way

| What changed | How it reaches the cluster |
|---|---|
| app `values` / `credentials` | `atmos helmfile diff <app> -s <stack>` → `apply` (approval) |
| kubemarine `vars.cluster` - plugins, services | `atmos kubemarine install -s <stack> -- --tasks <task list>` (e.g. `deploy.plugins`) or the dedicated maintenance procedure; dry-run first |
| PSS settings / exemptions | kubemarine `manage_pss` procedure with a `vars.procedures.manage_pss` procedure.yaml |
| node labels / taints of running nodes | `kubectl label` / `kubectl taint` (kubemarine applies them only on join) |
| `infra` vars (admin_cidr, admin_ports, region, cidr) | `terraform plan` → apply. `region` / `cidr` changes recreate the network and VMs = a new cluster: stop and warn |

## 3. Credentials

- Changing a `ref+...` target (env var → secret manager) changes nothing in the cluster as long as the value is the same.
- `helmfile apply` with a **different** secret value rewrites the app's Secret: clients lose access. Before applying
  locally, make sure the env vars hold the values the cluster already uses (they can be read from the cluster Secret -
  never echo them; copy to the clipboard).
- New secret → `ref+envsubst://$NAME` in the catalog, `env:` + check in the workflow, README secrets table.

## 4. Access to the cluster

- SSH/API are open only for `admin_cidr` (+ `ci_cidr` during CI runs). Temporarily for this machine:
  `TF_VAR_ci_cidr=<ip>/32 atmos terraform apply infra -s <stack> -target=<firewall resource>`; close it again with
  `TF_VAR_ci_cidr=""` and the same target. Firewall resource per cloud: aws `aws_security_group.this`, azure
  `azurerm_network_security_group.this`, gcp `google_compute_firewall.admin`, openstack
  `openstack_networking_secgroup_rule_v2.admin`.
- No local kubeconfig (or the cluster was recreated): `atmos kubeconfig -s <stack>`.
