# nullclaw Plugin Examples

This directory contains ready-to-use examples for each of the three plugin
kinds supported by nullclaw's dynamic tool registry.

> **Security Warning:** Plugins execute arbitrary code with the same privileges
> as the nullclaw process. Only load plugins from sources you trust. Shared
> libraries (`so`/`dll`) run native code inside the host process; script
> plugins (`python`/`node`) spawn child processes that inherit the environment.
> Review every plugin before adding it to your configuration.

## Plugin kinds

| Kind     | File                   | Runtime required           |
|----------|------------------------|----------------------------|
| `so`     | `example_plugin.c`     | Any C compiler (`cc`)      |
| `python` | `example_plugin.py`    | Python 3 (`python3`)       |
| `node`   | `example_plugin.js`    | Node.js (`node`)           |

---

## Shared-library plugin (`so`)

### Build

```bash
cc -shared -fPIC -o example_plugin.so example_plugin.c
```

### ABI contract

The library must export two C symbols:

```c
NullclawToolDef* nullclaw_tools_list(size_t* out_count);
void             nullclaw_tools_free(NullclawToolDef* tools, size_t count);
```

`NullclawToolDef` layout (must match `SoToolDef` in `src/tools/loader_so.zig`):

```c
typedef struct {
    const char* name;
    const char* description;
    const char* params_json;
    bool (*execute)(const char* args_json,
                    char*       out_buf,
                    size_t      out_cap,
                    size_t*     out_len);
} NullclawToolDef;
```

- `execute` writes UTF-8 output into `out_buf` (capacity `out_cap`) and sets
  `*out_len` to the number of bytes written.  Return `true` for success, `false`
  for failure.
- `nullclaw_tools_free` is called after all wrappers for this library are
  removed. Free any heap memory allocated by `nullclaw_tools_list` here; for
  static arrays you can leave it as a no-op.

### Register

```json
{
  "tools": {
    "plugins": {
      "add": [{"kind": "so", "path": "/absolute/path/to/example_plugin.so"}]
    }
  }
}
```

---

## Python script plugin (`python`)

### Requirements

`python3` must be in `$PATH`.

### Protocol

| Step      | Command                                                        |
|-----------|----------------------------------------------------------------|
| Discovery | `python3 plugin.py --nullclaw-list --nullclaw-output <path>`                            |
| Execute   | `python3 plugin.py --nullclaw-call <tool_name> '<args_json>' --nullclaw-output <path>` |

- Discovery writes a JSON array to the `--nullclaw-output` file and exits 0.
- Execution writes the result to the `--nullclaw-output` file; exit 0 = success, non-zero = failure.
- Using a file instead of stdout avoids contamination from noisy dependency imports.

### Register

```json
{
  "tools": {
    "plugins": {
      "add": [{"kind": "python", "path": "/absolute/path/to/example_plugin.py"}]
    }
  }
}
```

---

## Node.js script plugin (`node`)

### Requirements

`node` (or `nodejs`) must be in `$PATH`.

### Protocol

Same as Python, with `node` replacing `python3`:

| Step      | Command                                                                            |
|-----------|------------------------------------------------------------------------------------|
| Discovery | `node plugin.js --nullclaw-list --nullclaw-output <path>`                          |
| Execute   | `node plugin.js --nullclaw-call <tool_name> '<args_json>' --nullclaw-output <path>`|

### Register

```json
{
  "tools": {
    "plugins": {
      "add": [{"kind": "node", "path": "/absolute/path/to/example_plugin.js"}]
    }
  }
}
```

---

## Hot-reload

Set `tools.plugins.hot_reload_interval_secs` (default: 5) to the polling
interval in seconds.  Set to 0 to disable hot-reload.

```json
{
  "tools": {
    "plugins": {
      "hot_reload_interval_secs": 10,
      "add": [...]
    }
  }
}
```

When the config file's mtime changes, the registry re-applies the plugin list
automatically — no restart needed.
