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
    python3 example_plugin.py --nullclaw-list --nullclaw-output /tmp/nc_XXXX
    → writes JSON array of tool descriptors to the output file, exit 0

Execution protocol (called per tool invocation):
    python3 example_plugin.py --nullclaw-call <tool_name> '<args_json>' --nullclaw-output /tmp/nc_XXXX
    → writes tool result to the output file, exit 0 = success, non-zero = failure

Output is written to the file specified by --nullclaw-output instead of stdout
so that noisy dependency imports do not contaminate the result.
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
    if "text" not in args or not isinstance(args["text"], str):
        raise ValueError("Missing or invalid 'text' parameter")
    return args["text"].upper()


def py_word_count(args: dict) -> str:
    if "text" not in args or not isinstance(args["text"], str):
        raise ValueError("Missing or invalid 'text' parameter")
    words = args["text"].split()
    return str(len(words))


HANDLERS = {
    "py_upper": py_upper,
    "py_word_count": py_word_count,
}

# ── Helpers ───────────────────────────────────────────────────────

def _get_output_path(argv):
    """Extract --nullclaw-output <path> from argv, or None."""
    if "--nullclaw-output" in argv:
        idx = argv.index("--nullclaw-output")
        if idx + 1 < len(argv):
            return argv[idx + 1]
    return None


def _write_output(argv, data):
    """Write data to the --nullclaw-output file, or stdout as fallback."""
    path = _get_output_path(argv)
    if path:
        with open(path, "w", encoding="utf-8") as f:
            f.write(data)
    else:
        print(data)

# ── Entry point ───────────────────────────────────────────────────

def main():
    argv = sys.argv[1:]

    if "--nullclaw-list" in argv:
        _write_output(argv, json.dumps(TOOLS))
        return

    if "--nullclaw-call" in argv:
        idx = argv.index("--nullclaw-call")
        if idx + 2 >= len(argv):
            sys.stderr.write("usage: --nullclaw-call <tool_name> '<args_json>'\n")
            sys.exit(1)
        tool_name = argv[idx + 1]
        raw_args  = argv[idx + 2]

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

        _write_output(argv, result)
        return

    sys.stderr.write(
        "Usage:\n"
        "  --nullclaw-list [--nullclaw-output <path>]\n"
        "  --nullclaw-call <tool_name> '<args_json>' [--nullclaw-output <path>]\n"
    )
    sys.exit(1)


if __name__ == "__main__":
    main()
