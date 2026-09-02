import 'dart:convert';

import 'package:crypto/crypto.dart';

const throughputRttProbeCount = 7;
const _microsecondsPerMillisecond = 1000;
const _rttReferencePrefix = 'rtt-sha256:';

enum ThroughputVariant {
  dartHashOn('dart-hash-on'),
  dartHashOff('dart-hash-off'),
  openssh('openssh');

  final String cliValue;

  const ThroughputVariant(this.cliValue);
}

enum ThroughputLeg { download, upload }

enum ThroughputReplicate {
  first(1),
  second(2);

  final int number;

  const ThroughputReplicate(this.number);
}

class ThroughputSampleSpec {
  final ThroughputLeg direction;
  final ThroughputVariant variant;
  final ThroughputReplicate replicate;

  const ThroughputSampleSpec({
    required this.direction,
    required this.variant,
    required this.replicate,
  });

  String get cliValue =>
      'rtt100-1gb-${direction.name}-${variant.cliValue}-r${replicate.number}';

  static ThroughputSampleSpec parse(String value) {
    for (final direction in ThroughputLeg.values) {
      for (final variant in ThroughputVariant.values) {
        for (final replicate in ThroughputReplicate.values) {
          final spec = ThroughputSampleSpec(
            direction: direction,
            variant: variant,
            replicate: replicate,
          );
          if (spec.cliValue == value) return spec;
        }
      }
    }

    throw FormatException('Unknown throughput sample: $value');
  }
}

class RttEvidence {
  final List<int> samplesUs;
  final int medianMs;
  final DateTime capturedAtUtc;
  final String reference;

  RttEvidence._({
    required List<int> samplesUs,
    required this.medianMs,
    required this.capturedAtUtc,
    required this.reference,
  }) : samplesUs = List.unmodifiable(samplesUs);

  factory RttEvidence.parse(String source) {
    late final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw FormatException('Invalid RTT evidence JSON: ${error.message}');
    }
    if (decoded is! Map) {
      throw const FormatException('RTT evidence must be a JSON object.');
    }

    final json = decoded.cast<String, Object?>();
    const fields = {'samplesUs', 'medianMs', 'capturedAtUtc'};
    if (json.keys.toSet().difference(fields).isNotEmpty ||
        fields.difference(json.keys.toSet()).isNotEmpty) {
      throw const FormatException(
        'RTT evidence needs samplesUs, medianMs, and capturedAtUtc.',
      );
    }

    return RttEvidence._fromSourceJson(json);
  }

  factory RttEvidence.fromJson(Map<String, Object?> json) {
    const fields = {'reference', 'samplesUs', 'medianMs', 'capturedAtUtc'};
    if (!_setsEqual(json.keys.toSet(), fields)) {
      throw const FormatException('Serialized RTT evidence is incomplete.');
    }
    final source = <String, Object?>{
      'samplesUs': json['samplesUs'],
      'medianMs': json['medianMs'],
      'capturedAtUtc': json['capturedAtUtc'],
    };
    final evidence = RttEvidence._fromSourceJson(source);
    final serializedReference = json['reference'];
    if (serializedReference is! String ||
        serializedReference != evidence.reference) {
      throw const FormatException('RTT evidence reference is invalid.');
    }

    return evidence;
  }

  factory RttEvidence._fromSourceJson(Map<String, Object?> json) {
    final rawSamples = json['samplesUs'];
    if (rawSamples is! List || rawSamples.length != throughputRttProbeCount) {
      throw const FormatException('RTT evidence needs seven samples.');
    }
    final samples = <int>[];
    for (final sample in rawSamples) {
      if (sample is! int || sample <= 0) {
        throw const FormatException('RTT samples must be positive integers.');
      }
      samples.add(sample);
    }

    final medianMs = json['medianMs'];
    if (medianMs is! int || medianMs <= 0) {
      throw const FormatException('RTT median must be a positive integer.');
    }
    final ordered = [...samples]..sort();
    final derivedMedian =
        (ordered[ordered.length ~/ 2] + _microsecondsPerMillisecond ~/ 2) ~/
        _microsecondsPerMillisecond;
    if (medianMs != derivedMedian) {
      throw FormatException(
        'RTT median $medianMs does not match $derivedMedian.',
      );
    }

    final capturedText = json['capturedAtUtc'];
    if (capturedText is! String) {
      throw const FormatException('RTT capture time must be a string.');
    }
    late final DateTime capturedAt;
    try {
      capturedAt = DateTime.parse(capturedText);
    } on FormatException {
      throw const FormatException('RTT capture time is invalid.');
    }
    if (!capturedAt.isUtc || !_hasUtcSuffix(capturedText)) {
      throw const FormatException('RTT capture time must be UTC.');
    }

    final canonical = <String, Object?>{
      'samplesUs': samples,
      'medianMs': medianMs,
      'capturedAtUtc': capturedAt.toIso8601String(),
    };
    final digest = sha256.convert(utf8.encode(jsonEncode(canonical)));
    return RttEvidence._(
      samplesUs: samples,
      medianMs: medianMs,
      capturedAtUtc: capturedAt,
      reference: '$_rttReferencePrefix$digest',
    );
  }

  Map<String, Object?> toJson() => {
    'reference': reference,
    'samplesUs': samplesUs,
    'medianMs': medianMs,
    'capturedAtUtc': capturedAtUtc.toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is RttEvidence &&
      _listsEqual(samplesUs, other.samplesUs) &&
      medianMs == other.medianMs &&
      capturedAtUtc == other.capturedAtUtc &&
      reference == other.reference;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(samplesUs),
    medianMs,
    capturedAtUtc,
    reference,
  );
}

