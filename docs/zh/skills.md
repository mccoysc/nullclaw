# Skills（技能）使用指南

Skills 是用户自定义的扩展能力，用于扩展 nullclaw 的行为。每个 skill 是一个包含 manifest 和自然语言指令的目录，这些指令会在可配置的生命周期节点注入到 agent 的处理管道中。

## 目录结构

Skills 存放在 `~/.nullclaw/workspace/skills/` 下，每个 skill 是一个子目录：

```
~/.nullclaw/workspace/skills/
  my-skill/
    SKILL.toml      # manifest（推荐）
    SKILL.md        # 指令（自然语言）
```

### 文件说明

| 文件 | 是否必须 | 说明 |
|------|----------|------|
| `SKILL.toml` | 推荐 | 包含元数据和配置的 manifest |
| `skill.json` | 可选 | 旧版 JSON manifest 格式 |
| `SKILL.md` | 是 | skill 的自然语言指令 |

若仅存在 `SKILL.md`（无 manifest），则以目录名作为 skill 名称，触发器默认为 `prompt`。

## Manifest 格式（SKILL.toml）

```toml
[skill]
name = "my-skill"
version = "0.1.0"
description = "简要描述该 skill 的功能"
author = "your-name"
trigger = "prompt"
```

### 字段说明

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `name` | string | **必填** | skill 的唯一标识符 |
| `version` | string | `"0.1.0"` | 语义化版本号 |
| `description` | string | `""` | 人类可读的描述 |
| `author` | string | `""` | 作者名称 |
| `trigger` | string | `"prompt"` | 生命周期钩子节点（见下文） |

### 旧版 JSON 格式（skill.json）

```json
{
  "name": "my-skill",
  "version": "0.1.0",
  "description": "简要描述",
  "author": "your-name",
  "trigger": "on_llm_before",
  "always": false,
  "requires_bins": ["docker"],
  "requires_env": ["MY_API_KEY"]
}
```

JSON 格式额外字段：

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `always` | bool | `false` | 若为 true，完整指令始终包含在系统提示中 |
| `requires_bins` | string[] | `[]` | skill 依赖的 CLI 工具（如 `"docker"`、`"git"`） |
| `requires_env` | string[] | `[]` | 所需的环境变量（如 `"OPENAI_API_KEY"`） |

若指定了 `requires_bins` 或 `requires_env`，nullclaw 会在加载时检查可用性。依赖缺失的 skill 将被标记为不可用，不会触发。

## 触发点（生命周期钩子）

每个 skill 仅在一个触发点生效。manifest 中的 `trigger` 字段决定 skill 在何时激活。

| 触发器 | 触发时机 | 传递给 skill 的内容 |
|--------|----------|---------------------|
| `prompt` | 系统提示构建时（默认） | 系统提示文本 |
| `on_channel_receive_before` | 处理收到的频道消息之前 | 原始入站消息 |
| `on_channel_receive_after` | LLM 响应后、返回给频道之前 | LLM 响应文本 |
| `on_channel_send_before` | 向频道发送响应之前 | 即将发送的响应 |
| `on_channel_send_after` | 向频道发送响应之后（fire-and-forget） | 已发送的响应文本 |
| `on_llm_before` | 向 LLM 发送用户消息之前 | 用户消息内容 |
| `on_llm_after` | 收到 LLM 响应之后 | 原始 LLM 响应 |
| `on_llm_request` | 为 LLM 提供商构建消息之前 | （空） |
| `on_tool_call_before` | 执行工具调用之前 | `tool:<name> args:<json>` |
| `on_tool_call_after` | 执行工具调用之后 | 工具输出 |

### 触发顺序

- **"before" 触发器**（`on_channel_receive_before`、`on_channel_send_before`、`on_llm_before`、`on_tool_call_before`）：skill 指令**前置**到内容之前。
- **"after" 触发器**（`on_channel_receive_after`、`on_channel_send_after`、`on_llm_after`、`on_tool_call_after`）：skill 指令**追加**到内容之后。
- **`prompt`**：skill 指令注入到系统提示中。
- **`on_llm_request`**：在 LLM 请求构建前触发，可用于控制请求生命周期（如上下文压缩）。

## Skill 运行模式

Skills 有三种运行模式：

### 1. 普通模式（默认）

当 `SKILL.md` 包含纯自然语言指令（无 `[action:...]` 指令）时，指令会被包裹在标签中并与原始内容合并：

