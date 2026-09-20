// Ported from Séance app/seance_app/lib/ui/sync_enrollment_validation.dart
// @ 2e6d1f1; see docs/PORTS.md. Recorded divergence: the issue is reported
// as a typed value the render site maps to ARB copy (D20), never an
// embedded English string — the validation RULES are byte-identical.

/// Which enrollment shape the validator checks: Séance's
/// `SyncEnrollmentMode` pair — register carries the passphrase
/// confirmation requirement, login does not.
enum SyncEnrollmentMode { register, login }

/// The failure [validateSyncEnrollment] reports, mapped to ARB copy at
/// the render site.
enum SyncEnrollmentIssue {
  invalidServerUrl,
  credentialsInUrl,
  missingUsername,
  missingPassword,
  missingEncryptionPassphrase,
  missingConfirmation,
  confirmationMismatch,
}

/// Returns the issue blocking enrollment from contacting the server, or
/// null when the request is ready to run — the ported
/// `validateSyncEnrollment`, rule-for-rule.
SyncEnrollmentIssue? validateSyncEnrollment({
  required SyncEnrollmentMode mode,
  required String baseUrl,
  required String username,
  required String password,
  required String encryptionPassphrase,
  String confirmationPassphrase = '',
}) {
  final uri = Uri.tryParse(baseUrl.trim());
  final scheme = uri?.scheme.toLowerCase();
  // HTTP remains valid for localhost, development, and existing self-hosted
  // deployments; stricter transport policy is a separate migration.
  if (uri == null ||
      (scheme != 'http' && scheme != 'https') ||
      uri.host.isEmpty) {
    return SyncEnrollmentIssue.invalidServerUrl;
  }
  if (uri.userInfo.isNotEmpty) {
    return SyncEnrollmentIssue.credentialsInUrl;
  }
  if (username.trim().isEmpty) return SyncEnrollmentIssue.missingUsername;
  if (password.trim().isEmpty) return SyncEnrollmentIssue.missingPassword;
  if (encryptionPassphrase.trim().isEmpty) {
    return SyncEnrollmentIssue.missingEncryptionPassphrase;
  }
  if (mode == SyncEnrollmentMode.register) {
    if (confirmationPassphrase.trim().isEmpty) {
      return SyncEnrollmentIssue.missingConfirmation;
    }
    if (confirmationPassphrase != encryptionPassphrase) {
      return SyncEnrollmentIssue.confirmationMismatch;
    }
  }
  return null;
}
