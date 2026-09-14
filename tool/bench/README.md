# M0 bench harness — legacy compatibility entrypoint

The harness moved to [`packages/poltergeist_bench`](../../packages/poltergeist_bench)
in the M3 relocation (07 §3.4). This directory only forwards the documented
legacy invocations:

```bash
dart pub get --directory tool/bench
test/integration/run.sh --lifecycle-only -- tool/bench/run.sh
# or, for focused iteration from the old location:
cd tool/bench && dart run bin/bench.dart --help
```

`run.sh` and `bin/bench.dart` execute the relocated package's code directly
(same flags, same exit codes). Results now land in
`packages/poltergeist_bench/bench-results.json` (plus
`.attempts.json`), regardless of the invoking directory — previously
`tool/bench/bench-results.json`; update artifact globs and consumers
accordingly. Pass `--output` to write elsewhere.
