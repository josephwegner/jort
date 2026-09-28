# Nonshipping native containment probes

`SandboxHarness.c` is a signed App Sandbox parent with the broker's exact
one-key sandbox policy. It includes the production broker implementation to
exercise its pipe setup, `posix_spawn`, owned PID supervision, and `waitpid`
reaping. It does not run an XPC listener or test peer authentication.

`NativeProbe.c` is an inherit-only signed child with the production worker
entitlements. It includes the production worker implementation to use the exact
resource bootstrap. Neither fixture introduces a production test switch or
native JavaScript API. Neither executable is embedded in Jort.app.

The XCTest wrapper signs disposable copies with exact entitlements, avoiding
test-action `get-task-allow` injection. It creates a harmless known-existing
file outside the sandbox container and requires `EPERM`/`EACCES` for read,
write, network connect, and network bind. File and network checks precede
resource-limit setup so missing resources, connection refusal, and resource
quotas cannot masquerade as sandbox denials. After bootstrap, subprocess
creation must fail with a permission error or the installed process quota.

The CPU fixture installs the production 1-second soft / 2-second hard CPU
policy, retains the production default `SIGXCPU` disposition, and executes a
native tight loop. The test supervisor permits eight wall seconds so the kernel
CPU signal acts first, then requires `SIGXCPU`, cumulative child CPU usage at
most two seconds, no forced supervisor termination, and `ECHILD` after the
production broker's reap. Darwin does not guarantee a subsequent `SIGKILL`
when `SIGXCPU` is ignored. The shipping wall timeout remains unchanged.

The heap fixture launches disposable, exactly entitled copies of the actual
production `JortJavaScriptWorker`. Using the production broker's spawn and reap
helpers plus protocol framing, it sends the same small program twice in one
surviving harness process: first requesting a 32 MiB string, then a 1 MiB string.
The first must return a bounded implementation/engine failure with no output;
the second must succeed with the correct length. Both must return correlated
single frames, exit normally, and be reaped. This tests the 16 MiB QuickJS heap
policy, not a whole-process memory ceiling. It does not exercise the XPC peer
identity or signed bundle-location checks.

The Keychain probe creates and reads a disposable canary before launch. The
inherited child opens that same keychain but cannot retrieve the known item.
The protected-device probe first opens and immediately closes the connected
Yubico USB service without sending any device command, then requires an
explicit privilege denial for the same registry service in the inherited
child. The Apple Events fixture launches a disposable receiver through
LaunchServices and uses a separate signed control sender to receive the exact
`pong` before and after the inherited worker attempt. The worker's `-600`
result is accepted only with those positive controls and exactly two receiver
deliveries; a matching `appleeventsd` audit explicitly attributed the blocked
lookup to sandboxing on the verification host.

The Apple Events probe is opt-in because macOS may show an Automation consent
dialog for the disposable control sender. After approving that local-only
prompt, run `JORT_APPLE_EVENT_PROBE=1 ./scripts/validate focused containment
--only JortJavaScriptContainmentTests/JortAppleEventProbeTests`. The ordinary
Foundation/gate lane skips this test and must not request consent unattended.

`BrokerFaultHarness.c` separately drives the production broker receive,
supervision, watchdog, and reap paths over anonymous XPC. Its fixture-only
worker selection bypasses signature authentication, while a separate mode
calls the production worker verifier against sealed, wrong-identifier, and
tampered nested copies. Those anonymous-XPC modes do not test the production
XPC caller requirement. A further mode stages signed app/broker/worker copies
and uses the unchanged production client over named XPC: it first proves a
successful request, then terminates only the exact-path disposable broker
while its verified worker is active. It requires one typed unavailable result,
no output, stable client descriptors, and eventual worker disappearance.
Each anonymous fault round checks one correlated terminal reply, no surviving
child, and stable request descriptor counts.

## Target integration

- Exclude `Fixtures` from the `JortJavaScriptContainmentTests` source glob.
- `JortJavaScriptNativeProbe`: macOS tool, `NativeProbe.c`, production protocol,
  shim, and QuickJS sources; use worker header paths / CONFIG_VERSION settings.
  Embed `Probe-Info.plist`; use production worker entitlements; hardened runtime.
- `JortJavaScriptSandboxHarness`: macOS tool, `SandboxHarness.c`, production
  `BrokerIdentity.c`, `BrokerEnvelope.c`, and protocol sources; include broker
  and protocol headers; link Security and Foundation; embed `Harness-Info.plist`;
  use `Harness.entitlements`; hardened runtime. Do not separately compile broker
  `main.c`, which the fixture includes.
- Make both tools non-embedded build dependencies of containment tests. Give
  both `CREATE_INFOPLIST_SECTION_IN_BINARY=YES` and
  `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`. IDs match their Info plists.
- Also add the shipping `JortJavaScriptWorker` as a non-embedded build dependency
  of containment tests so the heap fixture uses the production executable.
- Run through the dispatcher:
  `./scripts/validate focused foundation --only JortJavaScriptContainmentTests/JortSignedNativeProbeTests`.
