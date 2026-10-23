---
name: atmos-kubemarine-ops
description: Use when changing or operating a repository that manages Kubernetes clusters with atmos stacks, kubemarine and helmfile (stacks/providers, stacks/clusters, stacks/catalog, components/terraform, components/helmfile) - scaling or resizing nodes, adding a helmfile app, changing cluster or app configuration, upgrading Kubernetes, chart or tool versions, or preparing a deploy/apps run. Picks the right stack layer, edits YAML, verifies with atmos; never changes a live cluster without explicit confirmation.
---

# atmos-kubemarine-ops

## What this does

Make a change to an atmos + kubemarine + helmfile cluster repository the way its authors would: in the right stack
layer, rendered and validated before anything touches a cloud or a cluster, with the apply commands handed to the user
in the order that keeps the cluster alive.

## Hard rules

- **The stack is the source of truth.** Never edit generated files: `.kubemarine/<stack>/*` (cluster.yaml,
  procedure.yaml, kubeconfig), `*.terraform.tfvars.json`, `backend.tf.json`, `*.helmfile.vars.yaml`, `apm_modules/`.
- **Find where a value comes from before changing it.** A value lives in exactly one layer file and every stack that
  imports that file gets the change. Read its provenance first (see *Tools*), then pick the layer by the scope the user
  wants (table below). Never "fix" a shared catalog file to change one cluster.
- **Live changes need the user's go-ahead, every time.** Free to run: `atmos list|describe|validate`,
  `atmos terraform plan`, `atmos kubemarine <proc> --dry-run`, `atmos helmfile template|diff`. Show the result, then
  ask before: `terraform apply|destroy`, `kubemarine install|add_node|remove_node|upgrade|...` without `--dry-run`,
  `helmfile apply|sync|destroy`, `gh workflow run`, firewall changes. Approval for one step is not approval for the next.
- **Secrets never land in the repo.** Stacks hold `ref+envsubst://$VAR` (or `ref+<secret manager>://...`) references;
  the value comes from the environment or CI secrets. Never print a secret read from a cluster; copy it to the clipboard
  or show the command that prints it.
- **Keep the template delimiters.** Stack manifests use atmos Go templates with `<% %>`; `{{ }}` belongs to kubemarine
  (jinja) and helm values and must stay literal in stacks.

## Repository model

Verify on the repo you are in (`atmos.yaml`: `stacks.name_template`, `stacks.included_paths`, `commands`); the usual
layout is:

| Layer (lowest → highest precedence) | Holds | Scope of an edit |
|---|---|---|
| `stacks/providers/<cloud>/_defaults.yaml` | backend, cloud env (subscription/profile), region, size classes → VM sizes | every cluster in that cloud |
| `stacks/catalog/*` (node-types, kubemarine, `<app>/defaults` + profiles) | shared defaults | every cluster that imports the file |
| `stacks/clusters/<cluster>.yaml` | nodes, node types, cluster.yaml settings, which app profiles to import, app overrides | that cluster in every cloud |
| `stacks/providers/<cloud>/<cluster>.yaml` | the stack `<cluster>-<cloud>`: imports + overrides | that one stack |

Merge: imports first (depth-first, in order), then the file's own content. Maps merge key by key; **lists and scalars
replace** (an override of `taints`, `racks`, `environmentVariables` must repeat the whole list).

Components:

- `infra` (terraform, `metadata.component: <cloud>`): network, firewall (`admin_cidr` + CI-only `ci_cidr`), VMs from
  `nodes` × `node_types` × `sizes`; single output `nodes` (name, address, internal_address, roles, labels, taints).
- `kubemarine` (abstract terraform component): `vars.cluster` = cluster.yaml, `nodes: !terraform.output infra nodes`;
  `vars.procedures.<name>` = procedure.yaml. Rendered and run by the custom command `atmos kubemarine <proc> -s <stack>`.
- helmfile apps (`components/helmfile/<app>`): `vars` become helmfile state values; secrets resolved by vals
  (`fetchSecretValue`); `env.KUBECONFIG` points at `.kubemarine/<stack>/kubeconfig`.

## Tools

Prefer the atmos MCP server when its tools are available; fall back to the CLI.

| Need | MCP tool | CLI |
|---|---|---|
| stacks and their components | `atmos_list_stacks` | `atmos list stacks` |
| effective config of a component | `atmos_describe_component` | `atmos describe component <c> -s <stack> --process-functions=false` |
| value **and the file:line it comes from** | `atmos_stack_config_get` | `grep -rn '<key>:' stacks/` over the stack's import chain; the highest layer wins |
| set a value | `atmos_stack_config_set` | edit the layer file |
| one section across all stacks | `atmos_list_values` (top-level query only: `.vars`, not `.vars.a.b`) | `atmos describe stacks --components <c> --sections vars --process-functions=false --format json` |
| what a change touches | `describe_affected` | `atmos describe affected` |
| validate | `atmos_validate_stacks` | `atmos validate stacks` |

`atmos_stack_config_set` writes to the file the value currently resolves from. When the target layer differs (e.g. the
value comes from a catalog profile but the change is for one cluster), pass `file` explicitly or edit the layer file
yourself. `--process-functions=false` skips `!terraform.output` (which needs terraform, cloud credentials and state).

## Verify every change

1. `atmos validate stacks`.
2. For each affected stack (`describe_affected`, or every stack importing the edited file):
   `atmos describe component <c> -s <stack> --process-functions=false` shows the value you intended - and nothing else
   moved.
3. Render offline: `atmos terraform plan infra -s <stack>` (needs cloud credentials), `atmos kubemarine <proc> -s <stack>
   --dry-run`, `atmos helmfile template <app> -s <stack>` (export dummy values for the app's `ref+envsubst` variables;
   do not print the rendered secrets).
4. Update the README / docs when behaviour or the operator's commands change.
5. Hand over the apply commands in order, with what each one changes, and wait for the user.

## Task router

- Add, remove or resize nodes; node types; control-plane / balancer topology → LOAD references/scale-cluster.md
- Add a new helmfile app or a second instance of one → LOAD references/add-app.md
- Change app values, cluster.yaml settings, credentials, access → LOAD references/configure.md
- Upgrade Kubernetes, charts, kubemarine, atmos, terraform, helm tooling → LOAD references/upgrade-versions.md
- Run any of it through the GitHub workflow instead of locally → LOAD references/workflow.md
