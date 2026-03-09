# 配置热重载

NullClaw 监控 `config.json` 文件的变更，并**无需重启进程**即可动态应用更新。这包括全局模型参数和各频道的配置。

## 工作原理

1. Daemon 在每次监控循环迭代时轮询配置文件的修改时间（mtime）。
2. 检测到变更后，加载新配置并与当前配置进行差异对比。
3. 根据实际变更内容粒度化应用更改——未受影响的会话保持不变，保留完整对话历史。

## 热重载覆盖范围

| 变更 | 效果 |
|------|------|
| 全局模型参数（`provider`、`model`、`max_context_tokens`、`temperature`） | **所有**频道会话（Telegram、Discord、Slack、Signal、Matrix、IRC、Web、WhatsApp、Mattermost、iMessage 等）原地热更新。对于 MQTT / Redis Stream，仅无自身 `model_override` 的 endpoint 会被更新。对话历史保留。 |
| 全局子 agent / 工具审查器模型（`sub_agent_provider`、`sub_agent_model`、`tools_reviewer_provider`、`tools_reviewer_model`） | 同全局模型参数——所有频道会话热更新。有自身覆盖的 MQTT / Redis Stream endpoint 保持其 per-endpoint 配置。 |
| Per-endpoint `model_override`（含 `sub_agent_*` / `tools_reviewer_*`） | 仅该 endpoint 的会话热更新，对话历史保留。 |
| 结构性 endpoint 变更（host、port、keys、topic） | 该 endpoint 的会话被驱逐（重置），频道以新配置重启。 |
| 移除 endpoint | 该 endpoint 的会话被驱逐，资源释放。 |
| 新增 endpoint | 启动新的频道监听器，不影响现有会话。 |
| 移除账号 | 该账号的所有会话和监听器停止并清理。 |
| 新增账号 | 启动新的频道监听器。 |

## 变更分类

热重载系统使用 `endpoint_id` 将运行中的会话与配置条目关联。对于每个 endpoint，变更分为三类：

### 1. 无变更

若结构性字段和模型覆盖字段均未变更，会话完全不受影响。对话历史、上下文和所有状态均保留。

### 2. 仅模型变更（热更新）

若仅 `model_override` 字段发生变更（或无覆盖的 endpoint 的全局模型配置变更），会话的模型参数**原地**更新。对话历史和上下文完整保留——仅后续的 LLM provider/model/temperature/token-limit 设置发生变化。

示例：
- 将 `temperature` 从 `0.7` 改为 `0.9`
- 将模型从 `gpt-4o` 切换为 `claude-sonnet-4-20250514`
- 调整 `max_context_tokens`

### 3. 结构性变更（会话重置）

若以下任意字段发生变更，该会话被视为结构性不同，将被**驱逐**（对话历史丢失，重新开始新会话）：

**MQTT：**
- `host`、`port`、`username`、`password`、`tls`、`client_id`
- `peer_pubkey`、`local_privkey`、`local_pubkey`
- `listen_topic`、`reply_topic`

**Redis Stream：**
- `host`、`port`、`username`、`password`、`tls`、`db`
- `peer_pubkey`、`local_privkey`、`local_pubkey`
- `listen_topic`、`reply_topic`
- `consumer_group`、`consumer_name`

发生结构性变更时，该账号对应的整个频道将停止并以新配置重启。

## endpoint_id 的作用

每个 endpoint 有唯一的 `endpoint_id`（上线时自动生成的 16 字符随机十六进制字符串）。该 ID 是热重载系统的关键：

- **匹配**：系统通过比较 `endpoint_id` 值，在新旧配置中找到"相同"的 endpoint。
- **会话关联**：会话以 `{channel_type}:{endpoint_id}` 为键，因此即使 topic 或 host 发生变化，系统也能找到正确的会话进行驱逐或更新。
- **稳定性**：只要 `endpoint_id` 保持不变，系统就知道这是同一个逻辑 endpoint。

### 若 endpoint_id 缺失？

若配置经过手动编辑且没有 `endpoint_id`，会话键回退为 `{channel_type}:{account_id}:{topic}`。热重载仍然有效，但重命名 topic 将创建新会话而非迁移现有会话。

## 全局与 Per-Endpoint 模型配置

NullClaw 支持两级模型配置：

### 全局配置

在 `config.json` 顶层设置：

```jsonc
{
  "provider": "openrouter",
  "model": "openrouter/minimax/minimax-m2.5",
  "max_context_tokens": 16384,
  "temperature": 0.7
}
```

所有会话默认使用这些设置。

### Per-Endpoint 覆盖

在 endpoint 的 `model_override` 中设置：

