# Tool packages

A package is a directory with `tool.json` and `tool.js`. The bundled tools in
`Jort/Resources/Tools` are complete examples. Settings → Tools edits the same
packages that the editor runs. Customize creates a user override; deleting that
override restores the current bundled package. Application updates preserve user
packages. Installed generations live under the app data directory's `Tools/`.
The atomic `index.json` selects current generations; older files are retained for
recovery. The registry's `install(from:)` imports a package directory.

The version-one manifest requires `schemaVersion`, a reverse-DNS `id`, a positive
integer `version`, `name`, slash-prefixed `command`, `description`, `entryContract`,
`inputMode`, `outputOperation`, `maximumInputBytes`, `maximumOutputBytes`, and
`maximumOutputLines`. The four input mode values are `contained`, `contextual`,
`ephemeralSingleLine`, and `ephemeralMultiline`. Output operations are
`replace-invocation`, `replace-context`, and `insert-at-invocation`.

```javascript
export default async function(input) {
  return {output: input.content.toUpperCase()};
}

// Optional. Runs before source is locked or the main entry point is called.
export async function validate(input) {
  return input.content.trim() ? {output: ""} : {error: "Enter some text."};
}
```

Both entry points receive a frozen object with `content`, `clock` (captured UTC
ISO-8601 string), `uuid` (captured lowercase UUID), and a read-only `cancelled`
getter. Return exactly one of `{output: string}` or `{error: string}`. There are
no separately parsed arguments. The host owns publication and Merge; scripts
never receive the document or editor. Empty output is a successful result.

Execution has a 16 MiB heap, 512 KiB stack, five-second timeout, and manifest
input/output bounds. Cancellation interrupts execution. There are no filesystem,
network, process, native bridge, module loading, `eval`, or function-constructor
facilities. No engine standard-library or operating-system bindings are linked.
Each run creates a fresh runtime. The engine source and MIT license are pinned
under `Vendor/QuickJS`; its two small local extensions are documented there.

`compatibleVersions` may list up to 32 older positive package versions that map
unchanged to the current entry, input, and output contracts. Completed output is
never rerun during migration. Without a compatible mapping, inputting source
becomes plain text; completed output is retained and invocation-owned source is
removed. Contextual source survives this fallback.

The bundled date format is `YYYY-MM-DD` in UTC; time is `HH:mm:ssZ`. Calculator
power is right associative, binds more tightly than a leading unary sign, and
rejects non-finite results. Sort uses literal JavaScript string ordering; dedupe
keeps the first exact line. Neither normalizes whitespace or Unicode.
