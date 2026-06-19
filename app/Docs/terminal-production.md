# Terminal production notes

## Ghostty config

The libghostty engine is mounted through `TerminalPaneHosting` and uses the
vendored GhosttyKit host. `GhosttyTerminalHost` calls Ghostty's
`ghostty_config_load_default_files`, explicitly loads Ghostty's resolved
`ghostty_config_open_path` when that file is readable, then calls
`ghostty_config_load_recursive_files`, so the embedded surface reads the user's
real Ghostty config directly from:

```text
~/.config/ghostty/config
```

That means font, palette or theme, padding, cursor, and other supported Ghostty
settings are applied by libghostty itself. Questmaster does not keep a static
mapping of those settings. Questmaster creates its embedded Ghostty host with
GhosttyKit's managed fallback theme disabled so the user's palette is not
overridden. If the file is absent, libghostty falls back to its defaults.

On startup the app logs the resolved config path, readability, and any libghostty
config diagnostics. A healthy load looks like:

```text
Ghostty config path: /Users/aleksi.tuominen/.config/ghostty/config readable=true
Ghostty config diagnostics: none
```

Keybind parity is intentionally out of scope for P2. The user's tmux and
vim-tmux-navigator config remains the source of truth for terminal key behavior.

## tmux launch

The GhosttyKit path starts tmux through shell startup, not keystroke injection.
Questmaster asks libghostty to start its normal login shell, with a temporary
`ZDOTDIR` that contains a minimal `.zprofile`. That profile immediately execs a
generated script which:

- Writes an optional environment dump when `QUESTMASTER_TERMINAL_ENV_DUMP` is set.
- Syncs `HOME`, `XDG_CONFIG_HOME`, `PATH`, `SHELL`, locale, and Questmaster
  focus variables into tmux global environment.
- Syncs the same keys into the target session when it already exists.
- Removes the temporary `ZDOTDIR` and startup-script variables from tmux.
- Execs `tmux new-session -A -s <session>`.

This keeps the app-owned terminal hosting the tmux session while avoiding the
old `exec tmux ...` input path. It also repairs stale tmux server or session
environment so tools inside tmux, including NeoVim, see the real user
`~/.config` path.

SwiftTerm remains a selectable fallback and still launches tmux directly through
its PTY process API.

## Vendored GhosttyKit provenance

The app vendors GhosttyKit in:

```text
app/Vendor/GhosttyKit-0.8.0
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
app/Vendor/GhosttyKit-0.8.0/Vendor/libghostty.version
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
rsync -a --delete Sources/CGhosttyKitBinary/ /path/to/questmaster/app/Vendor/GhosttyKit-0.8.0/Sources/CGhosttyKitBinary/
rsync -a --delete Sources/GhosttyKitExports/ /path/to/questmaster/app/Vendor/GhosttyKit-0.8.0/Sources/GhosttyKitExports/
rsync -a --delete Vendor/GhosttyKit.xcframework/ /path/to/questmaster/app/Vendor/GhosttyKit-0.8.0/Vendor/GhosttyKit.xcframework/
cp Vendor/GhosttyKit.checksum Vendor/libghostty.version /path/to/questmaster/app/Vendor/GhosttyKit-0.8.0/Vendor/
```

Then run:

```sh
swift build --package-path app
```

If Ghostty ships an official libghostty distribution, replace the local
`CGhosttyKitBinary` binary target in `app/Package.swift` with
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
