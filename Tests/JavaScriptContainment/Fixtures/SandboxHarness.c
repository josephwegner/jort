/* Nonshipping sandboxed parent: exercise the shipping broker's launch, owned
 * PID supervision and reaping code against an inherit-only native fixture. */
#define main jort_unused_broker_main
#include "../../../Sources/JortJavaScriptBroker/main.c"
#undef main

#include <sys/resource.h>

static bool allocation_request(const char *path, bool exhaust) {
    // Both requests use the same program. Only the requested allocation changes:
    // 32 MiB must exceed the shipping 16 MiB heap; 1 MiB must remain usable.
    static const char source[] = "export default async function(input) {"
        " const block = 'x'.repeat(Number(input.content));"
        " return {output: String(block.length)}; }";
    const char *amount = exhaust ? "33554432" : "1048576";
    Run run = {0};
    if (pthread_mutex_init(&run.lock, NULL)) return false;
    run.request.kind = JORT_JS_REQUEST;
    run.request.tag = JORT_JS_EXECUTE;
    run.request.deadline_ms = 2000;
    run.request.output_bytes = 64;
    run.request.output_lines = 1;
    memset(run.request.nonce, exhaust ? 1 : 2, sizeof(run.request.nonce));
    memset(run.request.invocation, exhaust ? 3 : 4, sizeof(run.request.invocation));
    memset(run.request.generation, exhaust ? 5 : 6, sizeof(run.request.generation));
    run.request.fields[0] = (uint8_t *)"{}";
    run.request.lengths[0] = 2;
    run.request.fields[1] = (uint8_t *)source;
    run.request.lengths[1] = sizeof(source) - 1;
    run.request.fields[2] = (uint8_t *)amount;
    run.request.lengths[2] = (uint32_t)strlen(amount);
    run.deadline = jort_js_monotonic() + 3;
    int input = -1, output = -1;
    bool verified = false;
    pid_t owned_pid = 0;
    unsigned stage = 1;
    if (!spawn_worker(&run, path, &input, &output)) goto finish;
    owned_pid = run.pid;
    stage = 2;
    JortJSReady ready = {0};
    if (jort_js_ready_read(output, &ready, run.deadline) != JORT_JS_IO_OK
        || ready.status != JORT_JS_OK || ready.cpu_soft != 2 || ready.cpu_hard != 3
        || ready.nofile != JORT_JS_NOFILE) goto finish;
    run.deadline = jort_js_monotonic() + 2;
    stage = 3;
    if (jort_js_frame_write(input, &run.request, run.deadline) != JORT_JS_IO_OK) goto finish;
    close_fd(&input);
    stage = 4;
    if (jort_js_frame_read(output, &run.response, run.deadline) != JORT_JS_IO_OK) goto finish;
    stage = 5;
    if (run.response.kind != JORT_JS_RESPONSE
        || memcmp(run.response.nonce, run.request.nonce, 16)
        || memcmp(run.response.invocation, run.request.invocation, 16)
        || memcmp(run.response.generation, run.request.generation, 16)
        || jort_js_expect_eof(output, run.deadline) != JORT_JS_IO_OK) goto finish;
    if (exhaust) {
        // The current shim reports bounded implementation/resource failures.
        // Do not accept timeout, crash, bootstrap, protocol, or partial output.
        verified = (run.response.tag == JORT_JS_IMPLEMENTATION || run.response.tag == JORT_JS_ENGINE_LIMIT)
            && run.response.lengths[0] == 0 && run.response.lengths[1] > 0
            && run.response.lengths[1] <= JORT_JS_ERROR_MAX;
    } else {
        verified = run.response.tag == JORT_JS_OK && run.response.lengths[1] == 0
            && run.response.lengths[0] == strlen(amount)
            && !memcmp(run.response.fields[0], amount, strlen(amount));
    }
finish:
    close_fd(&input);
    close_fd(&output);
    int status = reap(&run, !verified, JORT_JS_PROTOCOL);
    verified = verified && !run.forced_status && !run.pid
        && WIFEXITED(status) && WEXITSTATUS(status) == 0;
    if (verified) {
        int again = 0;
        errno = 0;
        verified = waitpid(owned_pid, &again, WNOHANG) == -1 && errno == ECHILD;
    }
    if (!verified) fprintf(stderr, "Heap probe exhaust=%d stage=%u reply=%u forced=%u wait=%d\n",
        exhaust, stage, run.response.tag, run.forced_status, status);
    jort_js_frame_destroy(&run.response);
    pthread_mutex_destroy(&run.lock);
    return verified;
}

/* Hold the real worker immediately after its production Ready handshake.  The
 * XCTest parent can inspect that exact child before closing our stdin, which
 * asks this harness to terminate and reap it.  No request frame (and therefore
 * no source) is ever sent to the worker. */
