/*
 * nullclaw shared-library (.so) plugin example
 *
 * Build:
 *   cc -shared -fPIC -o example_plugin.so example_plugin.c
 *
 * Register in ~/.nullclaw/config.json:
 *   {
 *     "tools": {
 *       "plugins": {
 *         "add": [{"kind": "so", "path": "/path/to/example_plugin.so"}]
 *       }
 *     }
 *   }
 *
 * ABI contract (must match NullclawToolDef in src/tools/loader_so.zig):
 *
 *   typedef struct {
 *       const char* name;
 *       const char* description;
 *       const char* params_json;
 *       bool (*execute)(const char* args_json,
 *                       char*       out_buf,
 *                       size_t      out_cap,
 *                       size_t*     out_len);
 *   } NullclawToolDef;
 *
 *   NullclawToolDef* nullclaw_tools_list(size_t* out_count);
 *   void             nullclaw_tools_free(NullclawToolDef* tools, size_t count);
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

/* ── ABI struct (must match loader_so.zig SoToolDef) ─────────── */

typedef struct {
    const char *name;
    const char *description;
    const char *params_json;
    bool (*execute)(const char *args_json,
                    char       *out_buf,
                    size_t      out_cap,
                    size_t     *out_len);
} NullclawToolDef;

/* ── Tool implementations ─────────────────────────────────────── */

/* so_echo: returns "echo: <args_json>" */
static bool so_echo_execute(const char *args_json,
                             char       *out_buf,
                             size_t      out_cap,
                             size_t     *out_len)
{
    int n = snprintf(out_buf, out_cap, "echo: %s", args_json);
    *out_len = (n > 0 && (size_t)n < out_cap) ? (size_t)n : (out_cap > 0 ? out_cap - 1 : 0);
    return true;
}

/* so_reverse: reverses the value of the "text" field (naive, ASCII only) */
static bool so_reverse_execute(const char *args_json,
                                char       *out_buf,
                                size_t      out_cap,
                                size_t     *out_len)
{
    /* Extract the value of "text" from the JSON string by finding it between
     * the first pair of quotes after "text": — good enough for this demo. */
    const char *key = "\"text\":";
    const char *p   = strstr(args_json, key);
    const char *src = "";
    size_t      src_len = 0;

    if (p) {
        p += strlen(key);
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '"') {
            p++;
            /* Walk the string handling backslash escapes so that escaped
             * quotes (e.g. \"hello\") don't terminate the scan early. */
            const char *start = p;
            while (*p && *p != '"') {
                if (*p == '\\' && *(p + 1)) p++; /* skip escaped char */
                p++;
            }
            src = start;
            src_len = (size_t)(p - start);
        }
    }

    if (src_len == 0) {
        *out_len = 0;
        return false; /* missing or non-string "text" field */
    }

    size_t out = src_len < out_cap ? src_len : out_cap;
    for (size_t i = 0; i < out; i++)
        out_buf[i] = src[src_len - 1 - i];
    *out_len = out;
    return true;
}

/* ── Tool table ───────────────────────────────────────────────── */

static NullclawToolDef tool_defs[] = {
    {
        "so_echo",
        "Echoes the raw JSON args back as output.",
        "{\"type\":\"object\",\"properties\":{}}",
        so_echo_execute,
    },
    {
        "so_reverse",
        "Reverses the value of the 'text' argument (ASCII).",
        "{\"type\":\"object\",\"required\":[\"text\"],"
        "\"properties\":{\"text\":{\"type\":\"string\"}}}",
        so_reverse_execute,
    },
};

/* ── Required exports ─────────────────────────────────────────── */

NullclawToolDef *nullclaw_tools_list(size_t *out_count)
{
    *out_count = sizeof(tool_defs) / sizeof(tool_defs[0]);
    return tool_defs;
}

void nullclaw_tools_free(NullclawToolDef *tools, size_t count)
{
    /* Static array — nothing to free. */
    (void)tools;
    (void)count;
}