enum ThroughputAttemptPhase { prime, warmup, trial }

enum ThroughputAttemptStatus { running, success, timeout, failure }

enum ThroughputIntegrityStatus { pending, verified, failed }

class ThroughputIntegrityEvidence {
  final ThroughputIntegrityStatus status;
  final int expectedBytes;
  final int? actualBytes;
  final String expectedSha256;
  final String? actualSha256;
  final String destination;
  final String? detail;

  const ThroughputIntegrityEvidence({
    required this.status,
    required this.expectedBytes,
    this.actualBytes,
    required this.expectedSha256,
    this.actualSha256,
    required this.destination,
    this.detail,
  });

  factory ThroughputIntegrityEvidence.fromJson(Map<String, Object?> json) =>
      ThroughputIntegrityEvidence(
        status: ThroughputIntegrityStatus.values.byName(
          json['status']! as String,
        ),
        expectedBytes: json['expectedBytes']! as int,
        actualBytes: json['actualBytes'] as int?,
        expectedSha256: json['expectedSha256']! as String,
        actualSha256: json['actualSha256'] as String?,
        destination: json['destination']! as String,
        detail: json['detail'] as String?,
      );

  bool get isVerified => status == ThroughputIntegrityStatus.verified;

  Map<String, Object?> toJson() => {
    'status': status.name,
    'expectedBytes': expectedBytes,
    'actualBytes': actualBytes,
    'expectedSha256': expectedSha256,
    'actualSha256': actualSha256,
    'destination': destination,
    'detail': detail,
  };
}

class ThroughputAttempt {
  final String reference;
  final String scenario;
  final ThroughputLeg direction;
  final ThroughputVariant? variant;
  final ThroughputReplicate? replicate;
  final int? ordinal;
  final ThroughputAttemptPhase phase;
  final int payloadBytes;
  final ThroughputAttemptStatus status;
  final DateTime startedAtUtc;
  final DateTime? endedAtUtc;
  final Duration? elapsed;
  final String? primeReference;
  final String? warmupReference;
  final RttEvidence? rttEvidence;
  final ThroughputIntegrityEvidence integrity;
  final String? error;

  const ThroughputAttempt({
    required this.reference,
    required this.scenario,
    required this.direction,
    required this.variant,
    required this.replicate,
    required this.ordinal,
    required this.phase,
    required this.payloadBytes,
    required this.status,
    required this.startedAtUtc,
    required this.endedAtUtc,
    required this.elapsed,
    required this.primeReference,
    required this.warmupReference,
    this.rttEvidence,
    required this.integrity,
    this.error,
  });