static bool runtime_mapping_request(const char *path) {
    Run run = {0};
    if (pthread_mutex_init(&run.lock, NULL)) return false;
    run.request.deadline_ms = 1000;
    run.deadline = jort_js_monotonic() + 3;
    int input = -1, output = -1;
    pid_t owned_pid = 0;
    bool verified = false;
    if (!spawn_worker(&run, path, &input, &output)) goto finish;
    owned_pid = run.pid;
    JortJSReady ready = {0};
    if (jort_js_ready_read(output, &ready, run.deadline) != JORT_JS_IO_OK
        || ready.status != JORT_JS_OK || ready.cpu_soft != 1 || ready.cpu_hard != 2
        || ready.nofile != JORT_JS_NOFILE) goto finish;
    // stdout is the XCTest control channel; the worker protocol remains on its
    // private pipe and stays blocked before source is received.
    if (printf("READY %d\\n", owned_pid) < 0 || fflush(stdout)) goto finish;
    char stop = 0;
    while (read(STDIN_FILENO, &stop, 1) < 0 && errno == EINTR) {}
    verified = true;
finish:
    /* Keep the worker's protocol stdin open until supervision sends SIGTERM.
     * Closing it first races with the worker's expected EOF exit (65), which
     * tests pipe closure rather than the broker-owned kill-and-reap path. */
    int status = reap(&run, true, JORT_JS_CANCELLED);
    close_fd(&input);
    close_fd(&output);
    if (verified) {
        int again = 0;
        errno = 0;
        verified = !run.pid && run.forced_status == JORT_JS_CANCELLED && WIFSIGNALED(status)
            && WTERMSIG(status) == SIGTERM
            && waitpid(owned_pid, &again, WNOHANG) == -1 && errno == ECHILD;
    }
    if (!verified) fprintf(stderr, "Runtime mapping probe ready/reap failed pid=%d forced=%u wait=%d\\n",
        owned_pid, run.forced_status, status);
    else puts("REAPED");
    pthread_mutex_destroy(&run.lock);
    return verified;
}

int main(int argc, char **argv) {
    if (argc != 4 || (strcmp(argv[1], "sandbox") && strcmp(argv[1], "cpu")
        && strcmp(argv[1], "heap") && strcmp(argv[1], "mapping") && strcmp(argv[1], "device"))) return 64;
    if (!strcmp(argv[1], "mapping")) {
        if (!runtime_mapping_request(argv[2])) return 78;
        return 0;
    }
    if (!strcmp(argv[1], "heap")) {
        if (!allocation_request(argv[2], true) || !allocation_request(argv[2], false)) return 77;
        puts("Heap allocation failed safely; fresh production worker succeeded; both children reaped");
        return 0;
    }
    bool cpu = !strcmp(argv[1], "cpu");
    bool device = !strcmp(argv[1], "device");
    Run run = {0};
    if (pthread_mutex_init(&run.lock, NULL)) return 70;
    run.request.deadline_ms = cpu ? 1000 : (device ? 11 : 10);
    // For the CPU probe only, allow the kernel CPU signal to act before the
    // fallback wall supervisor. Normal production wall supervision fires first.
    run.deadline = jort_js_monotonic() + 8;
    struct rusage before = {0}, after = {0};
    if (cpu && getrusage(RUSAGE_CHILDREN, &before)) return 70;
    int input = -1, output = -1;
    if (!spawn_worker(&run, argv[2], &input, &output)) return 71;
    pid_t owned_pid = run.pid;
    bool verified = false;
    if (cpu) {
        JortJSReady ready = {0};
        verified = jort_js_ready_read(output, &ready, jort_js_monotonic() + 3) == JORT_JS_IO_OK
            && ready.status == JORT_JS_OK && ready.cpu_soft == 1 && ready.cpu_hard == 2
            && ready.nofile == JORT_JS_NOFILE;
    } else {
        size_t length = strlen(argv[3]);
        verified = length < PATH_MAX && write(input, argv[3], length) == (ssize_t)length;
    }
    close_fd(&input);
    char result[256] = {0};
    if (!cpu && verified) {
        size_t used = 0;
        for (;;) {
            ssize_t count = read(output, result + used, sizeof(result) - 1 - used);
            if (count > 0) {
                used += (size_t)count;
                if (used == sizeof(result) - 1) { verified = false; break; }
            } else if (!count) break;
            else if (errno != EAGAIN && errno != EINTR) { verified = false; break; }
            if (jort_js_monotonic() >= run.deadline) { verified = false; break; }
            usleep(1000);
        }
    }
    close_fd(&output);
    int status = reap(&run, !verified, JORT_JS_PROTOCOL);
    if (run.forced_status || run.pid || !verified) {
        fprintf(stderr, "Native probe verified=%d forced_status=%u wait_status=%d owned_pid=%d\n",
            verified, run.forced_status, status, run.pid);
        return 72;
    }
    if (cpu) {
        if (!WIFSIGNALED(status) || WTERMSIG(status) != SIGXCPU
            || getrusage(RUSAGE_CHILDREN, &after)) return 73;
        double cpu_seconds = after.ru_utime.tv_sec - before.ru_utime.tv_sec
            + after.ru_stime.tv_sec - before.ru_stime.tv_sec
            + (after.ru_utime.tv_usec - before.ru_utime.tv_usec
                + after.ru_stime.tv_usec - before.ru_stime.tv_usec) / 1000000.0;
        // CPU time is the measured resource, not wall time under host load.
        if (cpu_seconds > 2.0) {
            fprintf(stderr, "Native probe exceeded CPU hard deadline: %.3f seconds\n", cpu_seconds);
            return 76;
        }
    } else if (!WIFEXITED(status) || WEXITSTATUS(status)
        || strcmp(result, device ? "DENIED protected-device open-close\n"
            : "DENIED file-read file-write network-client network-server keychain subprocess\n")) {
        fprintf(stderr, "Native sandbox probe exit=%d result=%s\n", WIFEXITED(status) ? WEXITSTATUS(status) : -1, result);
        return 74;
    }
    int again = 0;
    errno = 0;
    if (waitpid(owned_pid, &again, WNOHANG) != -1 || errno != ECHILD) return 75;
    pthread_mutex_destroy(&run.lock);
    puts(cpu ? "CPU limit SIGXCPU; broker reap confirmed" : result);
    return 0;
}
