# atmos-kubemarine-integration

[atmos](https://atmos.tools) создаёт сеть и VM в AWS / GCP / Azure / OpenStack (terraform),
затем custom command `atmos kubemarine` ставит и обслуживает Kubernetes через
[KubeMarine](https://github.com/Netcracker/KubeMarine), запущенный локально. Jump-хост не нужен.

```
atmos.yaml                          # настройки atmos + custom command `atmos kubemarine`
components/terraform/
  aws | gcp | azure | openstack     # сеть + firewall + VM; единый выход `nodes` (name, address, internal_address, roles, labels, taints)
  modules/nodes                     # общая модель нод: типы, классы размеров, переопределения
components/helmfile/
  kafka                             # qubership-kafka (helmfile), все настройки — из стека
stacks/
  catalog/kubemarine.yaml           # общий cluster.yaml (nodes = !terraform.output infra nodes)
  catalog/node-types.yaml           # базовые типы нод: balancer / control-plane / worker (размер — класс)
  catalog/kafka/                    # qubership-kafka: defaults + профили small / medium / large / xlarge
  clusters/<cluster>.yaml           # КЛАСТЕР, без провайдера: ноды, admin_cidr, cluster.yaml kubemarine
  providers/<cloud>/_defaults.yaml  # ПРОВАЙДЕР: state backend, env (подписка/профиль), регион, классы размеров -> VM
  providers/<cloud>/<cluster>.yaml  # РАЗМЕЩЕНИЕ = стек `<cluster>-<cloud>`: import двух файлов выше + правки под это облако
  workflows/cluster.yaml            # deploy / destroy
.kubemarine/<stack>/                # рабочая папка kubemarine: cluster.yaml, procedure.yaml, kubeconfig, dump/, отчёты (не в git)
```

Описание кластера не знает про облако; всё облачное — в `providers/<cloud>/`. Стек — это пара «кластер × облако»,
имя `<cluster>-<cloud>` (`name_template` в atmos.yaml): `test-azure`, `test-aws`, `full-cluster-azure`.
Один и тот же кластер можно разместить в нескольких облаках одновременно.

Порядок слоёв (deep merge, каждый следующий переопределяет предыдущий поле за полем):
`providers/<cloud>/_defaults` → `catalog/*` → `clusters/<cluster>` → `providers/<cloud>/<cluster>`.

Размеры VM — **классы** (`small`, `medium`, `large`, `xlarge`). Тип ноды говорит «worker = large», а каждый
провайдер в `sizes` переводит класс в свой размер (`large` → `Standard_D8s_v5` / `m6i.2xlarge` / `e2-standard-8` / `m1.xlarge`).
Поэтому кластер переносится между облаками без правок. Конкретный размер облака тоже можно указать:
то, чего нет в `sizes`, передаётся как есть.

## 1. Что установить

| Инструмент | Зачем | Установка |
|---|---|---|
| atmos ≥ 1.200 | оркестрация | https://atmos.tools/install |
| terraform ≥ 1.10 | ресурсы в облаке | https://developer.hashicorp.com/terraform/install |
| kubemarine | установка k8s | бинарник из [релизов](https://github.com/Netcracker/KubeMarine/releases) (`kubemarine-win64.exe` / `-linux-x86_64` / `-macos14-*`) переименовать в `kubemarine` и положить в `PATH` (или `pip install kubemarine`) |
| CLI облака | логин | `az`, `aws`, `gcloud`, `openstack` |
| SSH-ключ | доступ к VM | `ssh-keygen -t ed25519` → `~/.ssh/id_ed25519` |
| helm 3 + helmfile 1.x + helm-diff | приложения в кластере | [helm](https://github.com/helm/helm/releases), [helmfile](https://github.com/helmfile/helmfile/releases), `helm plugin install https://github.com/databus23/helm-diff` (на Windows без `pwsh` — положить `diff.exe` из релиза в `$(helm env HELM_PLUGINS)/helm-diff/bin/`) |

На Windows запускайте команды из **Git Bash**: шагам `atmos kubemarine` нужен `mkdir`, а atmos и kubemarine должны быть в `PATH`.
Для `kubectl` с локальной машины нужен `kubectl`.

## 2. Креды облаков: где хранить и как atmos их получает

Правило: **в репозитории только указатели (ID подписки, имя профиля, имя облака), секреты — в штатных хранилищах CLI облака или в секретах CI.**
Atmos передаёт terraform (и `!terraform.output`) переменные из секции `env:` стека, а terraform-провайдеры
сами находят креды по стандартной цепочке (env → файлы CLI → токен `az login`).

| Облако | Секрет хранится | Указатель (`providers/<cloud>/_defaults.yaml`, `env:`) | Локально | CI |
|---|---|---|---|---|
| Azure | кэш токенов `az login` (`~/.azure`) | `ARM_SUBSCRIPTION_ID` | `az login --tenant <id>` | `ARM_CLIENT_ID`, `ARM_TENANT_ID` + OIDC (`ARM_USE_OIDC=true`) или `ARM_CLIENT_SECRET` |
| AWS | `~/.aws/config` + SSO-кэш / `~/.aws/credentials` | `AWS_PROFILE` | `aws configure sso`, `aws sso login --profile X` | OIDC-роль (`aws-actions/configure-aws-credentials`) или `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` |
| GCP | ADC (`~/.config/gcloud/application_default_credentials.json`) | `vars.project` | `gcloud auth application-default login` | Workload Identity Federation или `GOOGLE_APPLICATION_CREDENTIALS` |
| OpenStack | `~/.config/openstack/clouds.yaml` + пароль/app credential в `secure.yaml` | `OS_CLOUD` | заполнить `clouds.yaml` | `OS_AUTH_URL`, `OS_APPLICATION_CREDENTIAL_ID/SECRET`, ... |
| OpenStack state (S3 API) | `~/.aws/credentials`, профиль `openstack-tfstate` (ключи из `openstack ec2 credentials create`) | `backend.s3.profile` | — | `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` |

SSH: публичный ключ (`ssh_public_key_file`, по умолчанию `~/.ssh/id_ed25519.pub`) кладётся на VM,
приватный (`cluster.node_defaults.keyfile`) использует kubemarine. В репозиторий ключи не попадают.

Если кластеру нужна другая подписка/аккаунт — переопределите `env` в его размещении `providers/<cloud>/<cluster>.yaml`.

## 3. Подготовка провайдера (один раз)

Для каждого облака: залогиниться, создать хранилище для state, вписать имена в `stacks/providers/<cloud>/_defaults.yaml`.

### Azure

```sh
az login --tenant <tenant-id>                 # MFA-тенант: только с --tenant
az account show --query id -o tsv             # -> env.ARM_SUBSCRIPTION_ID
export MSYS_NO_PATHCONV=1                     # Git Bash: не портить пути /subscriptions/...
az group create -n tfstate -l northeurope
az storage account create -n <уникальное_имя> -g tfstate -l northeurope --sku Standard_LRS --allow-blob-public-access false
az storage account blob-service-properties update -n <имя> -g tfstate --enable-versioning true
az role assignment create --assignee-object-id $(az ad signed-in-user show --query id -o tsv) \
  --assignee-principal-type User --role "Storage Blob Data Contributor" \
  --scope $(az storage account show -n <имя> -g tfstate --query id -o tsv)
az storage container create -n tfstate --account-name <имя> --auth-mode login
```
Роль применяется 1–5 минут (до этого terraform получает 403).
Проверьте доступность размеров VM и квоту в регионе:
`az vm list-skus -l <region> --size Standard_D2s_v5 --query "[].restrictions"`, `az vm list-usage -l <region> -o table`.

### AWS

```sh
aws configure sso --profile my-profile        # или aws configure --profile my-profile
aws s3 mb s3://<bucket> --region eu-central-1 --profile my-profile
aws s3api put-bucket-versioning --bucket <bucket> --versioning-configuration Status=Enabled --profile my-profile
```
В `providers/aws/_defaults.yaml`: `env.AWS_PROFILE`, `backend.s3.bucket`, `region`.

### GCP

```sh
gcloud auth login && gcloud auth application-default login
gcloud services enable compute.googleapis.com --project <project>
gcloud storage buckets create gs://<bucket> --project <project> --location=europe-west3 --uniform-bucket-level-access
gcloud storage buckets update gs://<bucket> --versioning
```
В `providers/gcp/_defaults.yaml`: `backend.gcs.bucket`, `vars.project`, `region`, `zone`.

### OpenStack

```sh
# ~/.config/openstack/clouds.yaml -> clouds.my-cloud (auth_url, project, ...), секрет в secure.yaml
export OS_CLOUD=my-cloud
openstack container create tfstate
openstack ec2 credentials create              # access/secret -> ~/.aws/credentials [openstack-tfstate]
openstack network list --external             # -> vars.external_network
openstack image list | grep -i 22.04          # -> vars.image
openstack flavor list                         # -> sizes (small/medium/large/xlarge)
```
В `providers/openstack/_defaults.yaml`: `env.OS_CLOUD`, `backend.s3.endpoints.s3` (S3 endpoint объектного хранилища), `external_network`, `image`, `sizes` (flavor-ы).

## 4. Создание кластера

1. Описание кластера, без провайдера — `stacks/clusters/prod.yaml`:

```yaml
import:
  - catalog/node-types
  - catalog/kubemarine

vars:
  stage: prod                        # имя кластера, префикс имён ресурсов в облаке

components:
  terraform:
    infra:
      vars:
        admin_cidr: 203.0.113.10/32  # откуда разрешены SSH и Kubernetes API (порты admin_ports)
        node_types:                  # необязательно: правка базовых типов для этого кластера
          worker: { size: xlarge }
        nodes:                       # имя -> тип (см. «Типы нод»)
          balancer-1:      { type: balancer }
          control-plane-1: { type: control-plane }
          control-plane-2: { type: control-plane }
          control-plane-3: { type: control-plane }
          worker-1:        { type: worker }
          worker-2:        { type: worker }

    kubemarine:
      vars:
        cluster:                     # любые ключи cluster.yaml kubemarine, deep merge с catalog/kubemarine.yaml
          cluster_name: prod.k8s.local
          services:
            kubeadm:
              kubernetesVersion: v1.33.x
```

2. Размещение в облаке — `stacks/providers/azure/prod.yaml` (это и есть стек `prod-azure`):

```yaml
import:
  - providers/azure/_defaults
  - clusters/prod

# необязательно: всё, что у этого кластера в этом облаке отличается от провайдера
components:
  terraform:
    infra:
      vars:
        region: swedencentral
        sizes: { xlarge: Standard_D16as_v5 }
```
Тот же кластер в AWS — `stacks/providers/aws/prod.yaml` с `- providers/aws/_defaults` (стек `prod-aws`).

`admin_cidr` — все адреса, с которых вы выходите в интернет. Если провайдер выпускает через пул NAT
(`curl ifconfig.me` возвращает разные IP), укажите подсеть пула, иначе SSH будет периодически отваливаться.

3. Проверить, что получилось:
```sh
atmos list stacks
atmos describe component infra -s prod-azure                                  # переменные terraform
atmos describe component kubemarine -s prod-azure --process-functions=false   # cluster.yaml до подстановки нод
atmos terraform plan infra -s prod-azure
```

4. Развернуть:
```sh
atmos workflow deploy -f cluster -s prod-azure
# то же по шагам:
atmos terraform apply infra -s prod-azure
atmos kubemarine check_iaas -s prod-azure       # необязательно: проверка VM до установки
atmos kubemarine install -s prod-azure
```

5. Подключиться: `install` кладёт kubeconfig (API — по публичному IP control-plane, порт 6443 открыт для `admin_cidr`):
```sh
export KUBECONFIG=$PWD/.kubemarine/prod-azure/kubeconfig
kubectl get nodes
```

Один control-plane — можно без балансера. Больше одного — нужен `balancer` (или `vrrp_ips` в `cluster`).

Примеры: [clusters/test.yaml](stacks/clusters/test.yaml) — минимальный (развёрнут как `test-azure`; размещения для aws/gcp/openstack тоже есть),
[clusters/full-cluster.yaml](stacks/clusters/full-cluster.yaml) — HA-кластер по мотивам
[full-cluster.yaml](https://github.com/Netcracker/KubeMarine/blob/main/examples/cluster.yaml/full-cluster.yaml) kubemarine:
2 балансера, 3 control-plane, 3 worker-а с labels/taints, kubeadm, NTP, AppArmor, RBAC/PSS, плагины.
В шапке файла перечислено, что из оригинала убрано и почему.

### Типы нод

Нода не описывает себя сама, она ссылается на **тип** — профиль с параметрами:

| Поле типа | Обязательно | Куда идёт |
|---|---|---|
| `roles` | да | роли kubemarine: `control-plane`, `worker`, `balancer` (можно несколько) |
| `size` | да | класс размера (`small`/`medium`/`large`/`xlarge`, переводится через `sizes` провайдера) или конкретный размер VM облака |
| `disk_size` | нет, 50 | системный диск, ГБ (в OpenStack задаётся flavor-ом) |
| `labels` | нет | labels ноды в Kubernetes |
| `taints` | нет | taints ноды, формат `key=value:Effect` |

Откуда берутся типы — обычный deep merge atmos, поле за полем:

```
catalog/node-types.yaml            node_types: balancer / control-plane / worker   ← базовые типы (размер — класс)
clusters/<cluster>.yaml            node_types: { worker: { size: xlarge } }        ← правка для кластера
                                   nodes: { worker-7: { type: worker, size: ... } } ← правка одной ноды
providers/<cloud>/_defaults.yaml   sizes: { large: Standard_D8s_v5, ... }           ← класс -> VM облака
providers/<cloud>/<cluster>.yaml   sizes: { large: ... }                            ← свой перевод для размещения
```

Нода = поля её типа + её собственные поля (`size`, `disk_size`, `labels` (сливаются), `taints`).
Неизвестный `type` останавливает `plan` с ошибкой. Логика — в [components/terraform/modules/nodes](components/terraform/modules/nodes/main.tf),
общая для всех облаков; тест: `cd components/terraform/modules/nodes && terraform init && terraform test`.

**Новый тип** — ещё один ключ в `node_types`: в `catalog/node-types.yaml` — для всех кластеров, в `clusters/<cluster>.yaml` — только для него.
Чтобы тип оставался переносимым, задавайте `size` классом. **Новый класс** (например, `gpu`) — ключ в `sizes` каждого провайдера.

```yaml
node_types:
  ingress:       { roles: [worker], size: medium, labels: { node-role.kubernetes.io/ingress: "" } }
  infra:         { roles: [worker], size: xlarge, disk_size: 200,
                   labels: { workload: infra }, taints: ["workload=infra:NoSchedule"] }
  cp-and-worker: { roles: [control-plane, worker], size: large }   # маленький кластер без отдельных worker-ов
nodes:
  ingress-1: { type: ingress }
  infra-1:   { type: infra }
```

## 5. `atmos kubemarine`

```
atmos kubemarine <procedure> -s <stack> [--nodes a,b] [-- <доп. аргументы kubemarine>]
```

Что делает: берёт `vars.cluster` компонента `kubemarine` из стека (ноды — из terraform outputs `infra`
через `!terraform.output`), в папке `.kubemarine/<stack>/` пишет `cluster.yaml` и при необходимости `procedure.yaml`
и запускает там `kubemarine <procedure> [procedure.yaml] --config cluster.yaml <доп. аргументы>`.
Результаты (kubeconfig, `cluster_finalized.yaml`, `dump/`, отчёты check_*) остаются в этой же папке.

- `procedure.yaml` для процедуры берётся из `vars.procedures.<procedure>` стека (например, план `upgrade`).
- `add_node` / `remove_node`: ноды из `--nodes`. Для `add_node` они исключаются из `cluster.yaml` и попадают в `procedure.yaml` (как требует kubemarine).
- `--dry-run`: только собрать и показать `cluster.yaml`, `procedure.yaml` и команду kubemarine, не запуская её.

Примеры:
```sh
atmos kubemarine check_iaas -s test-azure
atmos kubemarine add_node -s test-azure --nodes worker-3 --dry-run     # посмотреть, что уйдёт в kubemarine
atmos kubemarine install -s test-azure
atmos kubemarine install -s test-azure -- --tasks deploy.plugins          # только часть задач
atmos kubemarine check_paas -s test-azure
atmos kubemarine do -s test-azure -- -g control-plane --no_stream -- sudo kubectl get nodes   # команда на нодах
atmos kubemarine backup -s test-azure
```

`atmos kubeconfig -s <stack>` — забрать admin kubeconfig с control-plane в `.kubemarine/<stack>/kubeconfig`
(на новой машине или в CI, где `install` не запускался).

## 6. Изменение кластера

Источник истины — стек. `cluster.yaml` каждый раз генерируется заново, руками его не правят.

### Добавить ноду
```sh
# 1. добавить в stacks/clusters/<cluster>.yaml:  worker-3: { type: worker }
atmos terraform apply infra -s <stack>                          # создаст VM
atmos kubemarine add_node -s <stack> --nodes worker-3           # введёт её в кластер
```

### Удалить ноду (порядок обратный!)
```sh
atmos kubemarine remove_node -s <stack> --nodes worker-3        # пока VM ещё есть в outputs
# 2. удалить worker-3 из стека
atmos terraform apply infra -s <stack>                          # удалит VM
```

### Увеличить/уменьшить мощность нод (вертикальное масштабирование)

Поменять `size` (или `disk_size`) у типа — изменятся все ноды этого типа:
```yaml
node_types:
  worker: { size: xlarge }        # в clusters/<cluster>.yaml — для кластера во всех облаках
```
или поменять перевод класса только для одного размещения (`providers/<cloud>/<cluster>.yaml`):
```yaml
sizes:
  large: Standard_D16s_v5
```
```sh
atmos terraform plan infra -s <stack>      # покажет update in-place для VM этого типа
atmos terraform apply infra -s <stack>
```
Смена размера перезагружает VM, а terraform делает это для всех нод типа параллельно. Чтобы не уронить
сервис (особенно control-plane), меняйте по одной ноде:
```sh
atmos terraform apply infra -s <stack> -target='azurerm_linux_virtual_machine.node["worker-1"]'   # потом worker-2, ...
atmos terraform apply infra -s <stack>                                                            # финальная сверка
```
(ресурс VM: `aws_instance.node`, `google_compute_instance.node`, `azurerm_linux_virtual_machine.node`, `openstack_compute_instance_v2.node`).
Для одной «особой» ноды достаточно поля в самой ноде: `worker-7: { type: worker, size: ... }`.
Диск можно только увеличить.

### Горизонтальное масштабирование
Добавление/удаление нод нужного типа — см. выше («Добавить ноду», «Удалить ноду»). Kubemarine не умеет менять роли
существующей ноды: смена `roles` у типа или `type` у ноды = удалить ноду (`remove_node`) и добавить заново.

`labels`/`taints` kubemarine ставит, когда нода входит в кластер (`install`, `add_node`). Для уже работающих нод
после правки стека примените их через `kubectl label` / `kubectl taint`.

### Сеть и прочие облачные ресурсы
Меняются переменными `infra`: облачные (`region`, ...) — в размещении `providers/<cloud>/<cluster>.yaml` или в `_defaults` провайдера,
общие (`admin_cidr`, `admin_ports`, `cidr`) — в `clusters/<cluster>.yaml`:
`cidr`, `admin_cidr`, `admin_ports`, `region`, ... Затем:
```sh
atmos terraform plan infra -s <stack>     # смотрим, что изменится
atmos terraform apply infra -s <stack>
```
Осторожно: смена `cidr`/`region` пересоздаёт сеть и VM — это новый кластер. Новые типы ресурсов
(NAT, балансировщики облака, диски) добавляются в `components/terraform/<cloud>/` и, при необходимости, новыми переменными.

### Настройки Kubernetes
Изменить `components.terraform.kubemarine.vars.cluster` в `clusters/<cluster>.yaml` (или в `catalog/kubemarine.yaml` для всех)
и выполнить подходящую процедуру. Пример, проверенный на `test`: включили `plugins.calico.crossSubnet: false`
в каталоге и применили `atmos kubemarine install -s test-azure -- --tasks deploy.plugins`.
- версия k8s: `vars.procedures.upgrade.upgrade_plan: [v1.xx.y]` → `atmos kubemarine upgrade -s <stack>`;
- плагины/параметры сервисов: `atmos kubemarine install -s <stack> -- --tasks <задачи>` или `reconfigure`
  (см. [Maintenance.md](https://github.com/Netcracker/KubeMarine/blob/main/docs/public/Maintenance.md)).

### Удалить кластер
```sh
atmos workflow destroy -f cluster -s <stack>
```

## 7. Приложения в кластере (atmos helmfile): qubership-kafka

Приложение — helmfile-компонент atmos ([components/helmfile/kafka](components/helmfile/kafka/helmfile.yaml.gotmpl)),
настройки — в каталоге [stacks/catalog/kafka](stacks/catalog/kafka/). Ни компонент, ни каталог не знают ни про кластер, ни про облако.

**Установить Kafka в кластер — одна строка** в `clusters/<cluster>.yaml`:
```yaml
import:
  - catalog/node-types
  - catalog/kubemarine
  - catalog/kafka/small        # профиль: small | medium | large | xlarge
```
и во всех размещениях этого кластера (`<cluster>-azure`, `<cluster>-aws`, ...) появляется компонент `kafka`:
```sh
export KAFKA_ADMIN_PASSWORD=... KAFKA_CLIENT_PASSWORD=...
atmos helmfile diff  kafka -s test-azure
atmos helmfile apply kafka -s test-azure
atmos helmfile destroy kafka -s test-azure
```
`test` использует `small`, `full-cluster` — `medium`.

Как это устроено:
- **kubeconfig**: `catalog/kubemarine.yaml` задаёт `env.KUBECONFIG = .kubemarine/<stack>/kubeconfig` (его пишет
  `atmos kubemarine install`) — любой helmfile-компонент попадает в кластер своего стека без настроек.
  В стеках включены Go-шаблоны atmos с разделителями `<% %>` (`{{ }}` остаются kubemarine/helm).
- **хранилище**: Kafka пишет на локальные диски нод — `catalog/kubemarine.yaml` включает плагин kubemarine
  `local-path-provisioner` (StorageClass `local-path`, по умолчанию) во всех кластерах. На уже установленном кластере:
  `atmos kubemarine install -s <stack> -- --tasks deploy.plugins`.
- **профили** `catalog/kafka/<profile>.yaml` — ресурсы, heap, диск и тюнинг брокеров из раздела HWE
  [installation guide](https://github.com/Netcracker/qubership-kafka/blob/main/docs/public/installation.md);
  все импортируют `catalog/kafka/defaults.yaml` (версия чарта, namespace, KRaft, StorageClass).
- **values чарта** — переменная `values`, atmos сливает её по слоям: defaults → профиль → кластер → размещение.
  Любой параметр чарта переопределяется там, где нужно:
  ```yaml
  # clusters/full-cluster.yaml — для кластера во всех облаках
  components:
    helmfile:
      kafka:
        vars:
          values:
            kafka:
              replicas: 5
              tolerations: [{ key: workload, value: infra, effect: NoSchedule }]
  ```
- **пароли** не хранятся в репозитории. `credentials.*_password` — ссылки
  [vals](https://github.com/helmfile/vals), которые helmfile разрешает при деплое. По умолчанию — переменные окружения
  (`ref+envsubst://$KAFKA_ADMIN_PASSWORD`). Секрет-менеджер облака подключается в `providers/<cloud>/_defaults.yaml`
  (или в размещении), чарт и каталог не меняются:
  ```yaml
  components:
    helmfile:
      kafka:
        vars:
          credentials:
            admin_password: ref+azurekeyvault://my-vault/kafka-admin-password   # aws: ref+awssecrets://..., gcp: ref+gcpsecrets://...
  ```
- **версия**: `chart_version` в `catalog/kafka/defaults.yaml`; чарты берутся из GitHub-релизов qubership-kafka.

Новое приложение делается так же: `components/helmfile/<app>/helmfile.yaml.gotmpl` (+ `values.yaml.gotmpl`,
которому atmos передаёт `vars` как `.Values`) и `stacks/catalog/<app>/` с defaults и профилями.

## 8. GitHub Actions

Workflow [cluster](.github/workflows/cluster.yaml) запускается вручную и выполняет те же команды для выбранного стека:
`plan`, `deploy`, `infra`, `kubemarine`, `apps`, `destroy`, в том числе в режиме dry run. Креды облаков — из секретов GitHub (OIDC или ключи).
Какие секреты завести и как их получить для каждого провайдера — [.github/workflows/README.md](.github/workflows/README.md).

Раннеру на время запуска открывается доступ к нодам: облачные модули добавляют его IP (`ci_cidr`, `TF_VAR_ci_cidr`)
к `admin_cidr` в правиле firewall, в конце запуска IP убирается.

## 9. Как создавался кластер `test` (Azure, стек `test-azure`)

```sh
az login --tenant 7cb71954-...                         # MFA-тенант
# хранилище state: команды из раздела 3 (tfstate / tfstate3a9387c7 / tfstate)
atmos terraform plan  infra -s test-azure              # 11 ресурсов
atmos terraform apply infra -s test-azure
atmos kubemarine check_iaas -s test-azure
atmos kubemarine install -s test-azure                 # ~5 минут
export KUBECONFIG=$PWD/.kubemarine/test-azure/kubeconfig && kubectl get nodes
```

Что пришлось поправить по ходу (всё — в стеках, код модулей не трогали):
- пробная подписка: квота 4 vCPU на регион → в `providers/azure/test.yaml` классы `medium`/`large` = `Standard_D2as_v5`;
- `westeurope` — размеры VM запрещены для подписки, `northeurope` — нет свободных мощностей → `region: swedencentral` (там же);
- RBAC на storage account применяется несколько минут — первые запуски terraform получали 403;
- провайдер выпускает трафик через пул IP `72.56.49.167–172` → `admin_cidr: 72.56.49.160/28`;
- Calico по умолчанию не инкапсулирует трафик внутри одной подсети, облако его режет → `crossSubnet: false`;
- кластер создавался до разделения на «кластер × облако» (стек назывался `test`); state перенесён в workspace
  нового стека: `terraform state pull` из `test-infra` → `state push` в `test-azure-infra`, после чего `plan` — «No changes».

`check_iaas` на `test` оставляет FAIL по vCPU worker-а (2 < 4, ограничение квоты) и PodSubnet/ServiceSubnet
(проверка шлёт неинкапсулированные пакеты, облако их режет; с VXLAN это не мешает). Установка проходит.

## 10. Упрощения

- Ноды получают публичные IP: kubemarine ходит на них по SSH напрямую, входящий трафик открыт только с `admin_cidr` на `admin_ports` (22, 6443).
  Если ноды должны быть приватными — верните bastion и используйте `gateway_nodes` kubemarine.
- OpenStack: state без блокировки (`use_lockfile: false`), включите, если хранилище поддерживает conditional writes.
- Calico: VXLAN всегда (`crossSubnet: false`). IPIP не работает в Azure.
- Версия kubemarine — та, что в `PATH`; для `upgrade`/`migrate_kubemarine` сначала обновите бинарник.
- Kafka в `full-cluster`: там PSS `restricted` для всех namespace, кроме `kube-system`; если поды Kafka не пройдут
  проверку, добавьте `kafka` в `rbac.pss.exemptions.namespaces` кластера.
- Проверено end-to-end только Azure; модули AWS/GCP/OpenStack проходят `terraform validate`, но в облаке не запускались.
