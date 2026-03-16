/// Stub implementations of libcurl functions for cross-compilation targets
/// and environments where native libcurl is unavailable (e.g. Windows CI).
///
/// All functions return error codes. The runtime falls back to the subprocess
/// HTTP backend (`curl` CLI) when the native backend is unavailable.

#include <stddef.h>

/* CURLcode values */
#define CURLE_FAILED_INIT 2

int curl_global_init(long flags) { (void)flags; return CURLE_FAILED_INIT; }

void *curl_easy_init(void) { return (void *)0; }
void curl_easy_cleanup(void *h) { (void)h; }
int curl_easy_perform(void *h) { (void)h; return CURLE_FAILED_INIT; }
int curl_easy_setopt(void *h, int opt, ...) { (void)h; (void)opt; return CURLE_FAILED_INIT; }
int curl_easy_getinfo(void *h, int info, ...) { (void)h; (void)info; return CURLE_FAILED_INIT; }

struct curl_slist { char *data; struct curl_slist *next; };
struct curl_slist *curl_slist_append(struct curl_slist *list, const char *s) {
    (void)list; (void)s; return (void *)0;
}
void curl_slist_free_all(struct curl_slist *list) { (void)list; }

/* WebSocket stubs */
void *curl_ws(void *h) { (void)h; return (void *)0; }
int curl_ws_send(void *h, const void *buf, size_t len, size_t *sent, int fg, unsigned int flags) {
    (void)h; (void)buf; (void)len; (void)sent; (void)fg; (void)flags; return CURLE_FAILED_INIT;
}
int curl_ws_recv(void *h, void *buf, size_t len, size_t *recvd, const void **meta) {
    (void)h; (void)buf; (void)len; (void)recvd; (void)meta; return CURLE_FAILED_INIT;
}
