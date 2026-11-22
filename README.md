# Keyboard Handoff

Send a Bluetooth Magic Keyboard between two awake Macs with the same shortcut on either Mac. Both Macs need macOS 14 or later and should be on the same local network.

## Build

Use Xcode or Command Line Tools with Swift 6.

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

## Verify and release

Run `./test.sh` to check the handoff messages over a local TLS connection and verify that a different peer key is rejected.

The bundle uses semantic versions in `Info.plist`. Tag the matching commit with a `v` prefix, such as `v0.1.0`.
