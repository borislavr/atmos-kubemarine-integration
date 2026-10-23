# Add a helmfile app

Copy the shape of an existing app component (e.g. `components/helmfile/kafka`) instead of inventing one. An app is:

| Piece | Path | Content |
|---|---|---|
| component | `components/helmfile/<app>/helmfile.yaml.gotmpl` | releases; every setting from `.Values` (the stack `vars`) |
| values template | `components/helmfile/<app>/values.yaml.gotmpl` | `mergeOverwrite (deepCopy .Values.values) <secrets dict> \| toYaml`; secrets via `fetchSecretValue` |
| defaults | `stacks/catalog/<app>/defaults.yaml` (+ size profiles importing it) or `stacks/catalog/<app>.yaml` | `components.helmfile.<app>.vars`: chart version, release_name, namespace, `credentials` (`ref+envsubst://$VAR`), `values` |
| enablement | `import: - catalog/<app>/<profile>` in `stacks/clusters/<cluster>.yaml` | app appears in every placement of the cluster |

## Steps

1. **Chart source.** Find how the chart is published: helm repo (`repositories:` + `chart: repo/name`), OCI, GitHub
   release asset (`chart: https://.../<name>-<version>.tgz`), or only git (`chart: git::https://...git@<path>?ref=<tag>`).
   - git sources on Windows can hit the 260-char path limit: set `GIT_CONFIG_COUNT=1`, `GIT_CONFIG_KEY_0=core.longpaths`,
     `GIT_CONFIG_VALUE_0="true"` in the component `env`.
   - Helm stores the top-level chart in a release Secret (1 MiB limit after gzip+base64). A chart with megabytes of CRDs
     in its own `crds/` fails to install; CRDs inside subcharts are not stored and are fine.
2. **Read the chart's values and prerequisites** (`helm show values <chart>`, install guide): required credentials,
   CRDs it needs from other apps (ServiceMonitor, PrometheusRule, GrafanaDashboard, Gateway API, cert-manager), the
   default ingress / gateway / monitoring toggles. Turn off anything whose CRDs the cluster does not have.
3. **Write the component and catalog.** Keep the stack free of secrets: `credentials.<x>_password: ref+envsubst://$APP_X`.
   For CRD-bearing first installs add `disableValidationOnInstall: true`; for releases that depend on another release of
   the same component use `needs: [<ns>/<release>]`.
4. **Order between apps.** If the app needs another app's CRDs, document the order (CI input `apps: "monitoring <app>"`).
5. **Secrets in CI.** Add each new env var to the workflow `env:` (from `secrets.*`), a "secret is set" check in the
   helmfile step, and a row in the workflow README secrets table.
6. **Pod Security.** If the cluster enforces PSS `restricted`, check the chart's pods (hostNetwork/hostPath/privileged,
   missing `runAsNonRoot`/`seccompProfile`/dropped caps). Exempt the namespace in the kubemarine `rbac.pss.exemptions`
   of that cluster only when needed, and say that an installed cluster needs a kubemarine PSS procedure to apply it.
7. **Capacity.** Sum the requests against schedulable workers (tainted workers and control-planes excluded). With
   `local-path` storage the PVC size is not enforced: the node disk (`disk_size`) is the real limit.
8. **Verify:** `atmos validate stacks`; `atmos helmfile template <app> -s <stack>` with dummy secret env vars, list the
   rendered kinds/names (`awk '/^kind:/{k=$2} /^  name:/ && k {print k"/"$2; k=""}'`), check for name collisions with
   other releases in the namespace. Then `atmos helmfile diff` against the cluster (needs access) before `apply`.
9. **Access** to a UI: port-forward (`kubectl -n <ns> port-forward svc/<svc> <port>`) needs only API access; an ingress
   also needs 80/443 open in the firewall (`admin_ports`).

## A second instance of the same app

Inherit the component instead of copying the folder:

```yaml
components:
  helmfile:
    kafka-events:
      metadata: { component: kafka, inherits: [kafka] }
      vars:
        release_name: kafka-events
        namespace: kafka-events
        # plus every chart value that encodes the instance name (e.g. global.name / service names)
```
