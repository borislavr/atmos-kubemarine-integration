# Workflow `cluster`

Ручной запуск ([cluster.yaml](cluster.yaml)) операций над кластером из GitHub Actions — тех же команд atmos, что и локально:

| `action` | Что делает |
|---|---|
| `plan` | `atmos terraform plan infra` — что изменится в облаке |
| `deploy` | `terraform apply infra` → `kubemarine install` → `helmfile apply` для `apps` |
| `infra` | `atmos terraform apply infra` (создать/изменить ресурсы в облаке) |
| `kubemarine` | `atmos kubemarine <input kubemarine>`: `install`, `add_node --nodes worker-3`, `remove_node --nodes worker-3`, `upgrade`, `install -- --tasks deploy.plugins`, ... |
| `apps` | `atmos kubeconfig` → `atmos helmfile apply` для каждого компонента из `apps` (по умолчанию `kafka`) |
| `destroy` | `atmos terraform destroy infra`; нужно повторить имя стека в `confirm` |

Входные параметры: `stack` (`<cluster>-<cloud>`, например `test-azure`), `action`, `kubemarine`, `apps`, `confirm`, `dry_run`.
Облако определяется по суффиксу стека; используются только секреты этого облака.

Запуск: **Actions → cluster → Run workflow**, или из консоли:

```sh
gh workflow run cluster.yaml -f stack=test-azure -f action=plan
gh workflow run cluster.yaml -f stack=test-azure -f action=deploy -f dry_run=true
gh workflow run cluster.yaml -f stack=test-azure -f action=deploy
gh workflow run cluster.yaml -f stack=test-azure -f action=kubemarine -f kubemarine="add_node --nodes worker-3"
gh workflow run cluster.yaml -f stack=test-azure -f action=apps -f apps=kafka
gh workflow run cluster.yaml -f stack=full-cluster-aws -f action=deploy -f apps="monitoring kafka"   # порядок важен: CRD мониторинга нужны kafka
gh workflow run cluster.yaml -f stack=test-azure -f action=destroy -f confirm=test-azure
gh run watch
```

Параллельные запуски для одного стека выстраиваются в очередь (`concurrency`).

## Dry run

`dry_run: true` — ничего не меняется ни в облаке, ни в кластере (firewall для раннера тоже не открывается),
в логе — что было бы сделано:

| `action` | В режиме dry run |
|---|---|
| `deploy` | всё, что ниже для `infra`, `kubemarine install` и `apps` |
| `infra` | `atmos terraform plan infra` |
| `kubemarine` | `atmos kubemarine ... --dry-run`: итоговые `cluster.yaml` / `procedure.yaml` и команда kubemarine, без запуска (для `add_node` видно, какие ноды уходят в `procedure.yaml`) |
| `apps` | `atmos helmfile template` — список ресурсов, которые будут применены (рендер без обращения к кластеру; сами манифесты не печатаются — в них пароли) |
| `destroy` | `atmos terraform plan -destroy`; `confirm` не нужен |

Секреты облака нужны и в dry run: terraform читает state и ресурсы.
Для `deploy` по ещё не созданному кластеру в `cluster.yaml` будет `"nodes": null` — ноды появятся после `infra`.

## Доступ раннера к кластеру

SSH и Kubernetes API нод открыты только для `admin_cidr` из стека. Для `deploy`, `kubemarine` и `apps` workflow
временно добавляет IP раннера (terraform-переменная `ci_cidr`, точечный `apply` правила firewall),
ждёт, пока ноды станут доступны по SSH, и в конце — в том числе при ошибке — убирает IP обратно.
`plan`, `infra` и `destroy` доступа к нодам не требуют.

kubeconfig в CI не хранится: `apps` получает его командой `atmos kubeconfig -s <stack>` (по SSH с control-plane),
`deploy` — из `kubemarine install`.

## Секреты

**Settings → Secrets and variables → Actions → New repository secret**, или `gh secret set NAME`.
Нужны общие секреты и секреты тех облаков, в которых вы запускаете стеки.
Значения, которые не являются секретами (подписка Azure, AWS-профиль, проект GCP, имя облака OpenStack, регион, бакет state),
уже лежат в `stacks/providers/<cloud>/_defaults.yaml`.

### Общие

| Секрет | Зачем | Как получить |
|---|---|---|
| `KAFKA_ADMIN_PASSWORD`, `KAFKA_CLIENT_PASSWORD` | пароли qubership-kafka (`ref+envsubst://...` в `stacks/catalog/kafka/defaults.yaml`); admin — также логин в AKHQ и Cruise Control | придумать: `openssl rand -base64 24 \| gh secret set KAFKA_ADMIN_PASSWORD` |
| `GRAFANA_ADMIN_PASSWORD` | пароль `admin` в Grafana компонента `monitoring` (`stacks/catalog/monitoring.yaml`); нужен, только если ставите `monitoring` | придумать: `openssl rand -base64 24 \| gh secret set GRAFANA_ADMIN_PASSWORD` |

