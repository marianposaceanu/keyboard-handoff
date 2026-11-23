# Releasing Keyboard Handoff

1. Set the semantic version and build number in `Info.plist` and the corresponding version settings in the Xcode project.
2. Run `scripts/check.sh`. Check the menu, hidden-icon shortcut, incoming and outgoing handoffs, and stopping the core on two Macs.
3. Commit on `main` and create an annotated tag matching the bundle version, for example `git tag -a v0.2.0 -m "Keyboard Handoff 0.2.0"`.
4. Push the commit and tag. The release workflow checks the tag, runs the tests, and creates a draft release with a universal app ZIP and SHA-256 checksum.
5. Verify the draft assets with `shasum -a 256 -c SHA256SUMS.txt` and record the hardware acceptance results before publishing the draft.

To reproduce the package at a tagged checkout, run `scripts/package.sh v0.2.0`. Output goes under `dist/v0.2.0/`. These builds use local ad hoc signatures. Developer ID signing and Apple notarization are separate distribution steps.

When upgrading from 0.1.0, quit the original app before opening the replacement. For later updates use **Stop Handoff & Quit** so the next launch starts the bundled core. The original preference domain and local identity location are preserved.
