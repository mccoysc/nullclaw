#!/usr/bin/env node
/**
 * nullclaw Node.js script plugin example.
 *
 * Register in ~/.nullclaw/config.json:
 *     {
 *       "tools": {
 *         "plugins": {
 *           "add": [{"kind": "node", "path": "/path/to/example_plugin.js"}]
 *         }
 *       }
 *     }
 *
 * Discovery protocol (called once at load time):
 *     node example_plugin.js --nullclaw-list --nullclaw-output /tmp/nc_XXXX
 *     → writes JSON array of tool descriptors to the output file, exit 0
 *
 * Execution protocol (called per tool invocation):
 *     node example_plugin.js --nullclaw-call <tool_name> '<args_json>' --nullclaw-output /tmp/nc_XXXX
 *     → writes tool result to the output file, exit 0 = success, non-zero = failure
 *
 * Output is written to the file specified by --nullclaw-output instead of
 * stdout so that noisy dependency imports do not contaminate the result.
 */

'use strict';

// ── Tool definitions ─────────────────────────────────────────────

const TOOLS = [
  {
    name: 'js_reverse',
    description: "Reverses the 'text' argument.",
    params_json: JSON.stringify({
      type: 'object',
      required: ['text'],
      properties: { text: { type: 'string' } },
    }),
  },
  {
    name: 'js_char_count',
    description: "Returns the character count of the 'text' argument.",
    params_json: JSON.stringify({
      type: 'object',
      required: ['text'],
      properties: { text: { type: 'string' } },
    }),
  },
];

// ── Tool implementations ─────────────────────────────────────────

function js_reverse(args) {
  if (!args || typeof args.text !== 'string') {
    throw new Error("Missing or invalid 'text' parameter");
  }
  return args.text.split('').reverse().join('');
}

function js_char_count(args) {
  if (!args || typeof args.text !== 'string') {
    throw new Error("Missing or invalid 'text' parameter");
  }
  return String(args.text.length);
}

const HANDLERS = { js_reverse, js_char_count };

// ── Helpers ─────────────────────────────────────────────────────

const fs = require('fs');

function getOutputPath(argv) {
  const idx = argv.indexOf('--nullclaw-output');
  if (idx !== -1 && idx + 1 < argv.length) return argv[idx + 1];
  return null;
}

function writeOutput(argv, data) {
  const path = getOutputPath(argv);
  if (path) {
    fs.writeFileSync(path, data, 'utf-8');
  } else {
    process.stdout.write(data + '\n');
  }
}

// ── Entry point ──────────────────────────────────────────────────

const argv = process.argv.slice(2);

if (argv.includes('--nullclaw-list')) {
  writeOutput(argv, JSON.stringify(TOOLS));

} else if (argv.includes('--nullclaw-call')) {
  const idx = argv.indexOf('--nullclaw-call');
  if (idx + 2 >= argv.length) {
    process.stderr.write('usage: --nullclaw-call <tool_name> \'<args_json>\'\n');
    process.exit(1);
  }
  const toolName = argv[idx + 1];
  const rawArgs  = argv[idx + 2];

  const handler = HANDLERS[toolName];
  if (!handler) {
    process.stderr.write(`unknown tool: ${toolName}\n`);
    process.exit(1);
  }

  let result;
  try {
    result = handler(JSON.parse(rawArgs));
  } catch (err) {
    process.stderr.write(`tool error: ${err.message}\n`);
    process.exit(1);
  }

  writeOutput(argv, String(result));

} else {
  process.stderr.write(
    'Usage:\n' +
    '  --nullclaw-list [--nullclaw-output <path>]\n' +
    '  --nullclaw-call <tool_name> \'<args_json>\' [--nullclaw-output <path>]\n'
  );
  process.exit(1);
}
