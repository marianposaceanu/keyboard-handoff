# Contributing

Build with Swift 6 on macOS. Run `scripts/check.sh` before submitting changes. The core lifecycle fixture uses a temporary socket and skips hardware discovery and shortcut registration.

Use a Conventional Commit title such as `fix(core): recover a failed transfer`. Enable the local hook with `git config core.hooksPath .githooks`. CI also checks the pull request title and commit history.

Keep Bluetooth operations and peer trust in the core. The UI and CLI use the same local command protocol. Changes to the menu icon should update the ready/sending preview in the README.
