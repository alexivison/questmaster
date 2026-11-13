// Package tmux is the explicit tmux command boundary used by Questmaster.
//
// Production calls run through a Server that names a -L label or -S socket and
// strips TMUX, TMUX_PANE, and TMUX_TMPDIR from the command environment. Those
// variables describe the caller's tmux context and must not choose the target.
// New sessions use DefaultServer; callers acting on an existing session route
// its recorded tmux_server through tmuxroute.
//
// Use SessionTarget for commands addressed to a session: bare tmux names match
// prefixes, and the colon is required by commands that target a pane. NewSession
// returns the new pane ID; keep using that ID for agent-pane operations instead
// of assuming a window or pane index, since server base indexes are configurable.
package tmux
