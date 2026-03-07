# WASM Build Analysis

NullClaw ships two distinct WASM artifacts targeting different deployment scenarios.

---

## 1. WASI CLI Binary (`wasm32-wasi` target)

### Building

```bash
zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseSmall
```

The build system automatically switches the entry point to `src/main_wasi.zig` and disables all
C-linked backends (SQLite, PostgreSQL).

### Running

Using [wasmtime](https://wasmtime.dev/):

```bash
# Mount the current directory as a preopened directory and pass CLI arguments
wasmtime run --dir . -- zig-out/bin/nullclaw.wasm onboard
wasmtime run --dir . -- zig-out/bin/nullclaw.wasm agent -m "hello"
```

### Required Host Interfaces (WASI Preview 1)

The WASI runtime must implement the following functions from the `wasi_snapshot_preview1` module:

| WASI function | Purpose |
|---|---|
| `args_sizes_get` | Query argument count and total byte length |
| `args_get` | Read command-line arguments |
| `proc_exit` | Process exit (`std.process.exit`) |
| `fd_write` | Write to stdout (fd=1), stderr (fd=2), and files |
| `fd_read` | Read file contents (`file.readToEndAlloc`) |
| `fd_seek` | Seek within a file (used by `append_line` to read the last byte) |
| `fd_close` | Close a file descriptor |
| `fd_filestat_get` | Retrieve file metadata (`file.stat()`, used to get file size) |
| `fd_prestat_get` | Enumerate preopened directories (WASI filesystem isolation) |
| `fd_prestat_dir_name` | Retrieve the name of a preopened directory |
| `path_open` | Open or create files (`openFile`, `createFile`) |
| `path_create_directory` | Create directories (`makePath`) |
| `clock_time_get` | Get the current time (used to generate daily log filenames like `2026-03-07.md`) |

> **Note**: All major WASI runtimes (wasmtime, wasmer, WasmEdge, Node.js WASI API) implement these
> functions.

The runtime must also grant filesystem access via preopened directories:

```bash
# Expose only the specified directory, not the full host filesystem
wasmtime run --dir /path/to/workspace::. -- nullclaw.wasm status
```

### Feature Comparison (WASI vs Native)

| Feature | WASI | Native | Notes |
|---|---|---|---|
| `version` / `help` | ✅ | ✅ | |
| `onboard` (workspace init) | ✅ | ✅ | |
| `status` (workspace check) | ✅ | ✅ | |
| `identity show/set` | ✅ | ✅ | |
| `memory add/list/search/clear` | ✅ | ✅ | Markdown-file backed |
| `agent -m` (chat) | ⚠️ limited | ✅ | WASI responds from local memory only — no LLM API calls |
| AI providers (OpenAI, Anthropic, etc.) | ❌ | ✅ | No HTTP client in WASI build |
| SQLite memory backend | ❌ | ✅ | C linking unsupported on `wasm32-wasi` |
| PostgreSQL backend | ❌ | ✅ | C linking unsupported on `wasm32-wasi` |
| Messaging channels (Telegram, Discord, etc.) | ❌ | ✅ | |
| HTTP gateway | ❌ | ✅ | |
| Cron / scheduled tasks | ❌ | ✅ | |
| Security sandboxes (Landlock/Firejail/Docker) | ❌ | ✅ | |
| Observability hooks | ❌ | ✅ | |
| Runtime adapters (Docker/WASM/Cloudflare) | ❌ | ✅ | |
| Skill discovery (skillforge) | ❌ | ✅ | |
| Hardware peripherals (Arduino/RPi/STM32) | ❌ | ✅ | |
| Library module export (for Zig consumers) | ❌ | ✅ | `lib_mod = null` on WASI target |

### WASI `agent` Behavior

The WASI `agent` command does **not** call an LLM. It performs keyword search over the local
`MEMORY.md` and generates a simple reply:

```
NullClaw WASI: noted. Related memory: <matched entry>. Next practical step: <your message>
```

This allows the WASI binary to run fully offline without any API key, making it suitable as an
embedded assistant or offline CLI tool.

---

## 2. Cloudflare Workers WASM Policy Core (`wasm32-freestanding` target)

**Source**: `examples/edge/cloudflare-worker/agent_core.zig`

### Building

```bash
mkdir -p examples/edge/cloudflare-worker/dist
zig build-exe examples/edge/cloudflare-worker/agent_core.zig \
  -target wasm32-freestanding \
  -fno-entry \
  -rdynamic \
  -O ReleaseSmall \
  -femit-bin=examples/edge/cloudflare-worker/dist/agent_core.wasm
```

### Required Host Interfaces

**None.** The module is pure stateless computation with no host function imports (no WASI, no DOM
API, no network calls).

Instantiate with an empty import object:

```javascript
const instance = await WebAssembly.instantiate(wasmBytes, {}); // empty imports
```

### Exported Interface

| Function | Signature | Description |
|---|---|---|
| `choose_policy` | `(text_len: u32, has_question: u32, has_urgent_keyword: u32, has_code_hint: u32) -> u32` | Returns a response policy based on text features |

Return value enum:

| Value | Meaning |
|---|---|
| `0` | `concise`: short direct answer |
| `1` | `detailed`: step-by-step technical guidance |
| `2` | `urgent`: incident-response mode |

Decision logic:

```
urgent_score   = has_urgent_keyword × 3 + (text_len > 900 ? 1 : 0)
detailed_score = has_question × 2 + has_code_hint × 2 + (text_len > 260 ? 1 : 0)

if urgent_score  ≥ 3  → urgent
if detailed_score ≥ 3  → detailed
else                   → concise
```

### Feature Comparison (Cloudflare WASM vs Native)

This module is not a standalone assistant but a **swappable policy component** in an edge-host
architecture:

| Feature | agent_core.wasm | Native |
|---|---|---|
| Response policy decision | ✅ | ✅ (determined dynamically by agent loop) |
| LLM calls | ❌ (handled by JS host) | ✅ |
| Network access | ❌ | ✅ |
| State / storage | ❌ (stateless) | ✅ |
| Filesystem | ❌ | ✅ |
| Full agent capabilities | ❌ | ✅ |

### Architecture

```
Telegram Webhook
      │
  worker.mjs (JS host)
  ├── Extract text features (text_len, has_question, has_urgent_keyword, has_code_hint)
  ├── Call agent_core.wasm → choose_policy(...)   ← only WASM call
  ├── Build system prompt from returned policy
  ├── Call OpenAI Chat Completions API
  └── Send reply to Telegram chat
```

---

## 3. Side-by-Side Summary

| Dimension | WASI CLI | Cloudflare WASM |
|---|---|---|
| Compile target | `wasm32-wasi` | `wasm32-freestanding` |
| Entry file | `src/main_wasi.zig` | `examples/edge/cloudflare-worker/agent_core.zig` |
| Required host interfaces | WASI Preview 1 (13 syscalls) | None |
| Exported interface | `main` (standard WASI entry) | `choose_policy(u32, u32, u32, u32) -> u32` |
| Compatible runtimes | wasmtime, wasmer, WasmEdge, Node.js WASI | Browser, Cloudflare Workers, any WebAssembly host |
| Filesystem access | ✅ (via preopened directories) | ❌ |
| Network access | ❌ | ❌ (handled by JS host) |
| SQLite | ❌ (C linking unsupported on WASI) | ❌ |
| Full agent features | ⚠️ limited (no LLM) | ❌ |
| Target binary size | < 1 MB | < 5 KB |
