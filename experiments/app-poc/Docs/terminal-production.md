# Terminal production notes

## Ghostty config

The libghostty engine is mounted through `TerminalPaneHosting` and uses the
vendored GhosttyKit host. `GhosttyTerminalHost` calls Ghostty's
`ghostty_config_load_default_files` and `ghostty_config_load_recursive_files`,
so the embedded surface reads the user's real Ghostty config directly from:

```text
~/.config/ghostty/config
```

That means font, palette or theme, padding, cursor, and other supported Ghostty
settings are applied by libghostty itself. Questmaster does not keep a static
mapping of those settings. If the file is absent, GhosttyKit falls back to
Ghostty defaults plus its readable managed default theme.

Keybind parity is intentionally out of scope for P2. The user's tmux and
vim-tmux-navigator config remains the source of truth for terminal key behavior.

## tmux launch

The GhosttyKit path starts tmux through
`GhosttyTerminalLaunchConfiguration.command`, which GhosttyKit passes to
`ghostty_surface_config_s.command` before `ghostty_surface_new`. The app no
longer types `exec tmux ...` into the terminal after startup.

SwiftTerm remains a selectable fallback and still launches tmux directly through
its PTY process API.

## Vendored GhosttyKit provenance

The app vendors GhosttyKit in:

```text
experiments/app-poc/Vendor/GhosttyKit-0.8.0
```

Recorded pin:

```text
GhosttyKit repo: https://github.com/briannadoubt/GhosttyKit.git
GhosttyKit version: 0.8.0
GhosttyKit revision: 92a5e413565e8a5f5d19814a56882cb781555e5a
Vendored XCFramework checksum: ecb127cde29155a8dc3ab0ab45f818863bfcfc1cab4d2a645973b72b9625b544
Upstream Ghostty ref: 0071971b5
Upstream Ghostty commit: 0071971b577c6ef6396cfe99684b466757bf0ef9
Zig version used by the artifact: 0.15.2
Artifact updated at: 2026-05-15T09:49:44Z
```

The vendored Swift wrapper source has a local Swift 6.3 compatibility patch that
moves main-actor default construction out of default argument expressions. The
XCFramework, C headers, and upstream libghostty binary provenance above are
unchanged.

The authoritative upstream provenance file is:

```text
experiments/app-poc/Vendor/GhosttyKit-0.8.0/Vendor/libghostty.version
```

## Rebuild recipe

Rebuild the artifact in a clean GhosttyKit checkout, then copy the generated
wrapper files back into this vendored directory.

```sh
git clone https://github.com/briannadoubt/GhosttyKit.git /tmp/GhosttyKit
cd /tmp/GhosttyKit
git checkout 92a5e413565e8a5f5d19814a56882cb781555e5a
git submodule update --init --recursive
```

Install Zig `0.15.2`, matching `Vendor/libghostty.version`, then rebuild the
same upstream Ghostty commit:

```sh
./Scripts/update-libghostty.sh --ref 0071971b577c6ef6396cfe99684b466757bf0ef9
swift build
```

Copy the refreshed files into Questmaster:

```sh
rsync -a --delete Sources/CGhosttyKitBinary/ /path/to/questmaster/experiments/app-poc/Vendor/GhosttyKit-0.8.0/Sources/CGhosttyKitBinary/
rsync -a --delete Sources/GhosttyKitExports/ /path/to/questmaster/experiments/app-poc/Vendor/GhosttyKit-0.8.0/Sources/GhosttyKitExports/
rsync -a --delete Vendor/GhosttyKit.xcframework/ /path/to/questmaster/experiments/app-poc/Vendor/GhosttyKit-0.8.0/Vendor/GhosttyKit.xcframework/
cp Vendor/GhosttyKit.checksum Vendor/libghostty.version /path/to/questmaster/experiments/app-poc/Vendor/GhosttyKit-0.8.0/Vendor/
```

Then run:

```sh
swift build --package-path experiments/app-poc
```

If Ghostty ships an official libghostty distribution, replace the local
`CGhosttyKitBinary` binary target in `experiments/app-poc/Package.swift` with
the official package or binary target, keep the `TerminalPaneHosting` seam, and
delete this community artifact after the app builds and the IME gate below
passes.

## SwiftTerm retirement gate

SwiftTerm must remain selectable until the libghostty path passes the full IME
bar in the real workflow: Japanese composition with Kotoeri in NeoVim insert
mode, inside tmux, inside the embedded terminal surface.

The gate is:

- Live preedit appears at the cursor, not at the screen origin.
- The candidate window appears at the cursor.
- Commit reaches the shell and agent.
- Preedit follows the cursor across scroll.
- Backspace edits the active composition.
- Esc disambiguates IME cancel from Vim escape correctly.
- No characters are dropped or doubled.

P2 preserved GhosttyKit's `NSTextInputClient` path in
`GhosttyTerminalView.setMarkedText`, `unmarkText`, `firstRect`, and
`insertText`. Manual verification is still required after each libghostty
artifact refresh before SwiftTerm can be removed.
