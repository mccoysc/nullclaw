# Skill Authoring Guide

Skills are user-defined capabilities that extend nullclaw's behavior. Each skill is a directory containing a manifest and natural-language instructions that are injected into the agent's processing pipeline at configurable lifecycle points.

## Directory Structure

Skills live in `~/.nullclaw/workspace/skills/`. Each skill is a subdirectory:

```
~/.nullclaw/workspace/skills/
  my-skill/
    SKILL.toml      # manifest (preferred)
    SKILL.md        # instructions (natural language)
```

### Files

| File | Required | Description |
|------|----------|-------------|
| `SKILL.toml` | Recommended | Manifest with metadata and configuration |
| `skill.json` | Alternative | Legacy JSON manifest format |
| `SKILL.md` | Yes | Natural-language instructions for the skill |

If only `SKILL.md` exists (no manifest), the directory name is used as the skill name and the trigger defaults to `prompt`.

## Manifest Format (SKILL.toml)

```toml
[skill]
name = "my-skill"
version = "0.1.0"
description = "Brief description of what the skill does"
author = "your-name"
trigger = "prompt"
```

### Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | **required** | Unique identifier for the skill |
| `version` | string | `"0.1.0"` | Semantic version |
| `description` | string | `""` | Human-readable description |
| `author` | string | `""` | Author name |
| `trigger` | string | `"prompt"` | Lifecycle hook point (see below) |

### Legacy JSON Format (skill.json)

```json
{
  "name": "my-skill",
  "version": "0.1.0",
  "description": "Brief description",
  "author": "your-name",
  "trigger": "on_llm_before",
  "always": false,
  "requires_bins": ["docker"],
  "requires_env": ["MY_API_KEY"]
}
```

Additional fields in JSON format:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `always` | bool | `false` | If true, full instructions are always included in the system prompt |
| `requires_bins` | string[] | `[]` | CLI binaries the skill depends on (e.g. `"docker"`, `"git"`) |
| `requires_env` | string[] | `[]` | Environment variables required (e.g. `"OPENAI_API_KEY"`) |

If `requires_bins` or `requires_env` are specified, nullclaw checks availability at load time. Skills with missing dependencies are marked as unavailable and will not fire.

## Trigger Points (Lifecycle Hooks)

Each skill fires at exactly one trigger point. The `trigger` field in the manifest determines when the skill activates.

| Trigger | When it fires | Content passed to skill |
|---------|---------------|------------------------|
| `prompt` | System prompt construction (default) | System prompt text |
| `on_channel_receive_before` | Before processing a received channel message | Raw incoming message |
| `on_channel_receive_after` | After LLM response, before returning to channel | LLM response text |
| `on_channel_send_before` | Before sending response to channel | Response about to be sent |
| `on_channel_send_after` | After sending response to channel (fire-and-forget) | Sent response text |
| `on_llm_before` | Before sending user message to LLM | User message content |
| `on_llm_after` | After receiving LLM response | Raw LLM response |
| `on_llm_request` | Before building messages for the LLM provider | (empty) |
| `on_tool_call_before` | Before executing a tool call | `tool:<name> args:<json>` |
| `on_tool_call_after` | After executing a tool call | Tool output |

### Trigger Ordering

- **"before" triggers** (`on_channel_receive_before`, `on_channel_send_before`, `on_llm_before`, `on_tool_call_before`): skill instructions are **prepended** to the content.
- **"after" triggers** (`on_channel_receive_after`, `on_channel_send_after`, `on_llm_after`, `on_tool_call_after`): skill instructions are **appended** to the content.
- **`prompt`**: skill instructions are injected into the system prompt.
- **`on_llm_request`**: fires before the LLM request is constructed, allowing control over the request lifecycle (e.g. context compression).

## Skill Modes

There are two modes of operation for skills:

### 1. Plain Mode (Default)

When `SKILL.md` contains plain natural-language instructions (no `[action:...]` directive), the instructions are wrapped in tags and combined with the original content:

