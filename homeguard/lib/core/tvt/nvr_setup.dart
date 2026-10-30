import '../security/secure_store.dart';
import '../utils/log.dart';
import 'tvt_web_client.dart';

/// What sign-in learned from the recorder's web interface.
class NvrSetupResult {
  const NvrSetupResult({
    required this.channels,
    required this.rtspPort,
    this.rtspWasEnabled = false,
    this.httpPort = 80,
  });

  final List<TvtChannel> channels;
  final int rtspPort;
  final int httpPort;

  /// True when HomeGuard switched the RTSP service on during this sign-in.
  final bool rtspWasEnabled;
}

class NvrSetupException implements Exception {
  NvrSetupException(
    this.message, {
    this.authFailure = false,
    this.unreachable = false,
    this.needsRtsp = false,
  });
  final String message;
  final bool authFailure;

  /// No TVT web interface answered (other brand, wrong port, or the
  /// simulator): sign-in falls back to plain RTSP verification.
  final bool unreachable;

  /// Credentials are fine but RTSP is off; the user must agree to turn it on.
  final bool needsRtsp;
  @override
  String toString() => message;
}

typedef TvtWebFactory = TvtWebClient Function(String host, int port, Credentials c);

TvtWebClient defaultTvtWebFactory(String host, int port, Credentials c) =>
    TvtWebClient(host: host, port: port, username: c.username, password: c.password);

/// Signs in like SuperLive Plus / the NVR web page does (same username and
/// password), reads the camera list and, with the user's consent, switches
/// on the RTSP service the app streams from. No router or admin menus.
class NvrSetup {
  NvrSetup({TvtWebFactory factory = defaultTvtWebFactory}) : _factory = factory;
  final TvtWebFactory _factory;

  Future<NvrSetupResult> run({
    required String host,
    required int httpPort,
    required Credentials credentials,
    required bool allowEnableRtsp,
  }) async {
    final web = _factory(host, httpPort, credentials);
    try {
      await web.login();
      var channels = const <TvtChannel>[];
      try {
        channels = await web.channels();
      } on TvtWebException catch (e) {
        Log.w('setup', 'channel list unavailable: $e');
      }
      var rtsp = const TvtRtspServer(enabled: true, port: 554, authType: 'Digest', anonymous: false);
      try {
        rtsp = await web.rtspServer();
      } on TvtWebException catch (e) {
        // Some firmware hides the RTSP page from non-admin users; assume on.
        Log.w('setup', 'RTSP settings unavailable: $e');
      }
      var enabledNow = false;
      if (!rtsp.enabled) {
        if (!allowEnableRtsp) {
          throw NvrSetupException('The NVR\'s video service (RTSP) is switched off.', needsRtsp: true);
        }
        await web.enableRtsp(port: rtsp.port, authType: rtsp.authType);
        enabledNow = true;
        Log.w('setup', 'RTSP service enabled on the NVR at user request');
      }
      return NvrSetupResult(
        channels: channels,
        rtspPort: rtsp.port,
        httpPort: httpPort,
        rtspWasEnabled: enabledNow,
      );
    } on TvtWebException catch (e) {
      if (e.unreachable || e.notTvt) throw NvrSetupException(e.message, unreachable: true);
      if (e.authFailure) throw NvrSetupException(e.message, authFailure: true);
      throw NvrSetupException('NVR web interface error: $e');
    } finally {
      web.close();
    }
  }
}
