# Configuration Hot-Reload

NullClaw monitors the `config.json` file for changes and dynamically applies updates **without restarting the process**. This covers both global model parameters and per-channel configurations.

## How It Works

1. The daemon polls the config file's modification time (mtime) on each supervision loop iteration.
2. When a change is detected, the new config is loaded and diffed against the current config.
3. Changes are applied granularly based on what actually changed -- sessions that are unaffected remain untouched and keep their full conversation history.

## What Gets Hot-Reloaded

| Change | Effect |
|--------|--------|
| Global model params (`provider`, `model`, `max_context_tokens`, `temperature`) | Sessions without per-endpoint overrides are hot-updated in place. Conversation history is preserved. |
| Per-endpoint `model_override` | Only sessions on that endpoint are hot-updated. Conversation history is preserved. |
| Structural endpoint change (host, port, keys, topic) | Sessions on that endpoint are evicted (reset). The channel is restarted with the new config. |
| Endpoint removed | Sessions on that endpoint are evicted and resources freed. |
| Endpoint added | A new channel listener is started. No existing sessions are affected. |
| Account removed | All sessions and listeners for that account are stopped and cleaned up. |
| Account added | New channel listeners are started. |

## Change Classification

The hot-reload system uses `endpoint_id` to correlate running sessions with config entries. For each endpoint, changes are classified into three categories:

### 1. No Change

If neither the structural fields nor the model override fields have changed, the session is left completely untouched. The conversation history, context, and all state are preserved.

### 2. Model-Only Change (Hot Update)

If only the `model_override` fields changed (or the global model config changed for endpoints without overrides), the session's model parameters are updated **in place**. The conversation history and context are fully preserved -- only the LLM provider/model/temperature/token-limit settings change going forward.

Examples:
- Changing `temperature` from `0.7` to `0.9`
- Switching the model from `gpt-4o` to `claude-sonnet-4-20250514`
- Adjusting `max_context_tokens`

### 3. Structural Change (Session Reset)

If any of the following fields change, the session is considered structurally different and is **evicted** (conversation history is lost, a fresh session starts):

**MQTT:**
- `host`, `port`, `username`, `password`, `tls`, `client_id`
- `peer_pubkey`, `local_privkey`, `local_pubkey`
- `listen_topic`, `reply_topic`

**Redis Stream:**
- `host`, `port`, `username`, `password`, `tls`, `db`
- `peer_pubkey`, `local_privkey`, `local_pubkey`
- `listen_topic`, `reply_topic`
- `consumer_group`, `consumer_name`

When a structural change occurs, the entire channel for that account is stopped and restarted with the new configuration.

## The Role of endpoint_id

Each endpoint has a unique `endpoint_id` (auto-generated during onboarding as a 16-char random hex string). This ID is the key to the hot-reload system:

- **Matching**: The system finds the "same" endpoint across old and new configs by comparing `endpoint_id` values.
- **Session correlation**: Sessions are keyed as `{channel_type}:{endpoint_id}`, so even if the topic or host changes, the system can locate the correct session to evict or update.
- **Stability**: As long as the `endpoint_id` stays the same, the system knows it's dealing with the same logical endpoint.

### What if endpoint_id is Missing?

If a config was manually edited without an `endpoint_id`, the session key falls back to `{channel_type}:{account_id}:{topic}`. Hot-reload still works, but renaming the topic will create a new session rather than migrating the existing one.

## Global vs Per-Endpoint Model Config

NullClaw supports model configuration at two levels:

### Global Config

Set at the top level of `config.json`:

```jsonc
{
  "provider": "openrouter",
  "model": "openrouter/minimax/minimax-m2.5",
  "max_context_tokens": 16384,
  "temperature": 0.7
}
```

All sessions use these settings by default.

### Per-Endpoint Override

Set within an endpoint's `model_override`:

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

Endpoints with `model_override` use those settings instead of the global config.

### Hot-Reload Interaction

- **Global model change + endpoint has override**: No effect -- the endpoint keeps its own override.
- **Global model change + endpoint has no override**: Session is hot-updated with the new global settings.
- **Endpoint override change**: Only that endpoint's session is hot-updated.

## Examples

### Example 1: Change Global Temperature

**Before:**
```json
{ "temperature": 0.7 }
```

**After (edit and save config.json):**
```json
{ "temperature": 0.9 }
```

**Result:** All sessions without per-endpoint temperature overrides are hot-updated. Conversation history is preserved.

### Example 2: Add a New MQTT Endpoint

**Before:**
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

**After:**
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

**Result:** The existing session on `device/1` is untouched. A new listener is started for `device/2`. The MQTT channel is restarted to pick up the new endpoint, but the `device/1` session's conversation history is preserved (it is not evicted because its endpoint config hasn't changed).

### Example 3: Remove an Endpoint

Remove an endpoint from the `endpoints` array. The corresponding session is evicted and its resources are freed. Other endpoints are unaffected.

### Example 4: Change Broker Host

**Before:**
```json
{ "endpoint_id": "aaa...", "host": "broker1.example.com", ... }
```

**After:**
```json
{ "endpoint_id": "aaa...", "host": "broker2.example.com", ... }
```

**Result:** This is a structural change. The session on `aaa...` is evicted (conversation history is lost), and the channel is restarted connecting to the new broker.

### Example 5: Rotate P256 Keys

Changing `peer_pubkey`, `local_privkey`, or `local_pubkey` is a structural change. The session is evicted and a new one is created with the new keys.

## Monitoring

Hot-reload events are logged at the `info` level. Look for these log messages:

```
Config file changed, reloading...
MQTT endpoint 'aaa...' model config changed, hot-updating
MQTT endpoint 'bbb...' structural change, resetting session
MQTT endpoint 'ccc...' removed, evicting session
MQTT account 'staging' added, starting channel
Global model changed, hot-updating MQTT endpoint 'ddd...'
Config reload complete
```

## Context Auto-Compaction

When `max_context_tokens` is configured (globally or per-endpoint), NullClaw automatically monitors the token count of each session's conversation context. When the limit is reached, context compaction is triggered automatically -- summarizing older messages to free up space while retaining essential context.

This limit is also hot-reloadable: changing `max_context_tokens` in the config takes effect immediately on affected sessions without losing conversation history.
