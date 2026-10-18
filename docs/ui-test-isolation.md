# GUI test isolation

Run GUI checks through `./scripts/validate ui`, `focused ui --only …`, or
`package`. These routes build test products without launching Jort, then prepare
a fresh, credential-free copy with its own `dev.jort.editor.uitests.…` bundle
identifier. The original build and `dist/Jort.app` are not modified.

The copy keeps the original ad-hoc signing identifier required by the JavaScript
broker. Only its outer bundle is re-signed; nested code and production signing,
credential, and containment policies remain unchanged. Preparation refuses
credential-bearing or unexpectedly signed apps.

The test runner opens that exact bundle URL with temporary notes. Before any
editor input, it checks a fresh launch receipt against the running process's
identifier, executable, bundle path, and note directory. A mismatch fails the
test rather than falling back to an installed Jort. Each relaunch repeats this
check. Normal Jort launches do not create test receipts.

Run-owned copies and launch metadata remain under the validation products'
`.isolated-ui/` directory for diagnostics; test note directories are temporary.
Clipboard behavior is unchanged.