SSH-ключ нод в секретах GitHub не нужен: у каждого кластера свой ключ в секрет-менеджере облака (README,
«SSH-ключ кластера»). Шаг **SSH key** создаёт его для нового кластера (`deploy`/`infra`, `atmos sshkey ensure`) и один раз
читает в `$RUNNER_TEMP` для `deploy`/`kubemarine`/`apps`. Облачной роли CI нужен доступ к этому хранилищу (ниже).

Рекомендуемый способ входа в облака — **OIDC**: GitHub выдаёт workflow короткоживущий токен, облако обменивает его на
временные креды; долгоживущих ключей в секретах нет. Доверие ограничено репозиторием и веткой
(`repo:borislavr@19729448/atmos-kubemarine-integration@1426618043:ref:refs/heads/main`) — запуск workflow с другой ветки
потребует ещё одного федеративного удостоверения / условия. Статические ключи поддерживаются как запасной вариант.

### Azure

| Секрет | Обязателен | Значение |
|---|---|---|
| `AZURE_CLIENT_ID` | да | Application (client) ID приложения Entra ID |
| `AZURE_TENANT_ID` | да | Directory (tenant) ID |
| `AZURE_CLIENT_SECRET` | нет | client secret; если не задан — вход через OIDC |

Подписка берётся из `env.ARM_SUBSCRIPTION_ID` в `stacks/providers/azure/_defaults.yaml`.

```sh
export MSYS_NO_PATHCONV=1                                   # только в Git Bash
SUB=$(az account show --query id -o tsv)
TENANT=$(az account show --query tenantId -o tsv)

# приложение + service principal
APP_ID=$(az ad app create --display-name gh-atmos-kubemarine --query appId -o tsv)
az ad sp create --id "$APP_ID"

# OIDC: доверять токенам GitHub Actions этого репозитория из ветки main
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:borislavr@19729448/atmos-kubemarine-integration@1426618043:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'

# права: ресурсы кластеров в подписке + state в storage account
az role assignment create --assignee "$APP_ID" --role Contributor --scope "/subscriptions/$SUB"
az role assignment create --assignee "$APP_ID" --role "Storage Blob Data Contributor" \
  --scope "$(az storage account show -n tfstate3a9387c7 -g tfstate --query id -o tsv)"
# SSH-ключи кластеров (atmos sshkey): чтение и создание секретов в Key Vault
az role assignment create --assignee "$APP_ID" --role "Key Vault Secrets Officer" \
  --scope "$(az keyvault show -n kvatmos3a9387c7 --query id -o tsv)"

gh secret set AZURE_CLIENT_ID --body "$APP_ID"
gh secret set AZURE_TENANT_ID --body "$TENANT"

# вместо OIDC (не рекомендуется): секрет приложения
# az ad app credential reset --id "$APP_ID" --display-name github --years 1 --query password -o tsv | gh secret set AZURE_CLIENT_SECRET
```

### AWS

| Секрет | Обязателен | Значение |
|---|---|---|
| `AWS_ROLE_ARN` | да, для OIDC | ARN роли, которую принимает workflow |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | вместо роли | ключи IAM-пользователя |

Профиль `AWS_PROFILE` из стека workflow создаёт сам из полученных кредов; регион — из стека.

```sh
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# OIDC-провайдер GitHub (один раз на аккаунт)
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com

cat > trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:borislavr@19729448/atmos-kubemarine-integration@1426618043:ref:refs/heads/main"
      }
    }
  }]
}
EOF
aws iam create-role --role-name gh-atmos-kubemarine --assume-role-policy-document file://trust.json

# права: VPC/EC2 для кластеров + бакет state (имя — backend.s3.bucket в stacks/providers/aws/_defaults.yaml)
aws iam attach-role-policy --role-name gh-atmos-kubemarine --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
aws iam put-role-policy --role-name gh-atmos-kubemarine --policy-name tfstate --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::my-tfstate-aws" },
    { "Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], "Resource": "arn:aws:s3:::my-tfstate-aws/*" },
    { "Effect": "Allow", "Action": ["secretsmanager:CreateSecret", "secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue"],
      "Resource": "arn:aws:secretsmanager:*:*:secret:atmos/*" }
  ]
}'

gh secret set AWS_ROLE_ARN --body "arn:aws:iam::${ACCOUNT}:role/gh-atmos-kubemarine"

# вместо OIDC (не рекомендуется): IAM-пользователь с теми же политиками
# aws iam create-access-key --user-name <user>  -> AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
```

