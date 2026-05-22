# Contributing

Thanks for your interest in improving `party-cli`.

## Development setup

Prerequisites:

- Go 1.25.x-capable toolchain
- `tmux`
- Any agent CLI needed for manual testing (`claude`, `codex`, `pi`, etc.)

From this directory:

```sh
go mod tidy
go build -buildvcs=false ./...
go test ./...
go vet ./...
```

## Pull requests

- Keep changes focused and reviewable.
- Add or update tests for behavior changes.
- Preserve the current `party-cli` binary name unless a change explicitly covers migration and compatibility.
- Include verification output in the PR description.

## Reporting issues

Use the bug or feature templates under `.github/ISSUE_TEMPLATE/`. Include OS, Go version, `party-cli version`, `tmux -V`, and relevant command output for bugs.