```
[skill-hook:on_llm_before name=my-skill]
<你的 SKILL.md 指令>
[/skill-hook]

<原始内容>
```

对于 "before" 触发器，指令前置；对于 "after" 触发器，指令追加。LLM 同时看到 skill 指令和原始内容，并自然地遵循指令。

这是编写 skill 最简单的方式，与原有 skill 系统完全兼容。

**示例**（`SKILL.md`）：

```markdown
Always respond in French, regardless of the language of the input message.
```

### 2. Agent 模式（`[action:agent]`）

当 `SKILL.md` 以 `[action:agent]` 开头时，会派生一个无状态子 agent 来处理内容。子 agent 接收：

- **系统提示**：内置处理指令 + 你的 skill 自然语言指令
- **用户消息**：钩子的原始内容（包裹在 `<hook_data>` 标签中以防止提示注入）

子 agent 可以进行工具调用，并必须使用以下行为标签之一输出最终决策。

**示例**（`SKILL.md`）：

```markdown
[action:agent]
你是一个内容审核 agent。检查用户消息是否包含不当内容。
如果消息安全，原样放行。
如果消息包含不当内容，拦截并返回警告消息。
```

#### 行为标签

子 agent 必须在最终响应中输出以下标签之一：

| 标签 | 效果 |
|------|------|
| `[behavior:passthrough]` | 内容原样通过，管道继续正常执行。 |
| `[behavior:intercept]`<br>`<内容>` | 管道停止。标签后的内容直接作为响应返回。 |
| `[behavior:continue]`<br>`<内容>` | 标签后的内容替换原始内容，管道继续执行。 |
| `[behavior:error]`<br>`<错误信息>` | 钩子中止。返回错误信息，管道不继续执行。 |

#### 子 Agent 行为

