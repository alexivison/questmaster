# Artifact lifecycle redesign

## Intent

A session's finished artifact should appear in Questmaster without a separate registration reminder. The same artifact should be linkable to several sessions. The artifact panel should also open the selected file in its external tool with `o`.

## Current behavior and constraints

- Agents create files with ordinary tools and then run `questmaster artifact add <path>`. The bundled guide describes registration as a separate step.
- The root registry is keyed by path and stores one `session_id`. Adding that path from another session replaces its owner. Per-session sidecars and the Go/Swift tracker snapshots repeat this one-owner shape.
- The daemon watches the registry and pushes snapshots to the app. It does not create or attribute files. Sessions may share a working directory, so watching writes there cannot reliably identify an author.
- Artifact files may currently live anywhere. A project is assigned from the registering session's working directory, even if the artifact path is in a different repository. The app identifies an artifact by path.

## Goals

1. A single agent-facing creation operation writes or imports a file and registers it to the creating session as one successful action.
2. One artifact record can be linked to many sessions; linking never transfers another session's link.
3. Project grouping is independent of session links and follows the artifact's source repository when one exists.
4. The app's `o` key opens an artifact in its external tool; Return continues to open the in-app viewer.
5. Delete permanently removes the file and its registration from every session, from any artifact view.
6. Existing registered artifacts migrate without losing their paths, labels, or session associations.

## Non-goals and anti-goals

- No daemon scan of working directories or passive registration of arbitrary source files.
- No session name in an artifact's canonical storage path.
- Do not make a mere session unlink delete file bytes. Delete is a separate permanent action that removes the file and every link.
- Do not make linking a file copy it. Two sessions must refer to the same artifact record and file.

## Approaches

1. **Daemon librarian:** watch output files and infer the creator from filesystem activity. This needs broad watches and cannot attribute writes when sessions share a directory. Rejected.
2. **Command-owned lifecycle (chosen):** `artifact create` writes or imports the artifact and records the creating session in the same command; `artifact add` links an existing artifact to any chosen session. Reliable attribution and no background discovery are needed.
3. **Agent write hooks:** inspect tool events and auto-register likely files. This misses files made inside arbitrary shell commands and differs across agent harnesses. Rejected.

## Artifact model

The root registry has one record per artifact: stable ID, canonical path, kind, label, creation time, origin project ID, optional creator session ID, and a set of linked session IDs. The ID is independent of the path so a later path update does not change the artifact's identity. A link is a relationship, not ownership; the creator remains provenance only.

The Session tab and each session snapshot include records whose link set contains that session. The All tab shows each artifact once. The Project scope groups by origin project ID. A session from another project may link an artifact and see it in its Session tab while the artifact stays grouped with its origin project. An artifact with no resolvable repository uses the creating session's project; if neither resolves, it is ungrouped.

Migrate each legacy `session_id` into a one-element link set, retaining the existing path and metadata. Keep old sidecars readable during migration. Update the Go/Swift wire fixtures together and bump the protocol version if the new membership representation changes decoder requirements.

## Commands and storage

`questmaster artifact create <name> [--label <label>]` creates a new artifact linked to the current session. Text content is read from standard input. `--from <source-path>` imports an existing file, including a binary image, into the same managed location. It returns the artifact ID and final path. The command needs a valid session and never registers a partially written file: it writes a temporary file, publishes it, then commits the registry record; on registration failure it removes the new managed file.

New artifacts live in a Questmaster-managed project library under the state root, using a stable project key and artifact ID rather than a session ID. This keeps generated outputs together without making the creator their physical owner. The project comes from the source path's Git repository when importing; otherwise from the creating session's repository. A generated text artifact uses the session project. Names are sanitized and collisions get separate artifact IDs. Existing files registered with `artifact add` stay at their current path; no migration copies or moves them.

`questmaster artifact add <path-or-id> [--session <id>]` registers an existing file or adds a session link to an existing record. It defaults to the current session. An existing artifact ID preserves its metadata; a new path infers project from its path, falling back to the target session's project. Repeating the same link is idempotent. `artifact rm` in session scope removes only that link; an explicit global remove unregisters the record without deleting bytes, preserving the existing CLI behavior. A separate `artifact delete` permanently deletes the file and globally removes the record and every link, matching Delete in the app. The agent guide tells agents to use `create` for new deliverables and `add` for already existing files or sharing.

## App behavior

`o` acts on the keyboard cursor in the artifact list and on the current artifact in the viewer. Return and clicks retain the existing in-app viewing behavior. Markdown launches the currently attached session's `$EDITOR` in a new tmux window within that session, using a login shell so terminal editors have a terminal and the agent pane stays intact. The window closes when the editor exits, returning to the agent's window; graphical editor commands can launch from there too. HTML opens in the default browser, images in Preview, and other kinds in the system's default application. Missing files do not launch an app and show a useful error. The external opener uses the file's actual type/path rather than a user-supplied kind override when choosing an application.

Delete from Session, Project, or All always means the same permanent operation: remove the file from disk, unregister its artifact record, and remove it from every linked session. The existing confirmation must say that the file itself will be deleted, show its path, and make the action's global effect clear. The backend performs the delete; on a disk error it leaves the registration intact and reports the error. Registration-only removal remains available through the CLI `artifact rm`. The app does not expose unlink as Delete.

The app's Core layer decides whether the command is available and what opening intent it represents. The App target performs macOS and tmux I/O. All added key bindings and wire fields receive focused Core, Go, and app contract tests.

## Builder decisions and verification

- Preserve old registration paths and labels; apply managed placement only to new `create` calls.
- Do not infer artifact status from extension alone. The agent deliberately calls `create` or `add`.
- Make creation and linking safe under concurrent sessions through the existing registry lock.
- Verify text and binary creation, failed registration cleanup, project inference, migration, link/unlink behavior, permanent deletion and failure handling, session and project views, the `o` key, and all Go/Swift contract fixtures.
- Run the repository's Go build, vet, and tests and the macOS app build and logic tests. The change spans backend and app contract code, so plan reviewable PR slices after approval.
