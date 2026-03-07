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
 *     node example_plugin.js --nullclaw-list
 *     → stdout: JSON array of tool descriptors, exit 0
 *
 * Execution protocol (called per tool invocation):
 *     node example_plugin.js --nullclaw-call <tool_name> '<args_json>'
 *     → stdout: tool output, exit 0 = success, non-zero = failure
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
  return (args.text || '').split('').reverse().join('');
}

function js_char_count(args) {
  return String((args.text || '').length);
}

const HANDLERS = { js_reverse, js_char_count };

// ── Entry point ──────────────────────────────────────────────────

const argv = process.argv.slice(2);

if (argv.includes('--nullclaw-list')) {
  process.stdout.write(JSON.stringify(TOOLS) + '\n');

} else if (argv.includes('--nullclaw-call')) {
  const idx      = argv.indexOf('--nullclaw-call');
  const toolName = argv[idx + 1] || '';
  const rawArgs  = argv[idx + 2] || '{}';

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

  process.stdout.write(String(result) + '\n');

} else {
  process.stderr.write(
    'Usage:\n' +
    '  --nullclaw-list\n' +
    '  --nullclaw-call <tool_name> \'<args_json>\'\n'
  );
  process.exit(1);
}
