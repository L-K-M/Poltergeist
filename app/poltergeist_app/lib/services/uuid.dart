import 'package:uuid/uuid.dart';

/// Mints the UUID form shared by persisted records and temporary files.
String uuidV4() => const Uuid().v4();
