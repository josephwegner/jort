#ifndef JORT_JAVASCRIPT_H
#define JORT_JAVASCRIPT_H
#include <stddef.h>
#include <stdbool.h>
typedef struct JortJSCancellation JortJSCancellation;
JortJSCancellation *jort_js_cancellation_new(void);
void jort_js_cancel(JortJSCancellation *token);
void jort_js_cancellation_free(JortJSCancellation *token);
// Caller owns returned UTF-8 JSON/error and frees it using jort_js_free.
char *jort_js_run(const char *source, const char *input_json, const char *entry, size_t memory_limit,
                  double timeout_seconds, size_t result_limit,
                  JortJSCancellation *token, int *status);
char *jort_js_validate(const char *source);
// Worker-only raw UTF-8 adapter: exact content is constructed as a JS string, never
// parsed as executable text. The returned string is exclusively output or public error.
char *jort_js_run_text(const char *source, const char *content, const char *clock,
                      const char *uuid, const char *entry, double timeout_seconds,
                      size_t output_bytes, size_t output_lines, JortJSCancellation *token,
                      int *status);
void jort_js_free(char *value);
#endif
