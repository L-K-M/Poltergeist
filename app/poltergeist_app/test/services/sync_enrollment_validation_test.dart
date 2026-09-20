// The ported Séance validator (docs/PORTS.md): every rule the §4.3/§4.5
// forms run before contacting the server, asserted as typed issues the
// render site maps to ARB copy.
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/sync_enrollment_validation.dart';

SyncEnrollmentIssue? _validate({
  SyncEnrollmentMode mode = SyncEnrollmentMode.register,
  String baseUrl = 'https://sync.example',
  String username = 'u',
  String password = 'p',
  String encryptionPassphrase = 'e',
  String confirmationPassphrase = 'e',
}) =>
    validateSyncEnrollment(
      mode: mode,
      baseUrl: baseUrl,
      username: username,
      password: password,
      encryptionPassphrase: encryptionPassphrase,
      confirmationPassphrase: confirmationPassphrase,
    );

void main() {
  group('validateSyncEnrollment (Séance port)', () {
    test('a complete register request passes', () {
      expect(_validate(), isNull);
    });

    test('unparseable and non-http(s) URLs are invalid', () {
      expect(_validate(baseUrl: 'not a url'),
          SyncEnrollmentIssue.invalidServerUrl);
      expect(_validate(baseUrl: 'ftp://sync.example'),
          SyncEnrollmentIssue.invalidServerUrl);
      expect(_validate(baseUrl: 'sync.example'),
          SyncEnrollmentIssue.invalidServerUrl);
      expect(_validate(baseUrl: 'https://'),
          SyncEnrollmentIssue.invalidServerUrl);
      // HTTP stays valid for localhost and self-hosted deployments.
      expect(_validate(baseUrl: 'http://localhost:8799'), isNull);
    });

    test('credentials embedded in the URL are rejected', () {
      expect(_validate(baseUrl: 'https://u:p@sync.example'),
          SyncEnrollmentIssue.credentialsInUrl);
    });

    test('every required field is checked', () {
      expect(_validate(username: '  '),
          SyncEnrollmentIssue.missingUsername);
      expect(_validate(password: ''),
          SyncEnrollmentIssue.missingPassword);
      expect(_validate(encryptionPassphrase: ' '),
          SyncEnrollmentIssue.missingEncryptionPassphrase);
    });

    test('register requires a matching confirmation; login does not ask',
        () {
      expect(_validate(confirmationPassphrase: ''),
          SyncEnrollmentIssue.missingConfirmation);
      expect(_validate(confirmationPassphrase: 'different'),
          SyncEnrollmentIssue.confirmationMismatch);
      // Login ignores the confirmation field entirely.
      expect(
        _validate(
            mode: SyncEnrollmentMode.login, confirmationPassphrase: ''),
        isNull,
      );
    });
  });
}
