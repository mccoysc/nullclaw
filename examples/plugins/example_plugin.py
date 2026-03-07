#!/usr/bin/env python3
"""
nullclaw Python script plugin example.

Register in ~/.nullclaw/config.json:
    {
      "tools": {
        "plugins": {
          "add": [{"kind": "python", "path": "/path/to/example_plugin.py"}]
        }
      }
    }

Discovery protocol (called once at load time):
    python3 example_plugin.py --nullclaw-list
    → stdout: JSON array of tool descriptors, exit 0

Execution protocol (called per tool invocation):
    python3 example_plugin.py --nullclaw-call <tool_name> '<args_json>'
    → stdout: tool output, exit 0 = success, non-zero = failure
"""

import json
import sys

# ── Tool definitions ──────────────────────────────────────────────

TOOLS = [
    {
        "name": "py_upper",
        "description": "Converts the 'text' argument to uppercase.",
        "params_json": json.dumps({
            "type": "object",
            "required": ["text"],
            "properties": {"text": {"type": "string"}},
        }),
    },
    {
        "name": "py_word_count",
        "description": "Counts the words in the 'text' argument.",
        "params_json": json.dumps({
            "type": "object",
            "required": ["text"],
            "properties": {"text": {"type": "string"}},
        }),
    },
]

# ── Tool implementations ──────────────────────────────────────────

def py_upper(args: dict) -> str:
    return args.get("text", "").upper()


def py_word_count(args: dict) -> str:
    words = args.get("text", "").split()
    return str(len(words))


HANDLERS = {
    "py_upper": py_upper,
    "py_word_count": py_word_count,
}

# ── Entry point ───────────────────────────────────────────────────

def main() -> None:
    argv = sys.argv[1:]

    if "--nullclaw-list" in argv:
        print(json.dumps(TOOLS))
        return

    if "--nullclaw-call" in argv:
        idx = argv.index("--nullclaw-call")
        tool_name = argv[idx + 1] if idx + 1 < len(argv) else ""
        raw_args  = argv[idx + 2] if idx + 2 < len(argv) else "{}"

        handler = HANDLERS.get(tool_name)
        if handler is None:
            sys.stderr.write(f"unknown tool: {tool_name}\n")
            sys.exit(1)

        try:
            args = json.loads(raw_args)
        except json.JSONDecodeError as exc:
            sys.stderr.write(f"invalid args JSON: {exc}\n")
            sys.exit(1)

        try:
            result = handler(args)
        except (KeyError, ValueError, TypeError) as exc:
            sys.stderr.write(f"tool error: {exc}\n")
            sys.exit(1)

        print(result)
        return

    sys.stderr.write(
        "Usage:\n"
        "  --nullclaw-list\n"
        "  --nullclaw-call <tool_name> '<args_json>'\n"
    )
    sys.exit(1)


if __name__ == "__main__":
    main()
