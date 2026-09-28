#ifndef JORT_BROKER_IDENTITY_H
#define JORT_BROKER_IDENTITY_H

#include <stdbool.h>
#include <stddef.h>

#define JORT_APP_IDENTIFIER "dev.jort.editor"
#define JORT_BROKER_IDENTIFIER "dev.jort.javascript.broker"
#define JORT_WORKER_IDENTIFIER "dev.jort.javascript.worker"

/* Requirements are derived from checked, sealed nested code, never request data. */
bool jort_broker_copy_app_requirement(char *requirement, size_t capacity);
bool jort_broker_verified_worker_path(char *path, size_t capacity);

#endif