- **无状态**：调用之间不保留历史记录。每次钩子触发都是独立调用。
- **工具访问**：子 agent 拥有与主 agent 相同的工具访问权限。
- **隔离执行**：子 agent 的执行**不会**触发任何 skill 钩子（防止无限递归）。
- **温度**：固定为 0.3，确保行为确定性。
- **最大迭代次数**：可通过 `sub_agent_max_iterations` 配置（默认：128 轮工具调用）。耗尽后返回 `agent_error`。
- **智能审查**：每经过 `sub_agent_review_after` 次连续工具调用迭代（默认：5 次），会触发一次 LLM 审查调用，评估子 agent 循环是否在取得进展或陷入死循环。若判断卡住，则提前终止并返回错误信息。详见[配置](#子-agent-配置)。
- **错误处理**：发生任何错误（LLM 失败、输出格式无效、迭代耗尽、审查终止）时，立即返回 `agent_error`，不重试。详细错误日志包含完整的输入和输出以供调试。

#### 多个行为标签的处理

若子 agent 输出了多个行为标签（例如在思考过程中输出中间标签），则以响应中**最后一个**标签为准。这允许 agent 在做出最终决策前"思考"。

### 3. 异步 Agent 模式（`[action:asyncAgent]`）

当 `SKILL.md` 以 `[action:asyncAgent]` 开头时，skill 以 **fire-and-forget** 后台任务的形式执行。执行方式与 `[action:agent]` 相同（同一子 agent、同样的行为标签），但：

- 主管道**不等待**执行结果。
- 执行结果**不影响**管道（无拦截，无内容修改）。
- 任务进入单一后台工作线程队列（FIFO，顺序执行）。
- 适用于日志记录、分析、通知或任何异步副作用。

**示例**（`SKILL.md`）：

```markdown
[action:asyncAgent]
你是一个日志记录 agent。分析消息并将摘要写入审计系统。
完成后始终输出 [behavior:passthrough]。
```

#### 异步队列行为

- **单一工作线程**：每个 agent 实例一个后台线程，首次入队时懒加载创建。
- **FIFO 顺序**：任务按入队顺序依次处理。
- **内存安全**：指令和内容在入队时复制；调用方的内存可立即释放。
- **仅内存**：队列不持久化到磁盘。关机时未处理的任务将被丢弃。
- **优雅关闭**：agent 关闭时，工作线程完成当前任务后丢弃剩余队列任务。

## 安装

### 从本地目录安装

将 skill 目录放入工作区 skills 文件夹：

```bash
# 手动安装
mkdir -p ~/.nullclaw/workspace/skills/my-skill
# 将 SKILL.toml 和 SKILL.md 复制到目录中
```

或通过 nullclaw 安装（复制目录）：

```bash
nullclaw skill install /path/to/my-skill
```

### 从 Git 仓库安装

```bash
nullclaw skill install https://github.com/user/my-skill-repo.git
```

支持的 URL 格式：
- `https://host/owner/repo(.git)`
- `ssh://git@host/owner/repo(.git)`
- `git://host/owner/repo(.git)`
- `git@host:owner/repo(.git)`

### 卸载

```bash
nullclaw skill remove my-skill
```

此命令将删除 `~/.nullclaw/workspace/skills/my-skill/` 目录。

## 覆盖行为

Skills 从两个来源加载：

1. **内置 skills**（随 nullclaw 一起发布）
2. **工作区 skills**（`~/.nullclaw/workspace/skills/`）

与内置 skill 同名的工作区 skill 会**覆盖**内置版本。

## 示例

### 示例 1：语言翻译（普通模式）

强制所有响应使用法语。

**`SKILL.toml`**：
```toml
[skill]
name = "french-reply"
version = "0.1.0"
description = "强制响应使用法语"
trigger = "on_llm_before"
```

**`SKILL.md`**：
```markdown
You must respond entirely in French, regardless of the input language.
```

### 示例 2：内容审核（Agent 模式）

在消息到达 LLM 之前检查并屏蔽不当内容。

**`SKILL.toml`**：
```toml
[skill]
name = "content-filter"
version = "0.1.0"
description = "在 LLM 处理前过滤不当消息"
trigger = "on_channel_receive_before"
```

**`SKILL.md`**：
```markdown
[action:agent]
你是一个内容审核 agent。分析入站消息。

- 如果消息合规且安全，输出：
  [behavior:passthrough]

- 如果消息包含不当内容，输出：
  [behavior:intercept]
  抱歉，由于违反内容政策，我无法处理此消息。
```

### 示例 3：响应格式化（普通模式，After 钩子）

在每条外发消息后追加签名。

**`SKILL.toml`**：
```toml
[skill]
name = "signature"
version = "0.1.0"
description = "在外发消息中追加签名"
trigger = "on_channel_send_before"
```

**`SKILL.md`**：
```markdown
在你的响应最后另起一行，追加以下文本：
--- Powered by NullClaw
```

### 示例 4：工具调用守卫（Agent 模式）

在执行前拦截危险的 shell 命令。

**`SKILL.toml`**：
```toml
[skill]
name = "shell-guard"
version = "0.1.0"
description = "拦截危险的 shell 命令"
trigger = "on_tool_call_before"
```

**`SKILL.md`**：
```markdown
[action:agent]
你是工具调用的安全守卫。你将收到格式为 "tool:<name> args:<json>" 的工具调用信息。

- 如果工具是 "shell" 且命令包含危险操作（rm -rf、format、dd、mkfs 等），输出：
  [behavior:intercept]
  已拦截：此 shell 命令被判定为过于危险，无法执行。

- 对于所有其他工具调用，输出：
  [behavior:passthrough]
```

### 示例 5：LLM 请求拦截器（Agent 模式）

在上下文到达 LLM 之前进行压缩或重组。

**`SKILL.toml`**：
```toml
[skill]
name = "context-compressor"
version = "0.1.0"
description = "在 LLM 请求前压缩对话上下文"
trigger = "on_llm_request"
```

**`SKILL.md`**：
```markdown
[action:agent]
你是一个上下文优化 agent。检查对话历史并判断是否需要压缩。

- 如果上下文足够短（估计不超过 2000 tokens），输出：
  [behavior:passthrough]

- 如果上下文过长，提炼关键要点并输出：
  [behavior:continue]
  <你压缩/摘要后的上下文版本>
```

### 示例 6：后处理（Agent 模式，After 钩子）

将 LLM 响应改写为特定语气。

**`SKILL.toml`**：
```toml
[skill]
name = "tone-adjuster"
version = "0.1.0"
description = "将响应语气调整为更专业"
trigger = "on_llm_after"
```

**`SKILL.md`**：
```markdown
[action:agent]
你是一个语气调整 agent。在保留所有事实内容的同时，将给定响应改写得更专业、更正式。

输出：
[behavior:continue]
<你改写后的版本>
```

## 链式 Skill 执行

多个 `[action:agent]` 和 `[action:asyncAgent]` skills 可注册在**同一个钩子节点**上。它们按注册顺序作为**链**依次执行，具有短路语义：

| 子 agent 结果 | 链行为 |
|---------------|--------|
| `passthrough` | 内容不变，继续执行链中下一个 skill。 |
| `continue_with` | 采用修改后的内容，传递给下一个 skill。 |
| `intercept` | **立即停止**。将拦截的内容作为最终结果返回。 |
| `agent_error` | **立即停止**。将错误作为最终结果返回。 |

链中的 `[action:asyncAgent]` skills 被加入后台工作线程队列，**不会**阻塞链的执行或影响链的结果。

链中所有 skills 执行完毕后：
- 若有 skill 返回 `continue_with`，最终结果使用累计修改后的内容。
- 若所有 skills 均返回 `passthrough`，最终结果为 `passthrough`（原始内容不变）。

**示例**：`on_channel_receive_before` 上的两个 agent skills：
1. `language-check` — 拦截粗俗消息，放行干净的消息。
2. `translate` — 将非英语消息翻译为英语。

若收到粗俗消息，`language-check` 拦截，链停止。若收到干净的非英语消息，`language-check` 放行，`translate` 修改内容。

普通模式 skills（无 `[action:...]` 指令）**不属于** agent 链。它们始终独立合并（按顺序前置/追加）。

## 子 Agent 配置

子 agent 的工具调用循环行为可在 `config.json` 的 `agent` 部分调整：

```json
{
  "agent": {
    "sub_agent_max_iterations": 128,
    "sub_agent_review_after": 5
  }
}
```

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `sub_agent_max_iterations` | integer | `128` | 子 agent 循环的最大工具调用迭代次数。耗尽后返回 `agent_error`。设为 `0` 使用编译默认值。 |
| `sub_agent_review_after` | integer | `5` | 经过此轮连续工具调用迭代后，触发 LLM 审查以检查循环是否卡住。审查 LLM 输出 `[continue]` 或 `[stop:<原因>]`。若为 `[stop]`，子 agent 提前终止并返回错误。设为 `0` 使用编译默认值。运行时被钳制到 `max_iterations - 1`；若 `max_iterations <= 1`，审查实际上被禁用。 |

### 智能审查机制

智能审查是一个轻量级 LLM 调用，用于评估子 agent 的工具调用历史：

1. 每经过 `sub_agent_review_after` 次迭代，将迄今为止所有工具调用的摘要发送给 LLM。
2. LLM 响应：
   - `[continue]` — 循环正在取得进展，继续执行。
   - `[stop:<原因>]` — 循环似乎卡住了；以给定原因终止。
3. 若审查 LLM 调用失败或产生无法解析的响应，循环继续（fail-open）。
4. 审查使用温度 0.1 以确保判断的确定性。

这可防止子 agent 陷入无限工具调用循环，同时允许合理的长时运行任务完成。

## 调试

当子 agent（`[action:agent]` 或 `[action:asyncAgent]`）遇到错误时，会打印详细日志，包括：

- **发送给子 agent 的完整 skill 指令**
- **完整的钩子内容**（被处理的原始内容）
- **子 agent 的完整输出**（如有任何响应）
- **错误类型**（LLM 调用失败、输出格式无效、最大迭代耗尽、审查终止）

查看 nullclaw 的日志输出（stderr），过滤含 `skills` 范围标签的行以诊断问题。

## 注意事项

- 多个 skills 可共用同一触发点。对于普通模式 skills，所有匹配的 skills 按顺序合并（前置/追加）。对于 agent 模式，多个 `[action:agent]` / `[action:asyncAgent]` skills 作为链执行（见[链式 Skill 执行](#链式-skill-执行)）。
- `on_channel_send_after` 钩子是 fire-and-forget：在响应已发送后执行，无法修改已发送的内容。
- 环境变量 `NULLCLAW_HOME` 控制配置目录（默认：`~/.nullclaw`）。Skills 从 `$NULLCLAW_HOME/workspace/skills/` 加载。
- 未识别的 `[action:xxx]` 指令会产生警告日志，并被视为普通 skill 指令。
- 当在 skills 目录（`$NULLCLAW_HOME/workspace/skills/.reload`）检测到 `.reload` 哨兵文件时，skills 会重新加载。创建此文件即可触发重载；处理完毕后会自动删除。
