// The transport seam the backup service builds per server: the pinned
// Séance HTTP sync client satisfies 04 §4.5's `SyncEnrollmentApi` shape
// wholesale, plus the account-deletion verb (§4.1's "Delete backup
// account…" and §4.4's optional post-switch delete) and connection
// release — neither part of the core seam.
import 'package:poltergeist_core/poltergeist_core.dart';

/// A [SyncEnrollmentApi] that can also delete the account it is signed
/// into and release its connections.
abstract interface class SyncTransport implements SyncEnrollmentApi {
  /// DELETE /v1/account — in separate mode only; §4.2 hides it in shared
  /// mode (the account carries the user's Séance data).
  Future<void> deleteAccount();

  /// Release owned connections; the client cannot be reused afterwards.
  void close();
}

/// Builds the transport for [baseUrl]. [token] seeds a restored session —
/// sync rounds and the post-switch delete authenticate with the stored
/// bearer token; enrollment calls pass none.
typedef SyncTransportFactory = SyncTransport Function(
  String baseUrl, {
  String? token,
});

/// The production binding: `HttpSyncClient` already implements every
/// member [SyncTransport] declares (04 §4.5 names it the satisfying
/// shape), so the subclass is a pure marker. The bearer token is a public
/// field on the client — seeded here so restored sessions authenticate
/// without another login.
final class HttpSyncTransport extends HttpSyncClient
    implements SyncTransport {
  HttpSyncTransport({required super.baseUrl, String? token}) {
    this.token = token;
  }
}

/// The default [SyncTransportFactory] — the composition root's binding;
/// tests substitute fakes.
SyncTransport httpSyncTransport(String baseUrl, {String? token}) =>
    HttpSyncTransport(baseUrl: baseUrl, token: token);
