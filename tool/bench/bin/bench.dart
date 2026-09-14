import 'package:poltergeist_m0_bench/bench_cli.dart';

/// Legacy compatibility entrypoint: forwards to the relocated harness at
/// packages/poltergeist_bench (07 §3.4). Same flags, same exit codes.
Future<void> main(List<String> arguments) => benchMain(arguments);
