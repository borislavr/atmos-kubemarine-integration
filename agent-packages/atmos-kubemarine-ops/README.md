# atmos-kubemarine-ops

APM-пакет ([Agent Package Manager](https://github.com/microsoft/apm)) со скиллом для AI-агентов (Claude Code, Copilot,
Cursor, Codex, ...), которые работают с репозиторием вида «atmos + kubemarine + helmfile»: этим и похожими.

Скилл помогает:
- **масштабировать кластер** — добавить / удалить / увеличить ноды в правильном порядке (`terraform apply` ↔ `add_node` / `remove_node`);
- **добавлять приложения** — helmfile-компонент + каталог + импорт в кластер + секреты в CI;
- **менять конфигурацию** — найти, из какого слоя приходит значение, и править тот слой, который соответствует нужному охвату;
- **обновлять версии** — чарты, Kubernetes (процедура `upgrade` kubemarine), инструменты в CI.

Главные правила скилла: стек — источник истины; каждое изменение проверяется `atmos validate` / `describe` / рендером;
всё, что меняет облако или кластер, выполняется только после подтверждения пользователя; секреты не попадают ни в репозиторий,
ни в вывод.

## Состав

| Путь | Что |
|---|---|
| [`apm.yml`](apm.yml) | манифест; MCP-сервер atmos как зависимость |
| [`SKILL.md`](.apm/skills/atmos-kubemarine-ops/SKILL.md) | модель репозитория, правила, инструменты, проверка, маршрутизация задач |
| [`references/`](.apm/skills/atmos-kubemarine-ops/references/) | `scale-cluster`, `add-app`, `configure`, `upgrade-versions`, `workflow` — подгружаются по задаче |

## Установка

[Установите APM](https://microsoft.github.io/apm/getting-started/installation/) (`pip install apm-cli` или установщик), затем в
корне своего репозитория:

```sh
apm install borislavr/atmos-kubemarine-integration/agent-packages/atmos-kubemarine-ops   # из GitHub
apm install ./agent-packages/atmos-kubemarine-ops                                          # в этом репозитории
```

APM положит скилл туда, где его ищет ваш агент (`.claude/skills/`, `.agents/skills/`, ...), и пропишет MCP-сервер atmos
в конфиг агента (`.mcp.json`, `.vscode/mcp.json`, ...).

## MCP-сервер atmos

Пакет подключает встроенный MCP-сервер atmos (`atmos mcp start`, экспериментальный, нужен atmos ≥ 1.200; ключ AI-провайдера
не нужен). Самое полезное для скилла:

- `atmos_stack_config_get` — значение **и файл:строка, откуда оно пришло** (provenance): ответ на вопрос «где это править»;
- `atmos_stack_config_set` — правка значения в файле-источнике (или в явно указанном `file`);
- `atmos_list_stacks`, `atmos_describe_component`, `atmos_list_values`, `atmos_describe_dependents`, `describe_affected`,
  `atmos_validate_stacks`.

Сервер нужно включить в `atmos.yaml` репозитория и ограничить набор инструментов (иначе агенту доступны и
`execute_bash_command`, `write_*`, правка `atmos.yaml`):

```yaml
mcp:
  enabled: true
ai:
  enabled: true          # нужен для `atmos mcp start`; провайдер не требуется
  tools:
    allowed:             # только эти инструменты регистрируются
      - atmos_list_stacks
      - atmos_list_components
      - atmos_list_values
      - atmos_describe_component
      - atmos_describe_dependents
      - atmos_validate_stacks
      - atmos_stack_config_get
      - atmos_stack_config_list
      - atmos_stack_config_set
      - describe_affected
```

Без MCP скилл работает через CLI atmos — те же операции, только «откуда значение» ищется `grep` по цепочке импортов.
