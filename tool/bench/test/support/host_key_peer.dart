import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// The test peer needs wire encoders; product code never sees these types.
// ignore: implementation_imports
import 'package:dartssh2/src/kex/kex_nist.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_kex.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_kex_ecdh.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/ssh_kex_utils.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/ssh_message.dart';

const _serverVersion = 'SSH-2.0-PoltergeistContract';
const _uint32Bytes = 4;
const _paddingLengthBytes = 1;
const _packetHeaderBytes = _uint32Bytes + _paddingLengthBytes;
const _minimumPaddingBytes = 4;
const _packetBlockBytes = 8;
const _lineFeed = 0x0a;

/// Signs a real key exchange in memory, then stops at the trust callback.
/// No sshd, sockets, authentication, or private transport access is needed.
class HostKeyPeer {
  static const hostKeyType = 'ssh-ed25519';
  // ssh-keygen -lf over the RFC 8032 public key in OpenSSH wire encoding.
  static const fingerprint =
      'SHA256:bbXpuKG6zhzdmnxq256TlqzFBzRl2f6OOg722cYNbU8';

  // RFC 8032 §7.1, test 1: deliberately public test material.
  static const _seed =
      '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60';
  static const _publicKey =
      'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a';

  final _socket = _MemorySocket();
  final _keyExchange = SSHKexNist.p256();
  final _hostKey = OpenSSHEd25519KeyPair(
    _decodeHex(_publicKey),
    Uint8List.fromList([..._decodeHex(_seed), ..._decodeHex(_publicKey)]),
    'public contract fixture',
  );
  final _serverKexInit = SSH_Message_KexInit(
    kexAlgorithms: [SSHKexType.nistp256.name],
    serverHostKeyAlgorithms: [hostKeyType],
    encryptionClientToServer: [SSHCipherType.aes128ctr.name],
    encryptionServerToClient: [SSHCipherType.aes128ctr.name],
    macClientToServer: [SSHMacType.hmacSha256.name],
    macServerToClient: [SSHMacType.hmacSha256.name],
    compressionClientToServer: const ['none'],
    compressionServerToClient: const ['none'],
    firstKexPacketFollows: false,
  ).encode();
  final _pending = <int>[];
  late final StreamSubscription<List<int>> _requests;
  String? _clientVersion;
  Uint8List? _clientKexInit;

  HostKeyPeer() {
    _requests = _socket._outgoing.stream.listen(
      _receive,
      onError: _socket._incoming.addError,
    );
  }

  SSHSocket get socket => _socket;

  Future<void> close() async {
    await _requests.cancel();
    await _socket.close();
  }

  void _receive(List<int> bytes) {
    // Closing drains queued client writes; replying would mask the test error.
    if (_socket._incoming.isClosed) return;

    try {
      _pending.addAll(bytes);
      if (_clientVersion == null) {
        final newline = _pending.indexOf(_lineFeed);
        if (newline < 0) return;

        _clientVersion = ascii.decode(_pending.sublist(0, newline)).trimRight();
        _pending.removeRange(0, newline + 1);
        _socket._incoming.add(
          Uint8List.fromList(ascii.encode('$_serverVersion\r\n')),
        );
        _send(_serverKexInit);
      }

      // Stream chunks need not align with SSH packets.
      while (_pending.length >= _packetHeaderBytes) {
        final header = Uint8List.fromList(_pending.sublist(0, _uint32Bytes));
        final length = ByteData.sublistView(header).getUint32(0);
        final end = _uint32Bytes + length;
        if (_pending.length < end) return;

        final padding = _pending[_uint32Bytes];
        final payload = Uint8List.fromList(
          _pending.sublist(_packetHeaderBytes, end - padding),
        );
        _pending.removeRange(0, end);
        _reply(payload);
      }
    } on Object catch (error, stack) {
      _socket._incoming.addError(error, stack);
    }
  }

  void _reply(Uint8List payload) {
    if (payload.first == SSH_Message_KexInit.messageId) {
      _clientKexInit = payload;
      return;
    }
    if (payload.first != SSH_Message_KexECDH_Init.messageId) return;

    final clientKey = SSH_Message_KexECDH_Init.decode(payload).ecdhPublicKey;
    final hostKey = _hostKey.toPublicKey().encode();
    final exchangeHash = SSHKexUtils.computeExchangeHash(
      digest: SSHKexType.nistp256.createDigest(),
      clientVersion: _clientVersion!,
      serverVersion: _serverVersion,
      clientKexInit: _clientKexInit!,
      serverKexInit: _serverKexInit,
      hostKey: hostKey,
      clientPublicKey: clientKey,
      serverPublicKey: _keyExchange.publicKey,
      sharedSecret: _keyExchange.computeSecret(clientKey),
    );

    // RFC 5656 §4: host key precedes the ephemeral key in KEX_ECDH_REPLY.
    final reply = SSHMessageWriter()
      ..writeUint8(SSH_Message_KexECDH_Reply.messageId)
      ..writeString(hostKey)
      ..writeString(_keyExchange.publicKey)
      ..writeString(_hostKey.sign(exchangeHash).encode());
    _send(reply.takeBytes());
  }

  void _send(Uint8List payload) {
    var padding =
        _packetBlockBytes -
        ((_packetHeaderBytes + payload.length) % _packetBlockBytes);
    if (padding < _minimumPaddingBytes) padding += _packetBlockBytes;

    final packet = Uint8List(_packetHeaderBytes + payload.length + padding);
    ByteData.sublistView(packet).setUint32(0, packet.length - _uint32Bytes);
    packet[_uint32Bytes] = padding;
    packet.setRange(
      _packetHeaderBytes,
      _packetHeaderBytes + payload.length,
      payload,
    );
    _socket._incoming.add(packet);
  }
}

Uint8List _decodeHex(String value) => Uint8List.fromList([
  for (var offset = 0; offset < value.length; offset += 2)
    int.parse(value.substring(offset, offset + 2), radix: 16),
]);

class _MemorySocket implements SSHSocket {
  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  final _closed = Completer<void>();

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _closed.future;

  @override
  Future<void> close() {
    if (_closed.isCompleted) return done;

    _closed.complete();
    unawaited(_incoming.close());
    unawaited(_outgoing.close());
    return done;
  }

  @override
  void destroy() => unawaited(close());

  @override
  Future<void> flush() async {}
}
