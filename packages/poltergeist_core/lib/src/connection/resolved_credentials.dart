import 'package:seance_core/seance_core.dart';

/// The SSH opener cannot infer whether a supplied secret required a prompt.
enum CredentialOrigin { stored, prompted }

/// One vault resolution, including the interaction that caps pool growth.
/// Never persisted or retained by a server reference (D5, D18).
class ResolvedSshCredentials {
  final SshCredentials credentials;
  final CredentialOrigin origin;

  const ResolvedSshCredentials({
    required this.credentials,
    required this.origin,
  });
}
