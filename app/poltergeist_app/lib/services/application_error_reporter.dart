import 'package:flutter/foundation.dart';

typedef ApplicationErrorSink = void Function(Object, StackTrace);

final class ApplicationErrorReporter {
  ApplicationErrorReporter({ApplicationErrorSink? sink})
    : _sink = sink ?? _reportFlutterError;

  final ApplicationErrorSink _sink;

  void report(Object error, StackTrace stackTrace) {
    try {
      _sink(error, stackTrace);
    } catch (_) {
      // Reporting must terminate an error path, even if its sink fails.
    }
  }

  void observe(Future<void> operation) {
    operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        report(error, stackTrace);
      },
    );
  }

  Future<void> guard(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (error, stackTrace) {
      report(error, stackTrace);
    }
  }
}

void _reportFlutterError(Object error, StackTrace stackTrace) {
  FlutterError.reportError(
    FlutterErrorDetails(exception: error, stack: stackTrace),
  );
}
