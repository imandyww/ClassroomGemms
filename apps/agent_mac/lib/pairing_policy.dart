import 'package:lan_transport/lan_transport.dart';

/// Mobile senders are voice remotes in this demo: they can forward intents to
/// the Mac but cannot receive them. Auto-trusting that first request avoids a
/// hidden pairing dialog from blocking execution when the phone sends a command.
bool shouldAutoTrustIncomingPeer(LanPeer candidate) {
  return candidate.deviceType == 'mobile' && !candidate.acceptsIntents;
}