```jsonc
{
  "endpoints": [
    {
      "endpoint_id": "abc123...",
      "listen_topic": "support",
      "model_override": {
        "provider": "anthropic",
        "model": "claude-sonnet-4-20250514",
        "max_context_tokens": 8192,
        "temperature": 0.5
      }
    }
  ]
}
```

设置了 `model_override` 的 endpoint 使用这些设置，而非全局配置。

### 热重载交互

- **全局模型变更 + endpoint 有覆盖**：无效果——该 endpoint 保留自己的覆盖设置。
- **全局模型变更 + endpoint 无覆盖**：会话以新全局设置热更新。
- **Endpoint 覆盖变更**：仅该 endpoint 的会话热更新。

## 示例

### 示例 1：修改全局温度

**修改前：**
```json
{ "temperature": 0.7 }
```

**修改后（编辑并保存 config.json）：**
```json
{ "temperature": 0.9 }
```

**结果：** 所有无 per-endpoint 温度覆盖的会话热更新，对话历史保留。

### 示例 2：新增 MQTT Endpoint

**修改前：**
```jsonc
{
  "channels": {
    "mqtt": [{
      "account_id": "default",
      "endpoints": [
        { "endpoint_id": "aaa...", "listen_topic": "device/1", ... }
      ]
    }]
  }
}
```

**修改后：**
```jsonc
{
  "channels": {
    "mqtt": [{
      "account_id": "default",
      "endpoints": [
        { "endpoint_id": "aaa...", "listen_topic": "device/1", ... },
        { "endpoint_id": "bbb...", "listen_topic": "device/2", ... }
      ]
    }]
  }
}
```

**结果：** `device/1` 上的现有会话不受影响。为 `device/2` 启动新监听器。MQTT 频道重启以接入新 endpoint，但 `device/1` 会话的对话历史保留（其 endpoint 配置未变，不被驱逐）。

### 示例 3：移除 Endpoint

从 `endpoints` 数组中移除一个 endpoint。对应会话被驱逐，资源释放。其他 endpoint 不受影响。

### 示例 4：更换 Broker 主机

**修改前：**
```json
{ "endpoint_id": "aaa...", "host": "broker1.example.com", ... }
```

**修改后：**
```json
{ "endpoint_id": "aaa...", "host": "broker2.example.com", ... }
```

**结果：** 这是结构性变更。`aaa...` 上的会话被驱逐（对话历史丢失），频道重启并连接新 broker。

### 示例 5：轮换 P256 密钥

更改 `peer_pubkey`、`local_privkey` 或 `local_pubkey` 是结构性变更。会话被驱逐，以新密钥创建新会话。

## 监控

热重载事件以 `info` 级别记录。查找以下日志消息：

```
Config file changed, reloading...
MQTT endpoint 'aaa...' model config changed, hot-updating
MQTT endpoint 'bbb...' structural change, resetting session
MQTT endpoint 'ccc...' removed, evicting session
MQTT account 'staging' added, starting channel
Global model changed, hot-updating MQTT endpoint 'ddd...'
Config reload complete
```

## 子 Agent 与工具审查器模型配置

NullClaw 支持为**子 agent**（后台任务执行）和**工具审查器**（定期审查子 agent 工具调用循环是否在取得进展的轻量级 LLM 调用）分别配置专用 LLM 模型覆盖。这些覆盖存在于两个层级，遵循多层回退链。

### 全局子 Agent / 工具审查器模型

在 `config.json` 顶层设置：

```jsonc
{
  "sub_agent_provider": "anthropic",
  "sub_agent_model": "claude-sonnet-4-20250514",
  "tools_reviewer_provider": "openrouter",
  "tools_reviewer_model": "google/gemini-2.5-flash"
}
```

设置后，子 agent LLM 调用使用 `sub_agent_provider` / `sub_agent_model` 而非全局 `provider` / `model`。类似地，工具审查器 LLM 调用使用 `tools_reviewer_provider` / `tools_reviewer_model`。若未设置，两者均回退到全局默认 provider/model。

### Per-Endpoint 子 Agent / 工具审查器模型

在 endpoint 的 `model_override` 中设置：

```jsonc
{
  "endpoints": [
    {
      "endpoint_id": "abc123...",
      "listen_topic": "support",
      "model_override": {
        "provider": "anthropic",
        "model": "claude-sonnet-4-20250514",
        "sub_agent_provider": "openrouter",
        "sub_agent_model": "google/gemini-2.5-flash",
        "tools_reviewer_provider": "openrouter",
        "tools_reviewer_model": "google/gemini-2.5-flash"
      }
    }
  ]
}
```

### 回退链

子 agent 模型的解析顺序（工具审查器遵循相同模式）：

1. **频道 `model_override.sub_agent_model`** — 若 endpoint 明确设置，则使用。
2. **频道 `model_override.model`**（通用）— 若 endpoint 有自己的通用模型但无子 agent 专用模型，则使用频道的通用模型。
3. **全局 `sub_agent_model`** — 若频道无任何模型覆盖，则使用全局子 agent 模型。
4. **全局 `model`**（默认）— 最终回退到全局默认模型。

