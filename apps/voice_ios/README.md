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

## Demo-mode preloaded Gemma

For the macOS + iOS Simulator demo flow, use the repo-level commands from the
workspace root instead of `flutter run`:

```sh
./preload_gemma_demo.command
./run_gemma_demo.command
```

That flow builds `voice_ios` with:

- `VOICE_AGENT_DEMO_MODE=true`
- `VOICE_AGENT_DEMO_ROOT=/absolute/path/to/.demo-models`

The simulator app then loads `gemma-4-e2b-it` from its own sandbox copy at:

```text
Library/Application Support/gemma4_demo/gemma-4-e2b-it
```

If that copy is missing or invalid, demo mode fails loudly and points back to
`./preload_gemma_demo.command` instead of downloading a fallback model.

## Pairing with the Mac

The iPhone discovers `agent_mac` via mDNS / multicast UDP on UDP/53317 and sends
intents to TCP/53317. Both devices must be on the same Wi-Fi network.

### Discovery fallback

The iOS Simulator's network stack runs through the host Mac's loopback, so
multicast UDP packets sent by the Simulator do **not** reach the host Mac's
real-Wi-Fi interface, and the Simulator never sees the Mac's multicast
beacons.

To make development more reliable, `voice_ios` now falls back to a local-subnet
HTTP scan against `http://<candidate>:53317/api/localsend/v2/info` whenever it
does not find a Mac quickly over multicast. You can also tap **Scan LAN** or
paste a specific IP into **Mac IP** and tap **Add**.

That fallback helps in two common cases:

- the iOS Simulator, where multicast does not cross the Simulator boundary
- physical iPhones running a dev build where Local Network permission has not
  been granted yet or multicast is unavailable

### Local HTTP

iOS 14+ blocks plain-HTTP traffic by default (App Transport Security). The
LAN protocol uses `http://192.168.x.x:53317`, so `Info.plist` enables
`NSAppTransportSecurity → NSAllowsLocalNetworking = true` to whitelist
RFC 1918 / link-local destinations.
