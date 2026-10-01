/* Nonshipping broker fault injection. The production receive/supervise/timer/
 * spawn/reap implementations execute unchanged over real anonymous XPC and
 * real child pipes. Only worker selection and terminal observation are seams;
 * those anonymous-XPC modes make no sandbox or authentication claim. The
 * separate signed-interruption mode stages a real named XPC service and uses
 * the production client, peer requirements, worker verifier and worker. */
#include "BrokerEnvelope.h"
#include "BrokerIdentity.h"
#include <libproc.h>
#include <sys/resource.h>
#include <spawn.h>
#include <signal.h>
#include <sys/wait.h>

static int fixture_spawn(pid_t *, const char *, const posix_spawn_file_actions_t *,
    const posix_spawnattr_t *, char *const [], char *const []);
static int fixture_kill(pid_t, int);
static pid_t fixture_waitpid(pid_t, int *, int);

static bool fixture_worker_path(char *, size_t);
static xpc_object_t observe_reply(xpc_object_t, const JortJSFrame *);
#define jort_broker_verified_worker_path fixture_worker_path
#define jort_broker_create_reply observe_reply
#define posix_spawn fixture_spawn
#define kill fixture_kill
#define waitpid fixture_waitpid
#define main unused_broker_main
#include "../../../Sources/JortJavaScriptBroker/main.c"
#undef main
#undef jort_broker_create_reply
#undef jort_broker_verified_worker_path
#undef posix_spawn
#undef kill
#undef waitpid

/* The signed interruption fixture uses the production client without transport
 * seams: its named XPC connection and signature requirement remain unchanged. */
#include "../../../Sources/JortJavaScriptClient/JortJavaScriptClient.c"

static const char *mode, *worker_path;
static unsigned observed, statuses[32], received, invalid_replies;
static dispatch_semaphore_t terminal;
static unsigned invalid_pid_operations;

static int fixture_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
    const posix_spawnattr_t *attributes, char *const arguments[], char *const environment[]) {
    if (mode && (!strcmp(mode, "spawn-negative") || !strcmp(mode, "spawn-zero"))) {
        *pid = !strcmp(mode, "spawn-negative") ? -1 : 0;
        return EAGAIN;
    }
    return posix_spawn(pid, path, actions, attributes, arguments, environment);
}

// Trap unsafe operations in the fixture rather than ever signalling other
// user processes, even when this test runs against a regressed implementation.
static int fixture_kill(pid_t pid, int signal) {
    if (pid <= 0) { invalid_pid_operations++; errno = ESRCH; return -1; }
    return kill(pid, signal);
}

static pid_t fixture_waitpid(pid_t pid, int *status, int options) {
    if (pid <= 0) { invalid_pid_operations++; errno = ECHILD; return -1; }
    return waitpid(pid, status, options);
}

static bool invalid_pid_guards_hold(pid_t pid) {
    Run run = { .pid = pid, .cancelled = true };
    if (pthread_mutex_init(&run.lock, NULL)) return false;
    pthread_mutex_lock(&run.lock);
    terminate_locked(&run, JORT_JS_LAUNCH);
    pthread_mutex_unlock(&run.lock);
    bool verified = !run.terminated;
    // Even a stale termination marker cannot turn a sentinel into SIGKILL.
    run.terminated = true;
    watchdog(&run);
    (void)reap(&run, true, JORT_JS_LAUNCH);
    pthread_mutex_destroy(&run.lock);
    return verified && invalid_pid_operations == 0;
}

static bool fixture_worker_path(char *path, size_t capacity) {
    if (!strcmp(mode, "signed-service")) return jort_broker_verified_worker_path(path, capacity);
    if (!strcmp(mode, "identity")) return false;
    return snprintf(path, capacity, "%s", worker_path) < (int)capacity;
}

static xpc_object_t observe_reply(xpc_object_t request, const JortJSFrame *response) {
    if (!terminal) return jort_broker_create_reply(request, response);
    if (observed < 32) statuses[observed] = response->tag;
    observed++;
    const char *keys[] = {"nonce", "invocation", "generation"};
    const void *identities[] = {response->nonce, response->invocation, response->generation};
    for (unsigned i = 0; i < 3; i++) {
        size_t length = 0;
        const void *identity = xpc_dictionary_get_data(request, keys[i], &length);
        if (length != 16 || memcmp(identity, identities[i], 16)) invalid_replies++;
    }
    if (response->lengths[1] > JORT_JS_ERROR_MAX || (response->tag && response->lengths[0])) invalid_replies++;
    if (!response->tag && (response->lengths[0] != 14
        || memcmp(response->fields[0], "fixture-result", 14))) invalid_replies++;
    dispatch_semaphore_signal(terminal);
    return jort_broker_create_reply(request, response);
}

