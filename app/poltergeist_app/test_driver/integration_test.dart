// `flutter drive` counterpart for the tier-B suites: connects to the
// app under test, reports pass/fail back to the tool process.
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
