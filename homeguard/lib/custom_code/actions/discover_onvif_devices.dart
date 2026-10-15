// FlutterFlow custom action: "discoverOnvifDevices"
// Return type: List<JSON> — [{ip, label, xaddr}].
//
// WS-Discovery multicast probe (UDP 239.255.255.250:3702) on the LAN.
// Requires the iOS multicast entitlement (com.apple.developer.networking.multicast).

import '../../core/onvif/onvif_client.dart';

Future<List<dynamic>> discoverOnvifDevices() async {
  final devices = await Onvif.discover();
  return devices
      .map((d) => {'ip': d.address.address, 'label': d.label, 'xaddr': d.xaddrs.first.toString()})
      .toList();
}