### GCP

| Секрет | Обязателен | Значение |
|---|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | да, для OIDC | `projects/<номер>/locations/global/workloadIdentityPools/github/providers/github` |
| `GCP_SERVICE_ACCOUNT` | да, для OIDC | email сервисного аккаунта |
| `GCP_CREDENTIALS_JSON` | вместо OIDC | JSON-ключ сервисного аккаунта |

Проект — `vars.project` в `stacks/providers/gcp/_defaults.yaml`.

```sh
PROJECT=my-gcp-project
NUM=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
SA=gh-atmos-kubemarine@${PROJECT}.iam.gserviceaccount.com

gcloud iam service-accounts create gh-atmos-kubemarine --project "$PROJECT"
gcloud projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:$SA" --role roles/compute.admin
gcloud storage buckets add-iam-policy-binding gs://my-tfstate-gcp --member "serviceAccount:$SA" --role roles/storage.objectAdmin
gcloud projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:$SA" --role roles/secretmanager.admin   # SSH-ключи кластеров

# Workload Identity Federation: пул + OIDC-провайдер GitHub, только этот репозиторий
gcloud iam workload-identity-pools create github --project "$PROJECT" --location global
gcloud iam workload-identity-pools providers create-oidc github --project "$PROJECT" --location global \
  --workload-identity-pool github --issuer-uri https://token.actions.githubusercontent.com \
  --attribute-mapping "google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
  --attribute-condition "assertion.repository=='borislavr/atmos-kubemarine-integration' && assertion.ref=='refs/heads/main'"
gcloud iam service-accounts add-iam-policy-binding "$SA" --project "$PROJECT" --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/$NUM/locations/global/workloadIdentityPools/github/attribute.repository/borislavr/atmos-kubemarine-integration"

gh secret set GCP_WORKLOAD_IDENTITY_PROVIDER --body "projects/$NUM/locations/global/workloadIdentityPools/github/providers/github"
gh secret set GCP_SERVICE_ACCOUNT --body "$SA"

# вместо OIDC (не рекомендуется): ключ сервисного аккаунта
# gcloud iam service-accounts keys create key.json --iam-account "$SA" && gh secret set GCP_CREDENTIALS_JSON < key.json && rm key.json
```

### OpenStack

| Секрет | Обязателен | Значение |
|---|---|---|
| `OPENSTACK_CLOUDS_YAML` | да | содержимое `clouds.yaml` с облаком, имя которого указано в `env.OS_CLOUD` стека |
| `OPENSTACK_S3_ACCESS_KEY`, `OPENSTACK_S3_SECRET_KEY` | да | EC2-креды для state в объектном хранилище (S3 API) |
| `VAULT_TOKEN` | да | токен HashiCorp Vault с доступом к KV, где лежат SSH-ключи кластеров (`stores.ssh-keys-openstack`) |

У OpenStack нет OIDC для GitHub — используется application credential (ограниченный по проекту и времени жизни, отзывается отдельно от пароля пользователя).

```sh
export OS_CLOUD=my-cloud                                   # ваш обычный (пользовательский) доступ
openstack application credential create gh-atmos-kubemarine --expiration 2027-12-31T00:00:00 -f json
# -> id, secret

cat > clouds-ci.yaml <<EOF
clouds:
  my-cloud:                                                 # = env.OS_CLOUD в stacks/providers/openstack/_defaults.yaml
    auth_type: v3applicationcredential
    auth:
      auth_url: https://keystone.example.com:5000/v3
      application_credential_id: <id>
      application_credential_secret: <secret>
    region_name: RegionOne
    interface: public
    identity_api_version: 3
EOF
gh secret set OPENSTACK_CLOUDS_YAML < clouds-ci.yaml && rm clouds-ci.yaml

openstack ec2 credentials create -f json                    # -> access, secret
gh secret set OPENSTACK_S3_ACCESS_KEY --body "<access>"
gh secret set OPENSTACK_S3_SECRET_KEY --body "<secret>"
```

## Проверка

```sh
gh secret list                                              # имена заведённых секретов
gh workflow run cluster.yaml -f stack=test-azure -f action=plan && gh run watch
```
`plan` проверяет вход в облако и доступ к state, ничего не меняя.

## Если в разных стеках разные аккаунты

Секреты репозитория общие для всех стеков одного облака. Если, например, `prod-azure` живёт в другом tenant/подписке —
заведите GitHub Environment на стек (`Settings → Environments`), положите секреты туда и добавьте в job
`environment: ${{ inputs.stack }}`; там же можно включить ручное подтверждение (required reviewers) для prod.