static void delay_ms(unsigned ms) { usleep(ms * 1000); }

static int child(const char *path, unsigned milliseconds) {
    const char *name = strrchr(path, '/'); name = name ? name + 1 : path;
    signal(SIGPIPE, SIG_IGN);
    /* Even a broken supervisor must not leave a permanent fixture process. */
    alarm(10);
    struct rlimit no_core = {0, 0}; setrlimit(RLIMIT_CORE, &no_core);
    if (!strcmp(name, "bootstrap")) { signal(SIGTERM, SIG_IGN); for (;;) pause(); }
    JortJSReady ready = {JORT_JS_OK, (milliseconds + 999) / 1000,
        (milliseconds + 999) / 1000 + 1, JORT_JS_NOFILE};
    double deadline = jort_js_monotonic() + 8;
    if (jort_js_ready_write(1, &ready, deadline)) return 70;
    if (!strcmp(name, "backpressure")) { signal(SIGTERM, SIG_IGN); for (;;) pause(); }
    JortJSFrame request = {0};
    if (jort_js_frame_read(0, &request, deadline)) return 71;
    if (!strcmp(name, "crash")) { raise(SIGKILL); return 72; }
    if (!strcmp(name, "hang") || !strcmp(name, "capacity") || !strcmp(name, "cancel")) {
        signal(SIGTERM, SIG_IGN); for (;;) pause();
    }
    if (!strcmp(name, "late")) delay_ms(milliseconds + 150);
    if (!strcmp(name, "race")) delay_ms(milliseconds);
    if (!strcmp(name, "cancel-race")) delay_ms(50);
    JortJSFrame response = {0};
    response.kind = JORT_JS_RESPONSE;
    memcpy(response.nonce, request.nonce, 16);
    memcpy(response.invocation, request.invocation, 16);
    memcpy(response.generation, request.generation, 16);
    uint8_t payload[] = "fixture-result";
    response.fields[0] = payload; response.lengths[0] = sizeof(payload) - 1;
    uint8_t header[JORT_JS_HEADER_SIZE];
    if (jort_js_header_encode(&response, header)) return 73;
    if (!strcmp(name, "truncated")) {
        (void)write(1, header, 7);
        jort_js_frame_destroy(&request);
        return 0;
    }
    if (!strcmp(name, "malformed")) header[0] ^= 1;
    if (!strcmp(name, "oversized")) { header[64] = 0x7f; header[65] = 0xff; }
    if (!strcmp(name, "partial")) {
        for (size_t i = 0; i < sizeof(header); i++) {
            if (write(1, header + i, 1) != 1) return 74;
            delay_ms(1);
        }
        for (size_t i = 0; i < response.lengths[0]; i++) {
            if (write(1, payload + i, 1) != 1) return 75;
        }
    } else {
        if (write(1, header, sizeof(header)) != sizeof(header)) return 76;
        if (write(1, payload, response.lengths[0]) != response.lengths[0]) return 77;
    }
    if (!strcmp(name, "second")) (void)jort_js_frame_write(1, &response, deadline);
    jort_js_frame_destroy(&request);
    return 0;
}

static xpc_object_t request(unsigned index, unsigned milliseconds) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    uint8_t identity[16] = {0}; identity[0] = (uint8_t)index;
    xpc_dictionary_set_uint64(message, "version", 1);
    xpc_dictionary_set_uint64(message, "operation", JORT_JS_EXECUTE);
    const char *ids[] = {"nonce", "invocation", "generation"};
    for (unsigned i = 0; i < 3; i++) xpc_dictionary_set_data(message, ids[i], identity, 16);
    xpc_dictionary_set_data(message, "contract", "{}", 2);
    xpc_dictionary_set_data(message, "source", "source", 6);
    xpc_dictionary_set_data(message, "input", "", 0);
    if (!strcmp(mode, "backpressure")) {
        char *large = malloc(JORT_JS_INPUT_MAX); memset(large, 'x', JORT_JS_INPUT_MAX);
        xpc_dictionary_set_data(message, "input", large, JORT_JS_INPUT_MAX); free(large);
    }
    xpc_dictionary_set_data(message, "clock", "", 0);
    xpc_dictionary_set_data(message, "uuid", "00000000-0000-0000-0000-000000000001", 36);
    xpc_dictionary_set_uint64(message, "deadlineMilliseconds", milliseconds);
    xpc_dictionary_set_uint64(message, "outputBytes", 1024);
    xpc_dictionary_set_uint64(message, "outputLines", 10);
    return message;
}

