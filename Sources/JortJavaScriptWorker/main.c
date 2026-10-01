#include "JortJavaScript.h"
#include "JortJavaScriptProtocol.h"

#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

extern char **environ;

static int numeric(const char *text, uint32_t *value) {
    if (!text || !*text) return 0;
    uint64_t number = 0;
    for (const char *p = text; *p; ++p) {
        if (*p < '0' || *p > '9') return 0;
        number = number * 10 + (unsigned)(*p - '0');
        if (number > UINT32_MAX) return 0;
    }
    *value = (uint32_t)number;
    return 1;
}

static int limit(int resource, rlim_t soft, rlim_t hard) {
    struct rlimit current, desired = { soft, hard };
    if (getrlimit(resource, &current) || soft > current.rlim_max || hard > current.rlim_max ||
        setrlimit(resource, &desired) || getrlimit(resource, &current)) return 0;
    return current.rlim_cur == soft && current.rlim_max == hard;
}

static int bootstrap(uint32_t milliseconds, JortJSReady *ready) {
    // Darwin also inherits registered, exception and bootstrap Mach ports.
    // Drop these capabilities after libSystem/App Sandbox initialization but
    // before Ready or any untrusted source. The worker uses pipes, not XPC.
    // Keep intrinsic task/thread/host rights and Darwin's write-once system
    // task-access policy endpoint. The latter is present in normal sandboxed
    // processes and the kernel forbids replacing it, even with a null port.
    if (mach_ports_register(mach_task_self(), NULL, 0) != KERN_SUCCESS
        || task_set_exception_ports(mach_task_self(), EXC_MASK_ALL, MACH_PORT_NULL,
            EXCEPTION_DEFAULT, THREAD_STATE_NONE) != KERN_SUCCESS) return 0;
    mach_port_t thread = mach_thread_self();
    kern_return_t cleared = thread_set_exception_ports(thread, EXC_MASK_ALL, MACH_PORT_NULL,
        EXCEPTION_DEFAULT, THREAD_STATE_NONE);
    mach_port_deallocate(mach_task_self(), thread);
    if (cleared != KERN_SUCCESS
        || task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, MACH_PORT_NULL) != KERN_SUCCESS
        || task_set_special_port(mach_task_self(), TASK_DEBUG_CONTROL_PORT, MACH_PORT_NULL) != KERN_SUCCESS) return 0;
    // libSystem caches the bootstrap send right independently of the task slot.
    if (MACH_PORT_VALID(bootstrap_port)
        && mach_port_deallocate(mach_task_self(), bootstrap_port) != KERN_SUCCESS) return 0;
    bootstrap_port = MACH_PORT_NULL;
    // Only the three standard streams survive; no writable directory or caller
    // environment is needed. The broker supplies /dev/null on stderr.
    for (int fd = 3, ceiling = getdtablesize(); fd < ceiling; ++fd) close(fd);
    static char *empty_environment[] = { "LANG=C", "LC_ALL=C", NULL };
    environ = empty_environment;
    if (chdir("/")) return 0;
    signal(SIGPIPE, SIG_IGN);
    signal(SIGXCPU, SIG_DFL);
    sigset_t signals;
    sigemptyset(&signals);
    if (sigprocmask(SIG_SETMASK, &signals, NULL)) return 0;
    for (int fd = 0; fd < 2; ++fd) {
        int flags = fcntl(fd, F_GETFL);
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK)) return 0;
    }
    ready->cpu_soft = (milliseconds + 999) / 1000;
    ready->cpu_hard = ready->cpu_soft + 1;
    ready->nofile = JORT_JS_NOFILE;
    return limit(RLIMIT_CPU, ready->cpu_soft, ready->cpu_hard) &&
        limit(RLIMIT_CORE, 0, 0) && limit(RLIMIT_FSIZE, 0, 0) &&
        limit(RLIMIT_NPROC, 0, 0) && limit(RLIMIT_NOFILE, JORT_JS_NOFILE, JORT_JS_NOFILE);
}

int main(int argc, char **argv) {
    uint32_t policy = 0, milliseconds = 0;
    if (argc != 3 || !numeric(argv[1], &policy) || policy != JORT_JS_POLICY_VERSION ||
        !numeric(argv[2], &milliseconds) || milliseconds < 10 || milliseconds > 30000) return 64;
    JortJSReady ready = { .status = JORT_JS_BOOTSTRAP };
    if (bootstrap(milliseconds, &ready)) ready.status = JORT_JS_OK;
    double deadline = jort_js_monotonic() + 3;
    if (jort_js_ready_write(STDOUT_FILENO, &ready, deadline) || ready.status != JORT_JS_OK) return 70;

    // The broker closes its request pipe immediately after its single complete
    // frame. Requiring EOF before evaluation rejects appended or second frames.
    JortJSFrame request;
    deadline = jort_js_monotonic() + milliseconds / 1000.0 + 3;
    if (jort_js_frame_read(STDIN_FILENO, &request, deadline)) return 65;
    if (request.kind != JORT_JS_REQUEST || request.deadline_ms != milliseconds ||
        jort_js_expect_eof(STDIN_FILENO, deadline)) {
        jort_js_frame_destroy(&request);
        return 65;
    }
    close(STDIN_FILENO);
    JortJSFrame response = { .kind = JORT_JS_RESPONSE };
    memcpy(response.generation, request.generation, 16);
    memcpy(response.nonce, request.nonce, sizeof(response.nonce));
    memcpy(response.invocation, request.invocation, sizeof(response.invocation));
    int status = JORT_JS_IMPLEMENTATION;
    char *result = NULL;
    if (request.tag == JORT_JS_VALIDATE) {
        result = jort_js_validate((const char *)request.fields[1]);
        status = result ? JORT_JS_IMPLEMENTATION : JORT_JS_OK;
        if (!result) result = strdup("");
    } else {
        JortJSCancellation *token = jort_js_cancellation_new();
        if (token) {
            result = jort_js_run_text((const char *)request.fields[1],
                request.fields[2] ? (const char *)request.fields[2] : "",
                request.fields[3] ? (const char *)request.fields[3] : "",
                request.fields[4] ? (const char *)request.fields[4] : "",
                request.tag == JORT_JS_VALIDATE_INPUT ? "validate" : "default",
                milliseconds / 1000.0, request.output_bytes, request.output_lines, token, &status);
            jort_js_cancellation_free(token);
        }
    }
    if (!result) { status = JORT_JS_INTERNAL; result = strdup("Unable to allocate JavaScript result."); }
    if (!result) { jort_js_frame_destroy(&request); return 71; }
    size_t length = strlen(result);
    if (!jort_js_utf8_valid((const uint8_t *)result, length) ||
        (status == JORT_JS_OK ? length > request.output_bytes : length > JORT_JS_ERROR_MAX)) {
        jort_js_clear(result, length); jort_js_free(result);
        status = JORT_JS_PROTOCOL; result = strdup("JavaScript returned an invalid result.");
        if (!result) { jort_js_frame_destroy(&request); return 71; }
        length = strlen(result);
    }
    response.tag = (uint32_t)status;
    unsigned field = status == JORT_JS_OK ? 0 : 1;
    response.fields[field] = (uint8_t *)result;
    response.lengths[field] = (uint32_t)length;
    jort_js_frame_destroy(&request);
    int written = jort_js_frame_write(STDOUT_FILENO, &response, deadline);
    jort_js_clear(result, length); jort_js_free(result);
    close(STDOUT_FILENO);
    return written == JORT_JS_IO_OK ? 0 : 74;
}
