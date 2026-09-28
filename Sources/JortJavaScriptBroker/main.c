#include "BrokerEnvelope.h"
#include "BrokerIdentity.h"

#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

/* One serial queue owns admission, connection cancellation and terminal replies.
 * Only the supervisor reaps. Every signal and WNOHANG wait holds the PID lock,
 * so no event can signal a PID after waitpid has released process ownership. */
typedef struct {
    pthread_mutex_t lock;
    pid_t pid;
    bool cancelled;
    bool terminal;
    bool terminated;
    uint32_t forced_status;
    double deadline;
    double kill_at;
    xpc_connection_t connection;
    xpc_object_t message;
    dispatch_source_t watchdog;
    JortJSFrame request;
    JortJSFrame response;
} Run;

static dispatch_queue_t events;
static unsigned active;

static void initialize_response(Run *run, uint32_t status) {
    jort_js_frame_destroy(&run->response);
    run->response.kind = JORT_JS_RESPONSE;
    run->response.tag = status;
    memcpy(run->response.nonce, run->request.nonce, 16);
    memcpy(run->response.invocation, run->request.invocation, 16);
    memcpy(run->response.generation, run->request.generation, 16);
}

static void terminate_locked(Run *run, uint32_t status) {
    if (run->terminal || !run->pid || run->terminated) return;
    run->forced_status = status;
    run->terminated = true;
    run->kill_at = jort_js_monotonic() + 0.1;
    (void)kill(run->pid, SIGTERM);
}

static void watchdog(Run *run) {
    pthread_mutex_lock(&run->lock);
    if (!run->terminal) {
        double now = jort_js_monotonic();
        if (run->cancelled) terminate_locked(run, JORT_JS_CANCELLED);
        else if (now >= run->deadline) terminate_locked(run, JORT_JS_TIMEOUT);
        if (run->pid && run->terminated && now >= run->kill_at) (void)kill(run->pid, SIGKILL);
    }
    pthread_mutex_unlock(&run->lock);
}

static void close_fd(int *fd) {
    if (*fd >= 0) { close(*fd); *fd = -1; }
}

static bool spawn_worker(Run *run, const char *path, int *input, int *output) {
    int in[2] = {-1, -1}, out[2] = {-1, -1};
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    bool actions_ready = false, attributes_ready = false, ok = false;
    if (pipe(in) != 0 || pipe(out) != 0) goto done;
    for (size_t i = 0; i < 2; i++) {
        if (fcntl(in[i], F_SETFD, FD_CLOEXEC) < 0 || fcntl(out[i], F_SETFD, FD_CLOEXEC) < 0) goto done;
    }
    if (posix_spawn_file_actions_init(&actions) != 0) goto done;
    actions_ready = true;
    if (posix_spawnattr_init(&attributes) != 0) goto done;
    attributes_ready = true;
    if (posix_spawn_file_actions_adddup2(&actions, in[0], STDIN_FILENO) != 0
        || posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO) != 0
        || posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) != 0
        || posix_spawn_file_actions_addchdir_np(&actions, "/") != 0
        || posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT) != 0) goto done;
    char deadline[16], policy[16], sandbox_container[PATH_MAX];
    snprintf(deadline, sizeof(deadline), "%u", run->request.deadline_ms);
    snprintf(policy, sizeof(policy), "%u", JORT_JS_POLICY_VERSION);
    char *argv[] = {(char *)path, policy, deadline, NULL};
    char *environment[] = {"LANG=C", "LC_ALL=C", NULL, NULL};
    const char *container = getenv("APP_SANDBOX_CONTAINER_ID");
    if (container) {
        int length = snprintf(sandbox_container, sizeof(sandbox_container),
            "APP_SANDBOX_CONTAINER_ID=%s", container);
        if (length <= 0 || (size_t)length >= sizeof(sandbox_container)) goto done;
        environment[2] = sandbox_container;
    }
    pthread_mutex_lock(&run->lock);
    if (!run->cancelled) ok = posix_spawn(&run->pid, path, &actions, &attributes, argv, environment) == 0;
    pthread_mutex_unlock(&run->lock);
    if (ok) {
        *input = in[1]; in[1] = -1;
        *output = out[0]; out[0] = -1;
        if (fcntl(*input, F_SETFL, O_NONBLOCK) < 0 || fcntl(*output, F_SETFL, O_NONBLOCK) < 0) ok = false;
    }