static int fd_count(void) {
    int bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes <= 0) return -1;
    struct proc_fdinfo *fds = malloc((size_t)bytes + 32 * sizeof(*fds));
    int actual = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, fds,
        bytes + (int)(32 * sizeof(*fds)));
    free(fds);
    return actual > 0 ? actual / (int)sizeof(struct proc_fdinfo) : -1;
}

static bool process_at_path(pid_t pid, const char *expected) {
    char actual[PROC_PIDPATHINFO_MAXSIZE];
    return pid > 0 && proc_pidpath(pid, actual, sizeof(actual)) > 0 && !strcmp(actual, expected);
}

static pid_t process_with_exact_path(const char *expected, pid_t parent) {
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes <= 0) return 0;
    pid_t *pids = calloc(1, (size_t)bytes + 32 * sizeof(pid_t));
    if (!pids) return 0;
    int actual = proc_listpids(PROC_ALL_PIDS, 0, pids, bytes + 32 * sizeof(pid_t));
    pid_t found = 0;
    for (int i = 0; i < actual / (int)sizeof(pid_t); i++) {
        if (!process_at_path(pids[i], expected)) continue;
        if (parent) {
            struct proc_bsdinfo info = {0};
            if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)
                || info.pbi_ppid != parent) continue;
        }
        found = pids[i];
        break;
    }
    free(pids);
    return found;
}

static bool process_gone(pid_t pid) {
    errno = 0;
    return kill(pid, 0) == -1 && errno == ESRCH;
}

typedef enum { SIGNED_SUCCESS, SIGNED_INTERRUPTION, SIGNED_WAIT_TIMEOUT } SignedRound;

static int signed_client_round(const char *broker_path, const char *worker_path, SignedRound round) {
    bool interrupt = round == SIGNED_INTERRUPTION;
    bool wait_timeout = round == SIGNED_WAIT_TIMEOUT;
    JortJSClient *client = jort_js_client_create();
    if (!client) return 90;
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block unsigned completions = 0;
    __block uint32_t status = UINT32_MAX;
    __block bool payload_valid = false;
    uint8_t identity[16] = {1};
    const char *source = interrupt || wait_timeout ? "export default async function() { for (;;) {} }"
        : "export default async function() { return {output: 'fixture-result'}; }";
    JortJSClientRequest request = {
        .operation = JORT_JS_EXECUTE, .nonce = identity, .invocation = identity, .generation = identity,
        .deadline_ms = interrupt || wait_timeout ? 10000 : 2000, .output_bytes = 1024, .output_lines = 10,
        .contract = (const uint8_t *)"{}", .contract_length = 2,
        .source = (const uint8_t *)source, .source_length = strlen(source),
        .uuid = (const uint8_t *)"00000000-0000-0000-0000-000000000001", .uuid_length = 36
    };
    jort_js_client_send(client, &request, ^(uint32_t result, const uint8_t *output,
        size_t output_length, const uint8_t *error, size_t error_length) {
        completions++;
        status = result;
        payload_valid = interrupt || wait_timeout ? !output_length && error && error_length > 0
            && error_length <= JORT_JS_ERROR_MAX : output_length == 14 && output
            && !memcmp(output, "fixture-result", 14) && !error_length;
        dispatch_semaphore_signal(completed);
    });
    int failure = 0;
    pid_t worker = 0;
    if (interrupt) {
        /* The serial client queue owns its connection. Only inspect the PID
         * while that connection is live, then confirm both executable paths
         * before signalling the disposable broker. No name-based process kill. */
        double until = jort_js_monotonic() + 5;
        __block pid_t broker = 0;
        while (!worker && jort_js_monotonic() < until) {
            dispatch_sync(client->queue, ^{
                broker = client->connection ? xpc_connection_get_pid(client->connection) : 0;
            });
            if (!process_at_path(broker, broker_path))
                broker = process_with_exact_path(broker_path, 0);
            if (process_at_path(broker, broker_path)) {
                pid_t children[8] = {0};
                int bytes = proc_listchildpids(broker, children, sizeof(children));
                for (int i = 0; i < bytes / (int)sizeof(pid_t); i++) {
                    if (process_at_path(children[i], worker_path)) worker = children[i];
                }
                if (!worker) worker = process_with_exact_path(worker_path, broker);
            }
            if (!worker) delay_ms(5);
        }
        if (!worker || !process_at_path(broker, broker_path)) failure = 91;
        else if (kill(broker, SIGKILL)) failure = 92;
    }
    // Exercise the controller-timeout cleanup deterministically, while the
    // client's real asynchronous request is still pending.
    long waited = dispatch_semaphore_wait(completed,
        wait_timeout ? DISPATCH_TIME_NOW : dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC));
    if (wait_timeout ? !waited : waited != 0) failure = 93;
    if (worker) {
        /* A killed broker cannot waitpid its worker. The production worker's
         * own bounded deadline/CPU policy must still let launchd reap it. */
        double until = jort_js_monotonic() + 5;
        while (!process_gone(worker) && jort_js_monotonic() < until) delay_ms(10);
        if (!process_gone(worker)) failure = 94;
    }
    delay_ms(200); /* Drain both the XPC error event and reply callback. */
    // A timeout does not prove completion stopped. Cancel on the state queue
    // before inspecting captured values or releasing their semaphore; after
    // this barrier, later XPC/timer events cannot invoke completion again.
    jort_js_client_cancel(client);
    dispatch_sync(client->queue, ^{});
    uint32_t expected = wait_timeout ? JORT_JS_CANCELLED : interrupt ? JORT_JS_UNAVAILABLE : JORT_JS_OK;
    if (completions != 1 || status != expected || !payload_valid) {
        fprintf(stderr, "interruption=%d completions=%u status=%u expected=%u payload=%d\n",
            interrupt, completions, status, expected, payload_valid);
        if (!failure) failure = 95;
    }
    jort_js_client_release(client);
    dispatch_release(completed);
    return failure;
}

