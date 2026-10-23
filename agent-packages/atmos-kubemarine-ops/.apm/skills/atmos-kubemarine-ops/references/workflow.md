# Run through the GitHub workflow

Read the workflow first (`.github/workflows/*.yaml`, usually `cluster.yaml`, manual `workflow_dispatch`); the usual inputs:

| Input | Meaning |
|---|---|
| `stack` | `<cluster>-<cloud>` (`atmos list stacks`); the cloud is the suffix, only its secrets are used |
| `action` | `plan` · `infra` (terraform apply) · `kubemarine` (any procedure) · `apps` (helmfile apply of `apps`) · `deploy` (infra → kubemarine install → apps) · `destroy` (needs `confirm` = stack) |
| `kubemarine` | for `action=kubemarine`: `install`, `add_node --nodes worker-3`, `install -- --tasks deploy.plugins`, ... |
| `apps` | space-separated helmfile components, **in dependency order** (e.g. `monitoring kafka`) |
| `dry_run` | plan / `--dry-run` / `helmfile template` only; no firewall change |

The runner opens the firewall for its own IP (`ci_cidr`) for `deploy`/`kubemarine`/`apps` and closes it at the end.

## Map tasks to runs

| Task | Runs, in order |
|---|---|
| add a node | `action=infra` → `action=kubemarine`, `kubemarine="add_node --nodes worker-N"` |
| remove a node | `action=kubemarine`, `kubemarine="remove_node --nodes worker-N"` → stack change merged → `action=infra` |
| new / changed app | `action=apps`, `apps="<deps> <app>"` |
| new cluster | `action=deploy`, `apps="..."` |
| anything | the same with `dry_run=true` first |

The workflow runs the committed stack of the chosen ref: the stack change must be pushed (and usually merged) first.

```sh
gh workflow run cluster.yaml -f stack=<stack> -f action=<action> [-f kubemarine="..."] [-f apps="..."] -f dry_run=true
gh run watch
```

Each run writes a job summary (inputs, terraform plan/apply, kubemarine status and log tail). New secrets for apps must
exist in the repository secrets before the run (`gh secret list`).