  factory ThroughputAttempt.fromJson(Map<String, Object?> json) =>
      ThroughputAttempt(
        reference: json['reference']! as String,
        scenario: json['scenario']! as String,
        direction: ThroughputLeg.values.byName(json['direction']! as String),
        variant: json['variant'] == null
            ? null
            : ThroughputVariant.values.firstWhere(
                (variant) => variant.cliValue == json['variant'],
              ),
        replicate: json['replicate'] == null
            ? null
            : ThroughputReplicate.values.firstWhere(
                (replicate) => replicate.number == json['replicate'],
              ),
        ordinal: json['ordinal'] as int?,
        phase: ThroughputAttemptPhase.values.byName(json['phase']! as String),
        payloadBytes: json['payloadBytes']! as int,
        status: ThroughputAttemptStatus.values.byName(
          json['status']! as String,
        ),
        startedAtUtc: DateTime.parse(json['startedAtUtc']! as String),
        endedAtUtc: json['endedAtUtc'] == null
            ? null
            : DateTime.parse(json['endedAtUtc']! as String),
        elapsed: json['elapsedUs'] == null
            ? null
            : Duration(microseconds: json['elapsedUs']! as int),
        primeReference: json['primeReference'] as String?,
        warmupReference: json['warmupReference'] as String?,
        rttEvidence: json['rttEvidence'] == null
            ? null
            : RttEvidence.fromJson(
                (json['rttEvidence']! as Map).cast<String, Object?>(),
              ),
        integrity: ThroughputIntegrityEvidence.fromJson(
          (json['integrity']! as Map).cast<String, Object?>(),
        ),
        error: json['error'] as String?,
      );

  ThroughputAttempt finish({
    required ThroughputAttemptStatus status,
    required DateTime endedAtUtc,
    Duration? elapsed,
    required ThroughputIntegrityEvidence integrity,
    String? error,
  }) => ThroughputAttempt(
    reference: reference,
    scenario: scenario,
    direction: direction,
    variant: variant,
    replicate: replicate,
    ordinal: ordinal,
    phase: phase,
    payloadBytes: payloadBytes,
    status: status,
    startedAtUtc: startedAtUtc,
    endedAtUtc: endedAtUtc,
    elapsed: elapsed,
    primeReference: primeReference,
    warmupReference: warmupReference,
    rttEvidence: rttEvidence,
    integrity: integrity,
    error: error,
  );

  Map<String, Object?> toJson() => {
    'reference': reference,
    'scenario': scenario,
    'direction': direction.name,
    'variant': variant?.cliValue,
    'replicate': replicate?.number,
    'ordinal': ordinal,
    'phase': phase.name,
    'payloadBytes': payloadBytes,
    'status': status.name,
    'startedAtUtc': startedAtUtc.toIso8601String(),
    'endedAtUtc': endedAtUtc?.toIso8601String(),
    'elapsedUs': elapsed?.inMicroseconds,
    'primeReference': primeReference,
    'warmupReference': warmupReference,
    'rttEvidence': rttEvidence?.toJson(),
    'integrity': integrity.toJson(),
    'error': error,
  };
}

class ThroughputTrialEvidence {
  final ThroughputAttempt sourcePrime;
  final ThroughputAttempt warmupSourcePrime;
  final ThroughputAttempt warmup;
  final ThroughputAttempt trial;

  const ThroughputTrialEvidence({
    required this.sourcePrime,
    required this.warmupSourcePrime,
    required this.warmup,
    required this.trial,
  });

  factory ThroughputTrialEvidence.fromJson(Map<String, Object?> json) =>
      ThroughputTrialEvidence(
        sourcePrime: _attemptFrom(json, 'sourcePrime'),
        warmupSourcePrime: _attemptFrom(json, 'warmupSourcePrime'),
        warmup: _attemptFrom(json, 'warmup'),
        trial: _attemptFrom(json, 'trial'),
      );

  Map<String, Object?> toJson() => {
    'sourcePrime': sourcePrime.toJson(),
    'warmupSourcePrime': warmupSourcePrime.toJson(),
    'warmup': warmup.toJson(),
    'trial': trial.toJson(),
  };
}

ThroughputAttempt _attemptFrom(Map<String, Object?> json, String field) =>
    ThroughputAttempt.fromJson((json[field]! as Map).cast<String, Object?>());

bool _hasUtcSuffix(String value) =>
    value.endsWith('Z') ||
    value.endsWith('z') ||
    value.endsWith('+00:00') ||
    value.endsWith('-00:00');

bool _listsEqual(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

bool _setsEqual(Set<String> first, Set<String> second) =>
    first.length == second.length && first.containsAll(second);