static int signed_interruption(const char *broker_path, const char *worker_path) {
    int result = signed_client_round(broker_path, worker_path, SIGNED_SUCCESS);
    delay_ms(100);
    int before = fd_count();
    if (!result) result = signed_client_round(broker_path, worker_path, SIGNED_INTERRUPTION);
    if (!result) result = signed_client_round(broker_path, worker_path, SIGNED_WAIT_TIMEOUT);
    delay_ms(100);
    int after = fd_count();
    if (!result && (before < 0 || before != after)) result = 96;
    fprintf(stdout, "signed broker interruption result=%d descriptors=%d/%d\n", result, before, after);
    return result;
}

static int round_trip(xpc_endpoint_t endpoint, unsigned count, unsigned milliseconds, unsigned round) {
    xpc_connection_t clients[5] = {0};
    dispatch_sync(events, ^{ observed = received = invalid_replies = 0; memset(statuses, 0, sizeof(statuses)); });
    for (unsigned i = 0; i < count; i++) {
        clients[i] = xpc_connection_create_from_endpoint(endpoint);
        xpc_connection_set_target_queue(clients[i], events);
        xpc_connection_set_event_handler(clients[i], ^(xpc_object_t event) { (void)event; });
        xpc_connection_resume(clients[i]);
        xpc_object_t message = request(round * 5 + i, milliseconds);
        xpc_connection_send_message_with_reply(clients[i], message, events, ^(xpc_object_t reply) {
            if (xpc_get_type(reply) == XPC_TYPE_DICTIONARY)
                dispatch_async(events, ^{ received++; });
        });
        xpc_release(message);
    }
    bool cancelling = !strcmp(mode, "cancel") || !strcmp(mode, "cancel-race");
    if (cancelling) {
        /* Wait until receive has actually admitted a child before invalidation. */
        double until = jort_js_monotonic() + 2;
        int children = 0;
        do {
            pid_t pids[8];
            children = proc_listchildpids(getpid(), pids, sizeof(pids));
            delay_ms(5);
        } while (children <= 0 && jort_js_monotonic() < until);
        if (children <= 0) return 80;
        if (!strcmp(mode, "cancel-race")) delay_ms(50);
        xpc_connection_cancel(clients[0]);
    }
    for (unsigned i = 0; i < count; i++) {
        if (dispatch_semaphore_wait(terminal, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC))) return 81;
    }
    delay_ms(150); /* Include timer cancellation, late pipe and XPC events. */
    __block int failure = 0;
    dispatch_sync(events, ^{
        if (active || observed != count || invalid_replies) failure = 82;
        unsigned busy = 0;
        for (unsigned i = 0; i < observed; i++) {
            uint32_t expected = JORT_JS_OK;
            if (!strcmp(mode, "identity")) expected = JORT_JS_IDENTITY;
            else if (!strcmp(mode, "launch") || !strcmp(mode, "spawn-negative")
                || !strcmp(mode, "spawn-zero")) expected = JORT_JS_LAUNCH;
            else if (!strcmp(mode, "crash")) expected = JORT_JS_CRASH;
            else if (!strcmp(mode, "cancel")) expected = JORT_JS_CANCELLED;
            else if (!strcmp(mode, "second") || !strcmp(mode, "truncated")
                || !strcmp(mode, "malformed") || !strcmp(mode, "oversized")) expected = JORT_JS_PROTOCOL;
            else if (!strcmp(mode, "hang") || !strcmp(mode, "bootstrap") || !strcmp(mode, "late")
                || !strcmp(mode, "backpressure") || !strcmp(mode, "capacity")) expected = JORT_JS_TIMEOUT;
            if (!strcmp(mode, "capacity") && statuses[i] == JORT_JS_BUSY) { busy++; continue; }
            if (!strcmp(mode, "race") && (statuses[i] == JORT_JS_OK || statuses[i] == JORT_JS_TIMEOUT)) continue;
            if (!strcmp(mode, "cancel-race") && (statuses[i] == JORT_JS_OK || statuses[i] == JORT_JS_CANCELLED)) continue;
            if (statuses[i] != expected) { fprintf(stderr, "status=%u expected=%u\n", statuses[i], expected); failure = 83; }
        }
        if (!strcmp(mode, "capacity") && busy != 1) failure = 84;
        if (!cancelling && received != count) failure = 85;
    });
    for (unsigned i = 0; i < count; i++) { xpc_connection_cancel(clients[i]); xpc_release(clients[i]); }
    delay_ms(50);
    int status; errno = 0;
    if (waitpid(-1, &status, WNOHANG) != -1 || errno != ECHILD || invalid_pid_operations) return 86;
    return failure;
}

