import 'dart:convert';
import 'dart:io';

const _loopbackAddress = '127.0.0.1';
const _hostNetworkMode = 'host';

/// Finds host exposure paths in rendered Compose JSON.
List<String> findExposureErrors(Map<String, Object?> config) {
  final errors = <String>[];
  final services = config['services'];
  if (services is! Map) {
    return ['rendered config has no services map'];
  }

  for (final entry in services.entries) {
    final serviceName = entry.key.toString();
    final service = entry.value;
    if (service is! Map) {
      errors.add('$serviceName is not a service map');
      continue;
    }

    if (service['network_mode'] == _hostNetworkMode) {
      errors.add('$serviceName uses host networking');
    }

    final ports = service['ports'];
    if (ports == null) {
      continue;
    }
    if (ports is! List) {
      errors.add('$serviceName ports are not normalized');
      continue;
    }

    for (final port in ports) {
      if (port is! Map) {
        errors.add('$serviceName has an unnormalized port: $port');
        continue;
      }

      final hostIp = port['host_ip'];
      if (hostIp != _loopbackAddress) {
        errors.add('$serviceName publishes on ${hostIp ?? 'all interfaces'}');
      }
    }
  }

  return errors;
}

Future<void> main() async {
  final input = await stdin.transform(utf8.decoder).join();

  Object? decoded;
  try {
    decoded = jsonDecode(input);
  } on FormatException catch (error) {
    stderr.writeln('invalid rendered Compose JSON: $error');
    exitCode = 2;
    return;
  }

  if (decoded is! Map<String, Object?>) {
    stderr.writeln('rendered Compose config is not an object');
    exitCode = 2;
    return;
  }

  final errors = findExposureErrors(decoded);
  if (errors.isEmpty) {
    stdout.writeln('Compose exposure check passed.');
    return;
  }

  for (final error in errors) {
    stderr.writeln('unsafe Compose config: $error');
  }
  exitCode = 1;
}
