# Upgrade versions

## 1. Inventory what is pinned, and where

Grep instead of assuming; typical places:

| Version | Where | Check for newer |
|---|---|---|
| app chart | `stacks/catalog/<app>/defaults.yaml` (`chart_version`, `version`) | `gh release list -R <owner>/<repo>` or `helm search repo <chart> --versions` |
| Kubernetes | `kubemarine.vars.cluster.services.kubeadm.kubernetesVersion` (cluster layer); absent = kubemarine default | versions supported by the pinned kubemarine release (its release notes) |
| kubemarine, atmos, terraform, helm, helmfile, helm-diff | `.github/workflows/*.yaml` `env:` (`*_VERSION`), README install table | `gh release list -R Netcracker/KubeMarine`, `cloudposse/atmos`, `hashicorp/terraform`, `helm/helm`, `helmfile/helmfile`, `databus23/helm-diff` |
| terraform providers | `required_providers` in `components/terraform/*/main.tf` (lock file is not committed) | provider changelogs |
| VM image | image filter / variable in `components/terraform/<cloud>/` | cloud image catalog |

`grep -rnE '(version|_VERSION|Version)[:=]' stacks components .github atmos.yaml` gives a quick map.

## 2. Bump an app chart

1. Read the release notes between the two versions: renamed values, removed defaults, CRD changes, migration steps.
2. Diff the default values: `helm show values <old>` vs `<new>`; carry renames into the catalog / cluster overrides.
3. Change the version in the catalog (all clusters) or override it in one cluster layer for a canary.
4. `atmos helmfile template <app> -s <stack>` for every affected stack; compare kinds/names with the old render.
5. **CRDs:** helm installs `crds/` only on first install and never upgrades them. If the new chart changes CRDs, the
   upgrade needs `kubectl apply --server-side -f <crds>` (or the chart's own CRD job) before `helmfile apply` - say so.
6. `atmos helmfile diff` against the cluster, then apply after approval; canary cluster first.

## 3. Upgrade Kubernetes

1. One minor version at a time; each target must be supported by the kubemarine version in use (upgrade kubemarine
   first if not - same binary locally and in CI).
2. Put the plan into the cluster layer:
   ```yaml
   kubemarine:
     vars:
       procedures:
         upgrade:
           upgrade_plan: [v1.34.3]
   ```
3. `atmos kubemarine upgrade -s <stack> --dry-run` (check procedure.yaml), `atmos kubemarine backup -s <stack>` first,
   then the upgrade after approval.
4. After success set `services.kubeadm.kubernetesVersion` to the new version in the same layer and drop the
   `upgrade_plan`, so the next `install` / `add_node` renders the version the cluster actually runs.
5. Before planning the upgrade, check every app chart's supported Kubernetes range and removed APIs it still uses
   (chart notes, `helm template` output vs `kubectl api-resources` on the new version).

## 4. Tooling (CI and local)

- Bump the `*_VERSION` in the workflow `env:` and the README install table together; local tools should match CI
  (kubemarine especially: it decides which k8s versions and cluster.yaml schema are valid).
- atmos: re-run `atmos validate stacks`, `atmos describe component` for each component type and one
  `atmos kubemarine <proc> --dry-run` - custom commands and YAML functions are the usual breakage.
- terraform / providers: `atmos terraform plan infra -s <stack>` on every cloud placement; expect no changes.
