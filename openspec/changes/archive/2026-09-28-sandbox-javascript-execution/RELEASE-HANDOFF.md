# Wave 4 containment handoff

`establish-signed-release-and-app-identity` must treat this graph as a mandatory input, not infer or preserve the pre-containment layout.

| Role | Identifier | Required nested path | Entitlements |
|---|---|---|---|
| App | `dev.jort.editor` | `Jort.app/Contents/MacOS/Jort` | Wave 4 app policy |
| XPC broker | `dev.jort.editor.javascript-broker` | `Jort.app/Contents/XPCServices/JortJavaScriptBroker.xpc/Contents/MacOS/JortJavaScriptBroker` | only `com.apple.security.app-sandbox = true` |
| Worker | `dev.jort.editor.javascript-worker` | `Jort.app/Contents/XPCServices/JortJavaScriptBroker.xpc/Contents/Helpers/JortJavaScriptWorker` | exactly app-sandbox plus inherit |
| C client framework | `dev.jort.javascript.client` | `Jort.app/Contents/Frameworks/JortJavaScriptClient.framework` | none |

The app embeds the client framework, Runtime framework, and private broker; the broker bundle embeds the worker under its own `Contents/Helpers`. Runtime links the C client, the client speaks low-level authenticated XPC, and the broker alone launches the fixed worker path. QuickJS and `JortJavaScript.c` may link only into the worker among shipping products. The nonshipping `JortJavaScriptTestOracle` is an XCTest dependency and must never enter the app, package, release manifest, notarization input, or runtime mapping.

Local Debug builds use ad-hoc signing only through `JORT_JS_ALLOW_ADHOC=1` on the client and broker; every nested component is still signed and sandbox entitlements are exercised. Release builds do not enable that escape hatch. Wave 4 must replace the ad-hoc relationship with exact identifiers and the same real Team ID, then verify every nested signature before packaging.

Mandatory verification entry points are `./scripts/validate fast`, focused Foundation/native checks while iterating, `./scripts/validate quickjs`, `./scripts/validate package`, strict `openspec validate sandbox-javascript-execution`, and one final `./scripts/validate gate`. The package and gate lanes invoke `scripts/verify-javascript-containment.py` against their signed app products. Wave 4 must additionally repeat runtime-mapping checks, the complete signed sandbox-denial matrix, and notarized-package verification under the distribution identity. The current local probes cover file, network, and subprocess denial plus the CPU limit; Keychain, Apple Events, and protected-device denial are not yet demonstrated.
