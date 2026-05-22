# Migrating from `party-cli`

This page only applies if you already used the legacy `party-cli` tool before installing `questmaster`.

After installing `questmaster`, run the hook installer once:

```sh
questmaster hooks install --dry-run
questmaster hooks install
```

The installer copies `~/.party-state` to `~/.questmaster-state` and `~/.config/party-cli/` to `~/.config/questmaster/` when the new paths do not already exist.

Old directories are preserved with a `.moved-to-questmaster` marker. Pristine legacy hook scripts are removed; edited legacy scripts are preserved as `.bak.YYYYMMDD` files.

Restart existing legacy tmux sessions after migration.
