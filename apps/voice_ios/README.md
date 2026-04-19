# voice_ios

iOS app that records a voice command, transcribes it on-device, and forwards the
intent to a paired Mac running `agent_mac` over the LAN.

## Running

From the workspace root:

```sh
./rebuild_both.command            # rebuild Mac + iOS, then `flutter run -d 'iPhone'`
SKIP_IOS=1 ./rebuild_both.command # Mac only
```

Or directly:

```sh
cd apps/voice_ios
flutter run -d 'iPhone'   # physical iPhone
flutter run -d 'iPhone 17 Pro Max'  # Simulator (use any booted device's name)
```

## Pairing with the Mac

The iPhone discovers `agent_mac` via mDNS / multicast UDP on UDP/53317 and sends
intents to TCP/53317. Both devices must be on the same Wi-Fi network.

### iOS Simulator caveat

The iOS Simulator's network stack runs through the host Mac's loopback, so
multicast UDP packets sent by the Simulator do **not** reach the host Mac's
real-Wi-Fi interface, and the Simulator never sees the Mac's multicast
beacons.

Workaround: in the Simulator app, look at the agent_mac UI for the **LAN IPs
(type one on iPhone if Simulator)** section, copy one of those IPs (e.g.
`192.168.2.1`), and paste it into the **Mac IP** field on the iOS app, then tap
**Add**. That manually injects the Mac as a peer over unicast. Discovery on a
real iPhone over the same Wi-Fi (or a tethered hotspot) does not need this
workaround — multicast works there.

### Local HTTP

iOS 14+ blocks plain-HTTP traffic by default (App Transport Security). The
LAN protocol uses `http://192.168.x.x:53317`, so `Info.plist` enables
`NSAppTransportSecurity → NSAllowsLocalNetworking = true` to whitelist
RFC 1918 / link-local destinations.
