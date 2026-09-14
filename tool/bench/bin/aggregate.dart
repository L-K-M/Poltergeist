import 'package:poltergeist_m0_bench/aggregate_cli.dart';

/// Legacy compatibility entrypoint: forwards to the relocated harness at
/// packages/poltergeist_bench (07 §3.4). Same flags, same exit codes.
Future<void> main(List<String> arguments) => aggregateMain(arguments);