```
[skill-hook:on_llm_before name=my-skill]
<your SKILL.md instructions here>
[/skill-hook]

<original content>
```

For "before" triggers, instructions are prepended. For "after" triggers, instructions are appended. The LLM sees both the skill instructions and the original content, and follows the instructions naturally.

This is the simplest way to write skills and is backward-compatible with the original skill system.

**Example** (`SKILL.md`):

```markdown
Always respond in French, regardless of the language of the input message.
```

### 2. Agent Mode (`[action:agent]`)

When `SKILL.md` starts with `[action:agent]`, a stateless sub-agent is spawned to process the content. The sub-agent receives:

- **System prompt**: built-in processing instructions + your skill's natural-language instructions
- **User message**: the hook's original content

The sub-agent can make tool calls (up to 10 iterations) and must output a final decision using one of the behavior tags below.

**Example** (`SKILL.md`):

```markdown
[action:agent]
You are a content moderation agent. Examine the user's message for inappropriate content.
If the message is safe, pass it through unchanged.
If the message contains inappropriate content, intercept it and return a warning message.
```

#### Behavior Tags

The sub-agent must output exactly one of these tags in its final response:

| Tag | Effect |
|-----|--------|
| `[behavior:passthrough]` | Content passes through unchanged. Pipeline continues normally. |
| `[behavior:intercept]`<br>`<content>` | Pipeline stops. The content after the tag is returned directly as the response. |
| `[behavior:continue]`<br>`<content>` | The content after the tag replaces the original content, and the pipeline continues. |
| `[behavior:error]`<br>`<error message>` | Hook aborts. Error message is returned. Pipeline does not continue. |

#### Sub-Agent Behavior

- **Stateless**: no history is preserved between invocations. Each hook trigger is an independent call.
- **Tool access**: the sub-agent has access to the same tools as the main agent.
- **Isolated**: the sub-agent's execution does NOT trigger any skill hooks (prevents infinite recursion).
- **Temperature**: fixed at 0.3 for deterministic behavior.
- **Max iterations**: 10 tool-call rounds. If exhausted, returns `agent_error`.
- **Error handling**: on any error (LLM failure, invalid output format, iterations exhausted), returns `agent_error` immediately with no retries. Detailed error logs include the full input and output for debugging.

#### When Multiple Behavior Tags Appear

If the sub-agent outputs multiple behavior tags (e.g. reasoning with intermediate tags), the **last** tag in the response wins. This allows the agent to "think out loud" before committing to a final decision.

## Installation

### From Local Directory

Place the skill directory in the workspace skills folder:

```bash
# Manual
mkdir -p ~/.nullclaw/workspace/skills/my-skill
# Copy SKILL.toml and SKILL.md into the directory
```

Or install via nullclaw (copies the directory):

```bash
nullclaw skill install /path/to/my-skill
```

### From Git Repository

```bash
nullclaw skill install https://github.com/user/my-skill-repo.git
```

Supported URL formats:
- `https://host/owner/repo(.git)`
- `ssh://git@host/owner/repo(.git)`
- `git://host/owner/repo(.git)`
- `git@host:owner/repo(.git)`

### Removal

```bash
nullclaw skill remove my-skill
```

This deletes the skill directory from `~/.nullclaw/workspace/skills/my-skill/`.

## Override Behavior

Skills are loaded from two sources:

1. **Built-in skills** (shipped with nullclaw)
2. **Workspace skills** (`~/.nullclaw/workspace/skills/`)

Workspace skills with the same name as a built-in skill **override** the built-in version.

## Examples

### Example 1: Language Translation (Plain Mode)

Force all responses to be in French.

**`SKILL.toml`**:
```toml
[skill]
name = "french-reply"
version = "0.1.0"
description = "Force responses in French"
trigger = "on_llm_before"
```

**`SKILL.md`**:
```markdown
You must respond entirely in French, regardless of the input language.
```

