import 'package:poltergeist_core/poltergeist_core.dart';

/// An in-memory [SshConfigFileSource] for import tests: [files] maps
/// absolute paths to text, and directory listings report as absent (tests
/// that need includes stub the listing themselves).
class FakeSshConfigSource implements SshConfigFileSource {
  FakeSshConfigSource(this.files);

  final Map<String, String> files;

  @override
  Future<String?> readText(String path) async => files[path];

  @override
  Future<List<String>?> listLexical(String directory) async => null;
}