done:
    if (actions_ready) posix_spawn_file_actions_destroy(&actions);
    if (attributes_ready) posix_spawnattr_destroy(&attributes);
    close_fd(&in[0]); close_fd(&in[1]); close_fd(&out[0]); close_fd(&out[1]);
    return ok;
}

static int reap(Run *run, bool terminate, uint32_t failure) {
    int status = 0;
    /* A child that closes its output while crashing can reach EOF before its
     * exit becomes observable to waitpid. Give that natural exit a short chance
     * to be reaped before a protocol termination masks the crash status. */
    double crash_grace = jort_js_monotonic() + 0.05;
    for (;;) {
        pthread_mutex_lock(&run->lock);
        if (!run->pid) { pthread_mutex_unlock(&run->lock); return status; }
        pid_t result = waitpid(run->pid, &status, WNOHANG);
        if (result == run->pid) {
            run->pid = 0;
            pthread_mutex_unlock(&run->lock);
            return status;
        }
        if (result < 0 && errno != EINTR) {
            run->pid = 0;
            run->forced_status = JORT_JS_INTERNAL;
            pthread_mutex_unlock(&run->lock);
            return -1;
        }
        if (terminate && (failure != JORT_JS_PROTOCOL || jort_js_monotonic() >= crash_grace))
            terminate_locked(run, failure);
        pthread_mutex_unlock(&run->lock);
        watchdog(run);
        usleep(10000);
    }
}

static void supervise(Run *run) {
    int input = -1, output = -1;
    uint32_t status = JORT_JS_IDENTITY;
    bool complete = false;
    char path[PATH_MAX];
    if (!jort_broker_verified_worker_path(path, sizeof(path))) goto finish;
    status = JORT_JS_LAUNCH;
    if (!spawn_worker(run, path, &input, &output)) goto finish;
    status = JORT_JS_BOOTSTRAP;
    JortJSReady ready;
    int ready_result = jort_js_ready_read(output, &ready, run->deadline);
    if (ready_result != JORT_JS_IO_OK) {
        if (ready_result == JORT_JS_IO_TIMEOUT) status = JORT_JS_TIMEOUT;
        goto finish;
    }
    uint32_t cpu = (run->request.deadline_ms + 999) / 1000;
    if (ready.status != JORT_JS_OK || ready.cpu_soft != cpu || ready.cpu_hard != cpu + 1 || ready.nofile != JORT_JS_NOFILE) goto finish;
    pthread_mutex_lock(&run->lock);
    if (run->cancelled || run->terminated) {
        pthread_mutex_unlock(&run->lock);
        status = JORT_JS_CANCELLED;
        goto finish;
    }
    run->deadline = jort_js_monotonic() + ((double)run->request.deadline_ms / 1000.0);
    double execution_deadline = run->deadline;
    pthread_mutex_unlock(&run->lock);
    status = JORT_JS_PROTOCOL;
    int result = jort_js_frame_write(input, &run->request, execution_deadline);
    close_fd(&input);
    if (result != JORT_JS_IO_OK) { if (result == JORT_JS_IO_TIMEOUT) status = JORT_JS_TIMEOUT; goto finish; }
    result = jort_js_frame_read(output, &run->response, execution_deadline);
    if (result != JORT_JS_IO_OK) { if (result == JORT_JS_IO_TIMEOUT) status = JORT_JS_TIMEOUT; goto finish; }
    if (run->response.kind != JORT_JS_RESPONSE || memcmp(run->response.nonce, run->request.nonce, 16)
        || memcmp(run->response.invocation, run->request.invocation, 16)
        || memcmp(run->response.generation, run->request.generation, 16)
        || run->response.lengths[0] > run->request.output_bytes) goto finish;
    if (!jort_js_lines_valid(run->response.fields[0], run->response.lengths[0], run->request.output_lines)) {
        status = JORT_JS_OUTPUT_LIMIT; goto finish;
    }
    result = jort_js_expect_eof(output, execution_deadline);
    if (result != JORT_JS_IO_OK) { if (result == JORT_JS_IO_TIMEOUT) status = JORT_JS_TIMEOUT; goto finish; }
    complete = true;
finish:
    close_fd(&input); close_fd(&output);
    int child_status = reap(run, !complete, status);
    pthread_mutex_lock(&run->lock);
    if (run->cancelled) { status = JORT_JS_CANCELLED; complete = false; }
    else if (run->forced_status) { status = run->forced_status; complete = false; }
    else if (WIFSIGNALED(child_status)) {
        status = WTERMSIG(child_status) == SIGXCPU ? JORT_JS_CPU_LIMIT : JORT_JS_CRASH;
        complete = false;
    } else if (complete && (!WIFEXITED(child_status) || WEXITSTATUS(child_status) != 0)) {
        status = JORT_JS_CRASH; complete = false;
    }
    run->terminal = true;
    pthread_mutex_unlock(&run->lock);
    if (!complete) initialize_response(run, status);
    dispatch_async(events, ^{
        xpc_object_t reply = jort_broker_create_reply(run->message, &run->response);
        if (reply) { xpc_connection_send_message(run->connection, reply); xpc_release(reply); }
        active--;
        xpc_connection_set_context(run->connection, NULL);
        dispatch_source_cancel(run->watchdog);
    });
}

