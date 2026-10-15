import 'dart:async';
import 'dart:io';

/// Raw TCP reachability check — cheaper and more honest than ICMP, which
/// many NVRs and mobile networks drop.
typedef TcpProbe = Future<Duration?> Function(String host, int port, Duration timeout);

Future<Duration?> defaultTcpProbe(String host, int port, Duration timeout) async {
  final sw = Stopwatch()..start();
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
    return sw.elapsed;
  } on SocketException {
    return null;
  } on TimeoutException {
    return null;
  }
}

/// RFC 1918 / RFC 4193 / link-local / CGNAT check used to label a route as
/// LAN even when the user typed a hostname that resolves locally.
bool isPrivateAddress(InternetAddress a) {
  if (a.isLoopback || a.isLinkLocal) return true;
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
  }
  return (b[0] & 0xfe) == 0xfc; // fc00::/7 unique local
}