相同的链适用于 `sub_agent_provider`、`tools_reviewer_model` 和 `tools_reviewer_provider`。

### 热重载行为

所有四个字段（`sub_agent_provider`、`sub_agent_model`、`tools_reviewer_provider`、`tools_reviewer_model`）在全局和 per-endpoint 级别均支持热重载：

- **全局变更 + endpoint 有覆盖**：无效果——该 endpoint 保留自己的覆盖设置。
- **全局变更 + endpoint 无覆盖**：会话以新全局设置热更新。
- **Endpoint 覆盖变更**：仅该 endpoint 的会话热更新。

重载后新的子 agent / 工具审查器调用将使用更新后的模型。正在运行的子 agent 调用不会被中断。

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `sub_agent_provider` | string（可选） | *（全局默认 provider）* | 子 agent 调用使用的 LLM provider。 |
| `sub_agent_model` | string（可选） | *（全局默认 model）* | 子 agent 调用使用的 LLM 模型。 |
| `tools_reviewer_provider` | string（可选） | *（全局默认 provider）* | 工具审查器调用使用的 LLM provider。 |
| `tools_reviewer_model` | string（可选） | *（全局默认 model）* | 工具审查器调用使用的 LLM 模型。 |

## 子 Agent 配置

skill 子 agent（由 `[action:agent]` 和 `[action:asyncAgent]` skills 使用）有一个工具调用循环，具有可配置的限制和智能审查机制。这些设置在 `config.json` 的 `agent` 部分：

```jsonc
{
  "agent": {
    "sub_agent_max_iterations": 128,
    "sub_agent_review_after": 5
  }
}
```

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `sub_agent_max_iterations` | integer | `128` | 子 agent 循环的工具调用迭代次数硬限制。耗尽后返回 `agent_error`。设为 `0` 使用编译默认值（128）。 |
| `sub_agent_review_after` | integer | `5` | 经过此轮连续工具调用迭代后，触发轻量级 LLM 审查以判断循环是否卡住或在取得进展。设为 `0` 使用编译默认值（5）。 |

### 智能审查：工作原理

当子 agent 进入工具调用循环（例如反复调用 `shell`、`web_fetch` 等）时，系统会定期检查循环是否有效：

1. **触发**：每经过 `sub_agent_review_after` 次连续工具调用迭代，触发一次审查。
2. **审查调用**：独立的 LLM 调用接收迄今为止所有工具调用的摘要以及子 agent 的原始目标。
3. **判决**：审查 LLM 响应以下之一：
   - `[continue]` — 循环正在取得进展，继续执行。
   - `[stop:<原因>]` — 循环似乎卡住了；以给定原因作为错误信息终止。
4. **Fail-open**：若审查 LLM 调用失败或产生无法解析的响应，循环继续（无误报）。
5. **温度**：审查使用温度 0.1 以确保判断的确定性。
6. **调度**：审查在迭代 `review_after`、`2 * review_after`、`3 * review_after` 等时触发。阈值被钳制到 `max_iterations - 1`，确保至少执行一次迭代后才触发第一次审查。

### 运行时行为

- `sub_agent_review_after` 在运行时被钳制到 `sub_agent_max_iterations - 1`。
- 若 `sub_agent_max_iterations <= 1`，审查实际上被禁用（循环在审查前就会触达硬限制）。
- 两项设置均支持热重载：在 `config.json` 中修改后，立即对新的子 agent 调用生效。正在运行的子 agent 调用不会被中断。

### 示例：为长时运行子 Agent 调优

若某个 skill 合理地需要大量工具调用（例如多步骤研究 agent）：

```json
{
  "agent": {
    "sub_agent_max_iterations": 50,
    "sub_agent_review_after": 10
  }
}
```

允许最多 50 轮工具调用，在第 10、20、30、40 次迭代时进行进度审查。

### 示例：禁用审查

要完全禁用智能审查（仅依靠迭代次数硬限制）：

```json
{
  "agent": {
    "sub_agent_max_iterations": 20,
    "sub_agent_review_after": 20
  }
}
```

将 `review_after` 设置为等于 `max_iterations` 意味着审查会在最后一次迭代时触发，实际上等同于无审查。

## 上下文自动压缩

当配置了 `max_context_tokens`（全局或 per-endpoint）时，NullClaw 会自动监控每个会话的对话上下文 token 数量。达到限制时，自动触发上下文压缩——对较旧的消息进行摘要以释放空间，同时保留关键上下文。

该限制同样支持热重载：在配置中修改 `max_context_tokens` 后，立即对受影响的会话生效，无需丢失对话历史。
