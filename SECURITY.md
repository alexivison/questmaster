# Security Policy

## Supported versions

Until the first standalone release, security fixes target the default branch only. After tagged releases begin, this policy should be updated with supported version ranges.

## Reporting a vulnerability

Please do not open a public issue for suspected vulnerabilities.

Report privately through GitHub's private vulnerability reporting if available for the standalone repository. If that is not available yet, contact the maintainer through a private channel and include:

- Affected version or commit.
- Steps to reproduce.
- Impact and any known workarounds.
- Whether the issue has been disclosed elsewhere.

## Scope

Security-sensitive areas include generated shell hooks, tmux command construction, filesystem writes under user config/state directories, and handling of agent-provided text that may be relayed into other panes.
