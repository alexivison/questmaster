![Questmaster's eleven classes gathered in a ruined forest courtyard](assets/banner.png)

# Questmaster

Questmaster is a native macOS workspace for AI coding agents, backed by a Go CLI
and tmux. Master sessions coordinate workers, while the app brings their
terminals, messages, quests, pull requests, and artifacts together.

Each master has one of eleven fantasy classes, with its own animated avatar and
voice.

## Install the macOS app

The app currently builds from source. You need an **Apple Silicon Mac running
macOS 14 or later**, Apple's Command Line Tools, Go 1.25.7 or newer, and tmux.
You also need at least one supported coding agent installed and configured:
Claude Code, Codex, or Pi.

1. Install Apple's Command Line Tools, if needed:

   ```sh
   xcode-select --install
   ```

   Finish the installer before continuing. If the tools are already installed,
   macOS will say so.

2. With [Homebrew](https://brew.sh) installed, install the build and session tools:

   ```sh
   brew install go tmux
   ```

3. Download Questmaster and build the app:

   ```sh
   git clone https://github.com/alexivison/questmaster.git
   cd questmaster
   app/Scripts/build-app.sh
   ```

   The first build downloads dependencies and can take several minutes. The
   script checks prerequisites first, then installs **Questmaster.app** in
   **Applications**.

To update later, run `git pull --ff-only` in the repository, then run
`app/Scripts/build-app.sh` again.

## Open Questmaster

Open **Questmaster** from **Applications**, or press **Command+Space**, type
**Questmaster**, and press Return. You can keep it in the Dock like any other
Mac app.

In the app, press **Command+N** to create a session, choose your project folder
and installed agent, and enter a prompt.

### About `questmaster` and `qm`

These are command-line tools for managing sessions. Running either without a
subcommand shows CLI help. Open the native app from Applications or Spotlight.

The installer puts the CLI at `~/.local/bin/questmaster`; inside managed
sessions, both `questmaster` and `qm` are available. Using the app does not
require adding either command to your shell's `PATH`.

## Development

Build the backend with Go 1.25.7 or newer:

```sh
go build -buildvcs=false ./...
```

Running sessions requires tmux and an installed agent harness. The native app
targets macOS 14 or later. See [AGENTS.md](AGENTS.md) for app build instructions,
verification commands, and development guidelines.
