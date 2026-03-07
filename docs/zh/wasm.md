# WASM 构建分析

NullClaw 提供两种 WASM 产物，分别面向不同的运行场景。

---

## 一、WASI CLI 二进制（`wasm32-wasi` 目标）

### 构建方式

```bash
zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseSmall
```

编译时自动切换入口文件为 `src/main_wasi.zig`，禁用所有 C 链接依赖（SQLite、PostgreSQL）。

### 运行示例

以 [wasmtime](https://wasmtime.dev/) 为例：

```bash
# 挂载当前目录作为 preopened 目录，传递命令行参数
wasmtime run --dir . -- zig-out/bin/nullclaw.wasm onboard
wasmtime run --dir . -- zig-out/bin/nullclaw.wasm agent -m "你好"
```

### 所需宿主接口（WASI Preview 1）

WASI 运行时必须实现 `wasi_snapshot_preview1` 模块中以下接口，nullclaw 才能正常运行：

| WASI 函数 | 用途 |
|---|---|
| `args_sizes_get` | 获取参数个数与总长度 |
| `args_get` | 读取命令行参数 |
| `proc_exit` | 进程退出（`std.process.exit`） |
| `fd_write` | 写 stdout（fd=1）和 stderr（fd=2），以及写入文件 |
| `fd_read` | 读取文件内容（`file.readToEndAlloc`） |
| `fd_seek` | 文件指针定位（`append_line` 追加写入时读取末尾字节） |
| `fd_close` | 关闭文件描述符 |
| `fd_filestat_get` | 获取文件元信息（`file.stat()`，用于获取文件大小） |
| `fd_prestat_get` | 枚举 preopened 目录（WASI 文件系统隔离机制） |
| `fd_prestat_dir_name` | 获取 preopened 目录名称 |
| `path_open` | 打开或创建文件（`openFile`、`createFile`） |
| `path_create_directory` | 创建目录（`makePath`） |
| `clock_time_get` | 获取当前时间（用于生成每日日志文件名，如 `2026-03-07.md`） |

> **说明**：主流 WASI 运行时（wasmtime、wasmer、WasmEdge、Node.js WASI API）均实现了上述全部接口。

运行时还需要通过 preopened 目录向模块授予文件系统访问权限：

```bash
# 只暴露指定目录，不开放宿主机完整文件系统
wasmtime run --dir /path/to/workspace::. -- nullclaw.wasm status
```

### 功能对比（WASI vs Native）

| 功能 | WASI | Native | 说明 |
|---|---|---|---|
| `version` / `help` | ✅ | ✅ | |
| `onboard`（初始化工作区） | ✅ | ✅ | |
| `status`（工作区检查） | ✅ | ✅ | |
| `identity show/set` | ✅ | ✅ | |
| `memory add/list/search/clear` | ✅ | ✅ | 基于 Markdown 文件 |
| `agent -m`（对话） | ⚠️ 有限 | ✅ | WASI 版仅基于本地记忆响应，无 LLM API 调用 |
| AI Provider（OpenAI、Anthropic 等） | ❌ | ✅ | WASI 版无 HTTP 客户端 |
| SQLite memory backend | ❌ | ✅ | C 链接在 `wasm32-wasi` 下不支持 |
| PostgreSQL backend | ❌ | ✅ | C 链接在 `wasm32-wasi` 下不支持 |
| 消息渠道（Telegram、Discord 等） | ❌ | ✅ | |
| HTTP 网关（gateway） | ❌ | ✅ | |
| 定时任务（cron） | ❌ | ✅ | |
| 安全沙箱（Landlock/Firejail/Docker） | ❌ | ✅ | |
| 可观测性（Observer） | ❌ | ✅ | |
| 运行时适配器（Docker/WASM/Cloudflare） | ❌ | ✅ | |
| 技能发现（skillforge） | ❌ | ✅ | |
| 硬件外设（Arduino/RPi/STM32） | ❌ | ✅ | |
| lib 模块导出（供外部 Zig 项目引用） | ❌ | ✅ | WASI 目标下 `lib_mod = null` |

### WASI 版 `agent` 行为说明

WASI 版的 `agent` 命令不调用 LLM，而是基于本地 `MEMORY.md` 进行关键词检索并生成简单回复：

```
NullClaw WASI: noted. Related memory: <匹配条目>. Next practical step: <你的消息>
```

这使得 WASI 二进制可以在完全离线、无 API Key 的环境中运行，适合作为嵌入式助手或离线工具的底层。

---

## 二、Cloudflare Workers WASM 决策核心（`wasm32-freestanding` 目标）

**源文件**：`examples/edge/cloudflare-worker/agent_core.zig`

### 构建方式

```bash
mkdir -p examples/edge/cloudflare-worker/dist
zig build-exe examples/edge/cloudflare-worker/agent_core.zig \
  -target wasm32-freestanding \
  -fno-entry \
  -rdynamic \
  -O ReleaseSmall \
  -femit-bin=examples/edge/cloudflare-worker/dist/agent_core.wasm
```

### 所需宿主接口

**无**。该模块是纯无状态计算，不依赖任何宿主函数（无 WASI、无 DOM API、无网络）。

WebAssembly 运行时只需实例化该模块：

```javascript
const instance = await WebAssembly.instantiate(wasmBytes, {}); // 第二个参数为空对象
```

### 导出接口

| 函数名 | 签名 | 说明 |
|---|---|---|
| `choose_policy` | `(text_len: u32, has_question: u32, has_urgent_keyword: u32, has_code_hint: u32) -> u32` | 根据文本特征返回响应策略 |

返回值枚举：

| 值 | 含义 |
|---|---|
| `0` | `concise`：简洁回复 |
| `1` | `detailed`：详细技术解答 |
| `2` | `urgent`：紧急事件处理 |

决策逻辑：

```
urgent_score  = has_urgent_keyword × 3 + (text_len > 900 ? 1 : 0)
detailed_score = has_question × 2 + has_code_hint × 2 + (text_len > 260 ? 1 : 0)

如果 urgent_score  ≥ 3 → urgent
如果 detailed_score ≥ 3 → detailed
否则                    → concise
```

### 功能对比（Cloudflare WASM vs Native）

该模块不是独立助手，而是 edge host 架构中的**可替换策略组件**：

| 功能 | agent_core.wasm | Native |
|---|---|---|
| 响应策略决策 | ✅ | ✅（由 agent 循环动态决定） |
| LLM 调用 | ❌（在 JS host 中完成） | ✅ |
| 网络访问 | ❌ | ✅ |
| 状态存储 | ❌（无状态） | ✅ |
| 文件系统 | ❌ | ✅ |
| 完整 agent 功能 | ❌ | ✅ |

### 整体架构

```
Telegram Webhook
      │
  worker.mjs (JS host)
  ├── 提取文本特征（text_len, has_question, has_urgent_keyword, has_code_hint）
  ├── 调用 agent_core.wasm → choose_policy(...)  ← 唯一 WASM 调用点
  ├── 根据策略构建 system prompt
  ├── 调用 OpenAI Chat Completions API
  └── 发送回复至 Telegram
```

---

## 三、两种产物对比总览

| 维度 | WASI CLI | Cloudflare WASM |
|---|---|---|
| 编译目标 | `wasm32-wasi` | `wasm32-freestanding` |
| 入口文件 | `src/main_wasi.zig` | `examples/edge/cloudflare-worker/agent_core.zig` |
| 所需宿主接口 | WASI Preview 1（13 个系统调用） | 无 |
| 导出接口 | `main`（WASI 标准入口） | `choose_policy(u32, u32, u32, u32) -> u32` |
| 适用运行时 | wasmtime、wasmer、WasmEdge、Node.js WASI | 浏览器、Cloudflare Workers、任意 WebAssembly 宿主 |
| 文件系统访问 | ✅（通过 preopened 目录授权） | ❌ |
| 网络访问 | ❌ | ❌（由 JS host 处理） |
| SQLite | ❌（WASI 不支持 C 链接） | ❌ |
| 完整 agent 功能 | ⚠️ 有限（无 LLM） | ❌ |
| 二进制大小目标 | < 1 MB | < 5 KB |
