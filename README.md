# Keyboard Handoff

Send a Bluetooth Magic Keyboard between two awake Macs with the same shortcut on either Mac. Both Macs need macOS 14 or later and should be on the same local network.

![Keyboard Handoff menu bar icon in its ready and sending states](docs/status-icons.png)

The keyboard icon opens a native AppKit menu. **Hide Menu Bar Icon** closes that interface while the background core continues listening for incoming keyboards and handling **⌃⌥⌘K**. Reopen the app to bring the menu back. **Stop Handoff & Quit** ends both processes.

[Contributing](CONTRIBUTING.md) · [Releases](RELEASING.md) · [CI](https://github.com/marianposaceanu/keyboard-handoff/actions/workflows/ci.yml)

## Architecture

```text
    AppKit menu          keyboard-handoff-core <command>
         │                         │
         └────────────┬────────────┘
              same-user Unix socket
                      │
       keyboard-handoff-core on this Mac
         │                        │
      Bluetooth                local network
         │                 Bonjour + authenticated TLS
    Magic Keyboard                │
                        core on the other Mac
```

The core owns keyboard selection, peer trust, Bluetooth pairing, and the global shortcut. The menu and CLI send versioned requests over a private socket. Closing either client leaves the core running. The keyboard gets re-paired with the destination Mac after it accepts the offer.

## Build

Open `KeyboardHandoff.xcodeproj`, select **KeyboardHandoff → My Mac**, and press **⌘R**. To build a universal app for both Macs from the terminal, use Command Line Tools or Xcode with Swift 6.

```sh
./build.sh
```

Copy `.build/Keyboard Handoff.app` to the other Mac. The bundle supports Apple silicon and Intel. The build uses an ad hoc signature for local use. If macOS asks you to approve opening your copy, use Privacy & Security → Open Anyway. [Apple’s instructions](https://support.apple.com/en-us/102445)

## Set up

1. Open the app on both Macs and allow Bluetooth and Local Network access when macOS asks.
2. Click the keyboard icon in each Mac’s menu bar and choose **Trust** beside the name of your other Mac.
3. Unplug the Magic Keyboard’s USB cable. On the Mac it connects to over Bluetooth, use **Choose Keyboard** in the app to select it.
4. Press **⌃⌥⌘K** on the Mac you’re typing on or choose **Send to** from its menu. The receiving Mac remembers the keyboard, so the same shortcut sends it back.

Wake the clamshell Mac with its mouse if it’s asleep. If a failed handoff leaves the keyboard disconnected, plug it into the Mac you want to use and unplug it after it pairs. [Apple’s Bluetooth pairing instructions](https://support.apple.com/en-us/119917)

## How it works

Each Mac generates a local identity. The initial approval trusts the public key advertised by the Mac name you select in Bonjour. Later connections authenticate with TLS using a key the two Macs derive automatically. Keystrokes go directly to the Mac connected to the keyboard over Bluetooth.

The sending Mac waits for the other Mac to accept before releasing the keyboard. If the receiver confirms that it couldn’t connect, the sender attempts to recover the keyboard. macOS exposes pairing through IOBluetooth and the app uses an undocumented IOBluetooth selector to forget the keyboard on the sending Mac. A macOS update can affect this behavior. [Apple’s pairing API](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevicepair)

## Command line

The bundled core also acts as a client. With the app in Applications, use these commands from Terminal.

```sh
core="/Applications/Keyboard Handoff.app/Contents/MacOS/keyboard-handoff-core"
"$core" status
"$core" send
"$core" stop
```

| Command | Effect |
| --- | --- |
| `status` | Prints the running core’s snapshot as JSON, or reports that it is stopped. |
| `send` | Requests a transfer to the trusted Mac. Check `status` for the outcome. |
| `stop` | Stops an idle core. Choose **Reconnect to Core** or reopen the app to start it again. |

## Verification

Run `scripts/check.sh` for peer-authentication tests, an isolated core/CLI lifecycle check, and verification of the signed universal bundle. A physical acceptance test requires two Macs and the wireless keyboard. Send it in both directions, type on each destination, hide the icon, then send again with the global shortcut.