### Example 2: Content Moderation (Agent Mode)

Inspect messages before they reach the LLM and block inappropriate content.

**`SKILL.toml`**:
```toml
[skill]
name = "content-filter"
version = "0.1.0"
description = "Filter inappropriate messages before LLM processing"
trigger = "on_channel_receive_before"
```

**`SKILL.md`**:
```markdown
[action:agent]
You are a content moderation agent. Analyze the incoming message.

- If the message is appropriate and safe, output:
  [behavior:passthrough]

- If the message contains inappropriate content, output:
  [behavior:intercept]
  Sorry, I cannot process this message due to content policy violations.
```

### Example 3: Response Formatting (Plain Mode, After Hook)

Append a signature to every outgoing message.

**`SKILL.toml`**:
```toml
[skill]
name = "signature"
version = "0.1.0"
description = "Append signature to outgoing messages"
trigger = "on_channel_send_before"
```

**`SKILL.md`**:
```markdown
Append the following text on a new line at the very end of your response:
--- Powered by NullClaw
```

### Example 4: Tool Call Guard (Agent Mode)

Block dangerous shell commands before execution.

**`SKILL.toml`**:
```toml
[skill]
name = "shell-guard"
version = "0.1.0"
description = "Block dangerous shell commands"
trigger = "on_tool_call_before"
```

**`SKILL.md`**:
```markdown
[action:agent]
You are a security guard for tool calls. You will receive tool call information in the format "tool:<name> args:<json>".

- If the tool is "shell" and the command contains dangerous operations (rm -rf, format, dd, mkfs, etc.), output:
  [behavior:intercept]
  Blocked: this shell command was deemed too dangerous to execute.

- For all other tool calls, output:
  [behavior:passthrough]
```

### Example 5: LLM Request Interceptor (Agent Mode)

Compress or restructure context before it reaches the LLM.

**`SKILL.toml`**:
```toml
[skill]
name = "context-compressor"
version = "0.1.0"
description = "Compress conversation context before LLM request"
trigger = "on_llm_request"
```

**`SKILL.md`**:
```markdown
[action:agent]
You are a context optimization agent. Review the conversation history and determine if it needs compression.

- If the context is short enough (under 2000 tokens estimated), output:
  [behavior:passthrough]

- If the context is too long, summarize the key points and output:
  [behavior:continue]
  <your compressed/summarized version of the context>
```

### Example 6: Post-Processing (Agent Mode, After Hook)

Rewrite LLM responses to match a specific tone.

**`SKILL.toml`**:
```toml
[skill]
name = "tone-adjuster"
version = "0.1.0"
description = "Adjust response tone to be more professional"
trigger = "on_llm_after"
```

**`SKILL.md`**:
```markdown
[action:agent]
You are a tone adjustment agent. Rewrite the given response to be more professional and formal while preserving all factual content.

Output:
[behavior:continue]
<your rewritten version>
```

## Debugging

When a sub-agent (`[action:agent]`) encounters an error, detailed logs are printed including:

- **Full skill instructions** sent to the sub-agent
- **Full hook content** (the original content being processed)
- **Full sub-agent output** (if any response was received)
- **Error type** (LLM call failure, invalid output format, max iterations exhausted)

Check nullclaw's log output (stderr) for lines tagged with `skills` scope to diagnose issues.

## Notes

- Multiple skills can share the same trigger point. For plain mode skills, all matching skills are combined (prepended/appended in order). For agent mode, the first `[action:agent]` skill at a trigger point wins.
- The `on_channel_send_after` hook is fire-and-forget: it executes after the response is already sent and cannot modify the sent content.
- Environment variable `NULLCLAW_HOME` controls the config directory (default: `~/.nullclaw`). Skills are loaded from `$NULLCLAW_HOME/workspace/skills/`.
- Unrecognized `[action:xxx]` directives produce a warning log and are treated as plain skill instructions.
