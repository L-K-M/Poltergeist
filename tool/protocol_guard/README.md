# Engine protocol guard

```sh
dart analyze tool/protocol_guard
dart test tool/protocol_guard/test
dart run tool/protocol_guard/bin/check.dart .
```

Enforces 08 §3.3: engine declarations cannot store function-typed fields;
`EngineRequest`/`EngineEvent` subtypes must stay under core's `src/engine/`.
Resolution catches typedefs, inferred callbacks, type-parameter bounds,
and callbacks inside generic or record fields. Checks include extension-type
representations and inherited superclass/mixin storage with substituted type
arguments, including private fields and fields hidden by getter overrides.
External extension wrappers are checked through their erased representation.
Inherited static members, interfaces, methods, and computed getters add no
instance storage.

The commented allowlist names each internal callback owner by exact file
and class. A protocol subtype cannot use an exception. Scan inputs include
package/app sources and tests, excluding generated outputs. Missing,
linked, malformed, or unresolved engine inputs fail closed.

Exit codes: 0 clean, 1 policy violation, 2 scan failure. Runtime protocol
round-trip tests still verify payload values; static types alone cannot
inspect a callback hidden behind `Object` or `dynamic`.