static void send_failure(xpc_connection_t connection, xpc_object_t message, JortJSFrame *request, uint32_t status) {
    JortJSFrame response = {0};
    response.kind = JORT_JS_RESPONSE; response.tag = status;
    memcpy(response.nonce, request->nonce, 16);
    memcpy(response.invocation, request->invocation, 16);
    memcpy(response.generation, request->generation, 16);
    xpc_object_t reply = jort_broker_create_reply(message, &response);
    if (reply) { xpc_connection_send_message(connection, reply); xpc_release(reply); }
}

static void receive(xpc_connection_t connection, xpc_object_t message, bool *used) {
    if (xpc_get_type(message) == XPC_TYPE_ERROR) {
        Run *run = xpc_connection_get_context(connection);
        if (run) {
            pthread_mutex_lock(&run->lock); run->cancelled = true; pthread_mutex_unlock(&run->lock);
            watchdog(run);
        }
        return;
    }
    JortJSFrame request = {0};
    if (*used || !jort_broker_decode_request(message, &request)
        || jort_js_frame_validate(&request) != JORT_JS_IO_OK) {
        jort_js_frame_destroy(&request);
        xpc_connection_cancel(connection);
        return;
    }
    *used = true;
    if (active >= JORT_JS_CONCURRENCY) {
        send_failure(connection, message, &request, JORT_JS_BUSY);
        jort_js_frame_destroy(&request);
        return;
    }
    Run *run = calloc(1, sizeof(*run));
    if (!run) {
        send_failure(connection, message, &request, JORT_JS_INTERNAL);
        jort_js_frame_destroy(&request);
        return;
    }
    pthread_mutex_init(&run->lock, NULL);
    run->request = request;
    run->connection = xpc_retain(connection);
    run->message = xpc_retain(message);
    run->deadline = jort_js_monotonic() + 3.0;
    run->watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, events);
    dispatch_source_set_timer(run->watchdog, DISPATCH_TIME_NOW, 10000000, 1000000);
    dispatch_source_set_event_handler(run->watchdog, ^{ watchdog(run); });
    dispatch_source_set_cancel_handler(run->watchdog, ^{
        jort_js_frame_destroy(&run->request);
        jort_js_frame_destroy(&run->response);
        xpc_release(run->message); xpc_release(run->connection);
        dispatch_release(run->watchdog);
        pthread_mutex_destroy(&run->lock);
        free(run);
    });
    xpc_connection_set_context(connection, run);
    active++;
    dispatch_resume(run->watchdog);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ supervise(run); });
}

static void accept_connection(xpc_connection_t connection) {
        char requirement[4096];
        if (!jort_broker_copy_app_requirement(requirement, sizeof(requirement))
            || xpc_connection_set_peer_code_signing_requirement(connection, requirement) != 0) {
            xpc_connection_cancel(connection);
            return;
        }
        __block bool used = false;
        xpc_connection_set_target_queue(connection, events);
        xpc_connection_set_event_handler(connection, ^(xpc_object_t message) { receive(connection, message, &used); });
        xpc_connection_resume(connection);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    events = dispatch_queue_create("dev.jort.javascript.broker.events", DISPATCH_QUEUE_SERIAL);
    xpc_main(accept_connection);
}
