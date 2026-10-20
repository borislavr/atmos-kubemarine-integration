# atmos-kubemarine-integration

[atmos](https://atmos.tools) создаёт сеть и VM в AWS / GCP / Azure / OpenStack (terraform),
затем custom command `atmos kubemarine` ставит и обслуживает Kubernetes через
[KubeMarine](https://github.com/Netcracker/KubeMarine), запущенный локально. Jump-хост не нужен.

```
atmos.yaml                        # настройки atmos + custom command `atmos kubemarine`
components/terraform/
  aws | gcp | azure | openstack   # сеть + firewall + VM; единый выход `nodes` (name, address, internal_address, roles)
stacks/
  catalog/kubemarine.yaml         # общий cluster.yaml для всех кластеров (nodes = !terraform.output infra nodes)
  providers/<cloud>.yaml          # слой провайдера: backend для state, env (какая подписка/профиль), регион, размеры
  clusters/<name>.yaml            # слой кластера: import providers/<cloud> + переопределения; имя стека = vars.stage
  workflows/cluster.yaml          # deploy / destroy
.kubemarine/<stack>/              # рабочая папка kubemarine: cluster.yaml, procedure.yaml, kubeconfig, dump/, отчёты (не в git)
```

Слои: `catalog/kubemarine` → `providers/<cloud>` → `clusters/<name>`. Atmos делает deep merge:
кластер переопределяет только то, что отличается.

## 1. Что установить

| Инструмент | Зачем | Установка |
|---|---|---|
| atmos ≥ 1.200 | оркестрация | https://atmos.tools/install |
| terraform ≥ 1.10 | ресурсы в облаке | https://developer.hashicorp.com/terraform/install |
| kubemarine | установка k8s | бинарник из [релизов](https://github.com/Netcracker/KubeMarine/releases) (`kubemarine-win64.exe` / `-linux-x86_64` / `-macos14-*`) переименовать в `kubemarine` и положить в `PATH` (или `pip install kubemarine`) |
| CLI облака | логин | `az`, `aws`, `gcloud`, `openstack` |
| SSH-ключ | доступ к VM | `ssh-keygen -t ed25519` → `~/.ssh/id_ed25519` |

На Windows запускайте команды из **Git Bash**: шагам `atmos kubemarine` нужен `mkdir`, а atmos и kubemarine должны быть в `PATH`.
Для `kubectl` с локальной машины нужен `kubectl`.

## 2. Креды облаков: где хранить и как atmos их получает

Правило: **в репозитории только указатели (ID подписки, имя профиля, имя облака), секреты — в штатных хранилищах CLI облака или в секретах CI.**
Atmos передаёт terraform (и `!terraform.output`) переменные из секции `env:` стека, а terraform-провайдеры
сами находят креды по стандартной цепочке (env → файлы CLI → токен `az login`).

| Облако | Секрет хранится | Указатель в стеке (`providers/<cloud>.yaml`, `env:`) | Локально | CI |
|---|---|---|---|---|
| Azure | кэш токенов `az login` (`~/.azure`) | `ARM_SUBSCRIPTION_ID` | `az login --tenant <id>` | `ARM_CLIENT_ID`, `ARM_TENANT_ID` + OIDC (`ARM_USE_OIDC=true`) или `ARM_CLIENT_SECRET` |
| AWS | `~/.aws/config` + SSO-кэш / `~/.aws/credentials` | `AWS_PROFILE` | `aws configure sso`, `aws sso login --profile X` | OIDC-роль (`aws-actions/configure-aws-credentials`) или `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` |
| GCP | ADC (`~/.config/gcloud/application_default_credentials.json`) | `vars.project` | `gcloud auth application-default login` | Workload Identity Federation или `GOOGLE_APPLICATION_CREDENTIALS` |
| OpenStack | `~/.config/openstack/clouds.yaml` + пароль/app credential в `secure.yaml` | `OS_CLOUD` | заполнить `clouds.yaml` | `OS_AUTH_URL`, `OS_APPLICATION_CREDENTIAL_ID/SECRET`, ... |
| OpenStack state (S3 API) | `~/.aws/credentials`, профиль `openstack-tfstate` (ключи из `openstack ec2 credentials create`) | `backend.s3.profile` | — | `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` |

SSH: публичный ключ (`ssh_public_key_file`, по умолчанию `~/.ssh/id_ed25519.pub`) кладётся на VM,
приватный (`cluster.node_defaults.keyfile`) использует kubemarine. В репозиторий ключи не попадают.

Если разные кластеры живут в разных подписках/аккаунтах — переопределите `env` в `clusters/<name>.yaml`.

## 3. Подготовка провайдера (один раз)

Для каждого облака: залогиниться, создать хранилище для state, вписать имена в `stacks/providers/<cloud>.yaml`.

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
В `providers/aws.yaml`: `env.AWS_PROFILE`, `backend.s3.bucket`, `region`.

### GCP

```sh
gcloud auth login && gcloud auth application-default login
gcloud services enable compute.googleapis.com --project <project>
gcloud storage buckets create gs://<bucket> --project <project> --location=europe-west3 --uniform-bucket-level-access
gcloud storage buckets update gs://<bucket> --versioning
```
В `providers/gcp.yaml`: `backend.gcs.bucket`, `vars.project`, `region`, `zone`.

### OpenStack

```sh
# ~/.config/openstack/clouds.yaml -> clouds.my-cloud (auth_url, project, ...), секрет в secure.yaml
export OS_CLOUD=my-cloud
openstack container create tfstate
openstack ec2 credentials create              # access/secret -> ~/.aws/credentials [openstack-tfstate]
openstack network list --external             # -> vars.external_network
openstack image list | grep -i 22.04          # -> vars.image
openstack flavor list                         # -> node_types.*.size
```
В `providers/openstack.yaml`: `env.OS_CLOUD`, `backend.s3.endpoints.s3` (S3 endpoint объектного хранилища), `external_network`, `image`, `node_types` (flavor-ы).

## 4. Создание кластера

1. Создайте `stacks/clusters/<name>.yaml` (имя файла и `stage` = имя кластера и стека):

```yaml
import:
  - providers/azure            # aws | gcp | azure | openstack

vars:
  stage: prod                  # имя стека, префикс имён ресурсов

components:
  terraform:
    infra:
      vars:
        admin_cidr: 203.0.113.10/32      # откуда разрешены SSH и Kubernetes API (порты admin_ports)
        node_types:                      # необязательно: правка типов провайдера только для этого кластера
          worker: { size: Standard_D16s_v5 }
        nodes:                           # имя -> тип (см. раздел «Типы нод»)
          balancer-1:      { type: balancer }
          control-plane-1: { type: control-plane }
          control-plane-2: { type: control-plane }
          control-plane-3: { type: control-plane }
          worker-1:        { type: worker }
          worker-2:        { type: worker }
        # cidr, region, admin_ports ... — переопределяют значения провайдера

    kubemarine:
      vars:
        cluster:                         # любые ключи cluster.yaml kubemarine, deep merge с catalog/kubemarine.yaml
          cluster_name: prod.k8s.local
          services:
            kubeadm:
              kubernetesVersion: v1.33.x
```

`admin_cidr` — все адреса, с которых вы выходите в интернет. Если провайдер выпускает через пул NAT
(`curl ifconfig.me` возвращает разные IP), укажите подсеть пула, иначе SSH будет периодически отваливаться.

2. Проверить, что получилось:
```sh
atmos describe component infra -s prod                                  # переменные terraform
atmos describe component kubemarine -s prod --process-functions=false   # cluster.yaml до подстановки нод
atmos terraform plan infra -s prod
```

3. Развернуть:
```sh
atmos workflow deploy -f cluster -s prod
# то же по шагам:
atmos terraform apply infra -s prod
atmos kubemarine check_iaas -s prod        # необязательно: проверка VM до установки
atmos kubemarine install -s prod
```

4. Подключиться: `install` кладёт kubeconfig (API — по публичному IP control-plane, порт 6443 открыт для `admin_cidr`):
```sh
export KUBECONFIG=$PWD/.kubemarine/prod/kubeconfig
kubectl get nodes
```

Один control-plane — можно без балансера. Больше одного — нужен `balancer` (или `vrrp_ips` в `cluster`).

Примеры: [clusters/test.yaml](stacks/clusters/test.yaml) — минимальный (развёрнут),
[clusters/full-cluster.yaml](stacks/clusters/full-cluster.yaml) — HA-кластер по мотивам
[full-cluster.yaml](https://github.com/Netcracker/KubeMarine/blob/main/examples/cluster.yaml/full-cluster.yaml) kubemarine:
2 балансера, 3 control-plane, 3 worker-а с labels/taints, kubeadm, NTP, AppArmor, RBAC/PSS, плагины.
В шапке файла перечислено, что из оригинала убрано и почему.

### Типы нод

Нода не описывает себя сама, она ссылается на **тип** — профиль с параметрами:

| Поле типа | Обязательно | Куда идёт |
|---|---|---|
| `roles` | да | роли kubemarine: `control-plane`, `worker`, `balancer` (можно несколько) |
| `size` | да | размер VM: instance type (AWS), machine type (GCP), VM size (Azure), flavor (OpenStack) |
| `disk_size` | нет, 50 | системный диск, ГБ (в OpenStack задаётся flavor-ом) |
| `labels` | нет | labels ноды в Kubernetes |
| `taints` | нет | taints ноды, формат `key=value:Effect` |

Откуда берутся типы — обычный deep merge atmos, поле за полем:

```
stacks/providers/<cloud>.yaml   node_types: balancer / control-plane / worker   ← базовые размеры облака
stacks/clusters/<name>.yaml     node_types: { worker: { size: ... } }           ← правка для кластера
                                nodes: { worker-7: { type: worker, size: ... } } ← правка одной ноды
```

Нода = поля её типа + её собственные поля (`size`, `disk_size`, `labels` (сливаются), `taints`).
Неизвестный `type` останавливает `plan` с ошибкой. Логика — в [components/terraform/modules/nodes](components/terraform/modules/nodes/main.tf),
общая для всех облаков; тест: `cd components/terraform/modules/nodes && terraform init && terraform test`.

**Новый тип** — просто ещё один ключ в `node_types` (в провайдере — для всех кластеров, в кластере — только для него):

```yaml
node_types:
  ingress:      { roles: [worker], size: Standard_D4s_v5, labels: { node-role.kubernetes.io/ingress: "" } }
  infra:        { roles: [worker], size: Standard_E8s_v5, disk_size: 200,
                  labels: { workload: infra }, taints: ["workload=infra:NoSchedule"] }
  cp-and-worker: { roles: [control-plane, worker], size: Standard_D8s_v5 }   # маленький кластер без отдельных worker-ов
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

Примеры:
```sh
atmos kubemarine check_iaas -s test
atmos kubemarine install -s test
atmos kubemarine install -s test -- --tasks deploy.plugins          # только часть задач
atmos kubemarine check_paas -s test
atmos kubemarine do -s test -- -g control-plane --no_stream -- sudo kubectl get nodes   # команда на нодах
atmos kubemarine backup -s test
```

## 6. Изменение кластера

Источник истины — стек. `cluster.yaml` каждый раз генерируется заново, руками его не правят.

### Добавить ноду
```sh
# 1. добавить в stacks/clusters/<name>.yaml:  worker-3: { type: worker }
atmos terraform apply infra -s <name>                          # создаст VM
atmos kubemarine add_node -s <name> --nodes worker-3           # введёт её в кластер
```

### Удалить ноду (порядок обратный!)
```sh
atmos kubemarine remove_node -s <name> --nodes worker-3        # пока VM ещё есть в outputs
# 2. удалить worker-3 из стека
atmos terraform apply infra -s <name>                          # удалит VM
```

### Увеличить/уменьшить мощность нод (вертикальное масштабирование)

Поменять `size` (или `disk_size`) у типа — изменятся все ноды этого типа:
```yaml
node_types:
  worker: { size: Standard_D16s_v5 }
```
```sh
atmos terraform plan infra -s <name>      # покажет update in-place для VM этого типа
atmos terraform apply infra -s <name>
```
Смена размера перезагружает VM, а terraform делает это для всех нод типа параллельно. Чтобы не уронить
сервис (особенно control-plane), меняйте по одной ноде:
```sh
atmos terraform apply infra -s <name> -target='azurerm_linux_virtual_machine.node["worker-1"]'   # потом worker-2, ...
atmos terraform apply infra -s <name>                                                            # финальная сверка
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
Меняются переменными `infra` в стеке кластера (или провайдера — для всех кластеров):
`cidr`, `admin_cidr`, `admin_ports`, `region`, ... Затем:
```sh
atmos terraform plan infra -s <name>     # смотрим, что изменится
atmos terraform apply infra -s <name>
```
Осторожно: смена `cidr`/`region` пересоздаёт сеть и VM — это новый кластер. Новые типы ресурсов
(NAT, балансировщики облака, диски) добавляются в `components/terraform/<cloud>/` и, при необходимости, новыми переменными.

### Настройки Kubernetes
Изменить `components.terraform.kubemarine.vars.cluster` в стеке кластера (или в `catalog/kubemarine.yaml` для всех)
и выполнить подходящую процедуру. Пример, проверенный на `test`: включили `plugins.calico.crossSubnet: false`
в каталоге и применили `atmos kubemarine install -s test -- --tasks deploy.plugins`.
- версия k8s: `vars.procedures.upgrade.upgrade_plan: [v1.xx.y]` → `atmos kubemarine upgrade -s <name>`;
- плагины/параметры сервисов: `atmos kubemarine install -s <name> -- --tasks <задачи>` или `reconfigure`
  (см. [Maintenance.md](https://github.com/Netcracker/KubeMarine/blob/main/docs/public/Maintenance.md)).

### Удалить кластер
```sh
atmos workflow destroy -f cluster -s <name>
```

## 7. Как создавался кластер `test` (Azure)

```sh
az login --tenant 7cb71954-...                         # MFA-тенант
# хранилище state: команды из раздела 3 (tfstate / tfstate3a9387c7 / tfstate)
atmos terraform plan  infra -s test                    # 11 ресурсов
atmos terraform apply infra -s test
atmos kubemarine check_iaas -s test
atmos kubemarine install -s test                       # ~5 минут
export KUBECONFIG=$PWD/.kubemarine/test/kubeconfig && kubectl get nodes
```

Что пришлось поправить по ходу (всё — в `stacks/clusters/test.yaml` / каталоге, код модулей не трогали):
- пробная подписка: квота 4 vCPU на регион → 2 ноды `Standard_D2as_v5`;
- `westeurope` — размеры VM запрещены для подписки, `northeurope` — нет свободных мощностей → `region: swedencentral`;
- RBAC на storage account применяется несколько минут — первые запуски terraform получали 403;
- провайдер выпускает трафик через пул IP `72.56.49.167–172` → `admin_cidr: 72.56.49.160/28`;
- Calico по умолчанию не инкапсулирует трафик внутри одной подсети, облако его режет → `crossSubnet: false`.

`check_iaas` на `test` оставляет FAIL по vCPU worker-а (2 < 4, ограничение квоты) и PodSubnet/ServiceSubnet
(проверка шлёт неинкапсулированные пакеты, облако их режет; с VXLAN это не мешает). Установка проходит.

## 8. Упрощения

- Ноды получают публичные IP: kubemarine ходит на них по SSH напрямую, входящий трафик открыт только с `admin_cidr` на `admin_ports` (22, 6443).
  Если ноды должны быть приватными — верните bastion и используйте `gateway_nodes` kubemarine.
- OpenStack: state без блокировки (`use_lockfile: false`), включите, если хранилище поддерживает conditional writes.
- Calico: VXLAN всегда (`crossSubnet: false`). IPIP не работает в Azure.
- Версия kubemarine — та, что в `PATH`; для `upgrade`/`migrate_kubemarine` сначала обновите бинарник.
- Проверено end-to-end только Azure; модули AWS/GCP/OpenStack проходят `terraform validate`, но в облаке не запускались.