int main(int argc, char **argv) {
    if (argc == 1) {
        mode = "signed-service";
        return unused_broker_main();
    }
    if (argc == 4 && !strcmp(argv[1], "signed-interruption"))
        return signed_interruption(argv[2], argv[3]);
    /* This mode calls the linked production identity implementation. It must
     * execute from the shipping XPC bundle topology; the XCTest fixture stages
     * and signs that topology before invoking us. */
    if (argc == 2 && !strcmp(argv[1], "identity-verify")) {
        char verified[PATH_MAX];
        return jort_broker_verified_worker_path(verified, sizeof(verified)) ? 0 : 88;
    }
    if (argc == 3 && argv[1][0] == '1' && argv[1][1] == '\0') return child(argv[0], (unsigned)atoi(argv[2]));
    if (argc != 3) return 64;
    mode = argv[1]; worker_path = argv[2];
    if ((!strcmp(mode, "spawn-negative") || !strcmp(mode, "spawn-zero"))
        && !invalid_pid_guards_hold(!strcmp(mode, "spawn-negative") ? -1 : 0)) return 89;
    signal(SIGPIPE, SIG_IGN);
    events = dispatch_queue_create("dev.jort.broker.fault-fixture", DISPATCH_QUEUE_SERIAL);
    terminal = dispatch_semaphore_create(0);
    xpc_connection_t listener = xpc_connection_create(NULL, events);
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        __block bool used = false;
        xpc_connection_set_target_queue(peer, events);
        xpc_connection_set_event_handler(peer, ^(xpc_object_t message) { receive(peer, message, &used); });
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(listener);
    xpc_endpoint_t endpoint = xpc_endpoint_create(listener);
    unsigned count = !strcmp(mode, "capacity") ? 5 : 1;
    unsigned milliseconds = !strcmp(mode, "partial") || !strcmp(mode, "cancel")
        || !strcmp(mode, "cancel-race") || !strcmp(mode, "capacity") ? 2000 : 300;
    int result = round_trip(endpoint, count, milliseconds, 0);
    int before = fd_count();
    for (unsigned round = 1; !result && round < 4; round++) result = round_trip(endpoint, count, milliseconds, round);
    int after = fd_count();
    if (!result && (before < 0 || before != after)) {
        fprintf(stderr, "descriptor count before=%d after=%d\n", before, after); result = 87;
    }
    printf("mode=%s result=%d descriptors=%d/%d\n", mode, result, before, after);
    /* The anonymous listener is a fixture-only, process-lifetime endpoint.
     * Releasing it while its XPC event handlers are still draining can trap
     * after all broker assertions have passed. Request-owned resources were
     * checked above; process exit closes the listener itself. */
    fflush(stdout);
    _exit(result);
}
