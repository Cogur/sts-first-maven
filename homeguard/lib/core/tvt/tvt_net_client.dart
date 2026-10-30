import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../utils/log.dart';
import 'tvt_net_protocol.dart';

class TvtNetException implements Exception {
  TvtNetException(this.message, {this.authFailure = false});
  final String message;
  final bool authFailure;
  @override
  String toString() => message;
}

/// A byte pipe to a device. TCP on the LAN today; a P2P tunnel (see
/// `tvt_p2p.dart`) plugs in here once one exists, so the protocol code above
/// it does not change.
abstract class TvtTransport {
  Stream<Uint8List> get input;
  void add(List<int> bytes);
  Future<void> close();
}

class TcpTvtTransport implements TvtTransport {
  TcpTvtTransport._(this._socket);
  final Socket _socket;

  static Future<TcpTvtTransport> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    try {
      // Owned by the transport and destroyed in close().
      // ignore: close_sinks
      final s = await Socket.connect(host, port, timeout: timeout);
      s.setOption(SocketOption.tcpNoDelay, true);
      return TcpTvtTransport._(s);
    } on SocketException catch (e) {
      throw TvtNetException('Cannot reach $host:$port (${e.osError?.message ?? e.message})');
    }
  }

  @override
  Stream<Uint8List> get input => _socket;
  @override
  void add(List<int> bytes) => _socket.add(bytes);
  @override
  Future<void> close() async => _socket.destroy();
}

/// Client for the binary device protocol: login with the SuperLive
/// credentials, tunnelled HTTP, alarm outputs (door relay on intercoms).
class TvtNetClient {
  TvtNetClient(this._transport, {this.timeout = const Duration(seconds: 6)}) {
    _sub = _transport.input.listen(
      _onData,
      onError: (Object e) => _fail(TvtNetException('Connection error: $e')),
      onDone: () => _fail(TvtNetException('Connection closed by device')),
    );
  }

  static Future<TvtNetClient> connect(String host, int port) async =>
      TvtNetClient(await TcpTvtTransport.connect(host, port));

  final TvtTransport _transport;
  final Duration timeout;
  final _parser = TvtStreamParser();
  late final StreamSubscription<Uint8List> _sub;
  final _initDone = Completer<TvtInit>();
  final _queue = <TvtPacket>[];
  Completer<void>? _wake;
  Object? _error;
  int _httpSeq = 0;
  Timer? _keepAlive;

  TvtInit? get init => _parser.init;
  TvtLoginInfo? loginInfo;

  void _onData(Uint8List chunk) {
    try {
      _parser.add(chunk);
    } on FormatException catch (e) {
      _fail(TvtNetException('Protocol error: ${e.message}'));
      return;
    }
    if (_parser.init != null && !_initDone.isCompleted) _initDone.complete(_parser.init);
    if (_parser.packets.isNotEmpty) {
      _queue.addAll(_parser.packets);
      _parser.packets.clear();
      _wake?.complete();
      _wake = null;
    }
  }

  void _fail(Object e) {
    _error ??= e;
    if (!_initDone.isCompleted) _initDone.completeError(e);
    _wake?.complete();
    _wake = null;
  }

  Future<TvtPacket> _next(bool Function(TvtPacket) want) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final i = _queue.indexWhere(want);
      if (i >= 0) return _queue.removeAt(i);
      if (_error != null) throw _error!;
      final left = deadline.difference(DateTime.now());
      if (left.isNegative) throw TvtNetException('Device did not reply within ${timeout.inSeconds}s');
      _wake = Completer<void>();
      await _wake!.future.timeout(left, onTimeout: () {});
    }
  }

  Future<TvtLoginInfo> login(String username, String password) async {
    final init = await _initDone.future.timeout(
      timeout,
      onTimeout: () => throw TvtNetException('No TVT greeting: this port is not a TVT device'),
    );
    _transport.add(TvtCodec.loginRequest(username, password, init));
    while (true) {
      final p = await _next((p) => !p.isHeartbeat);
      if (TvtCmd.isLoginFail(p.cmd)) {
        throw TvtNetException('Invalid username or password', authFailure: true);
      }
      // Head-variant firmware sends short acknowledgements before the reply.
      if (TvtCmd.isLoginOk(p.cmd) || p.data.length > 100) {
        loginInfo = TvtLoginInfo.parse(p.data, headVariant: init.headVariant);
        _keepAlive = Timer.periodic(const Duration(seconds: 10), (_) => _transport.add(TvtCodec.heartbeat()));
        Log.d('tvt-net', 'login ok (protocol ${init.protocolVer}, ${loginInfo!.channels.length} channels)');
        return loginInfo!;
      }
    }
  }

  /// Runs an HTTP request inside the device protocol (same API as the web
  /// interface, without needing the HTTP port).
  Future<Uint8List> http(String path, {String method = 'GET', String body = ''}) async {
    _transport.add(TvtCodec.httpRequest(path, ++_httpSeq, method: method, body: body));
    final p = await _next((p) => p.cmd == TvtCmd.replyHttp);
    return TvtCodec.httpReplyBody(p.data);
  }

  /// Pulses an alarm output. On TVT intercoms the door relay is exposed as
  /// alarm output [channel] (experimental: not confirmed for every model).
  Future<void> pulseAlarmOut(int channel, Duration hold) async {
    _transport.add(TvtCodec.alarmOut(channel, on: true));
    await Future<void>.delayed(hold);
    _transport.add(TvtCodec.alarmOut(channel, on: false));
  }

  Future<void> close() async {
    _keepAlive?.cancel();
    try {
      _transport.add(TvtCodec.encode(TvtCmd.logout));
    } catch (_) {
      // Already disconnected.
    }
    await _sub.cancel();
    await _transport.close();
  }
}
