import 'dart:io';

/// LAN IPv4 addresses a PC could use to reach this phone, Wi-Fi first, then hotspot.
/// Cellular interfaces are skipped since a PC can't reach the phone through them.
Future<List<String>> localIpAddresses() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  int rank(NetworkInterface i) {
    final name = i.name.toLowerCase();
    if (name.startsWith('wlan')) return 0;
    if (name.startsWith('ap') || name.startsWith('swlan')) return 1;
    if (name.startsWith('eth')) return 2;
    return 3;
  }

  final usable = interfaces.where((i) {
    final name = i.name.toLowerCase();
    return !name.startsWith('rmnet') && !name.startsWith('ccmni') && !name.startsWith('lo');
  }).toList()
    ..sort((a, b) => rank(a).compareTo(rank(b)));

  return [
    for (final i in usable)
      for (final a in i.addresses)
        if (!a.isLoopback && !a.isLinkLocal) a.address,
  ];
}
