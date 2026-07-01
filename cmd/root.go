package cmd

import (
	"fmt"
	"io"
	"os"
	"runtime/debug"
	"strings"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func appVersion() string {
	info, ok := debug.ReadBuildInfo()
	if !ok || info.Main.Version == "" || info.Main.Version == "(devel)" {
		return "dev"
	}
	return info.Main.Version
}

// Option configures a root command. Used for test injection.
type Option func(*rootOpts)

type rootOpts struct {
	store    *state.Store
	client   *tmux.Client
	repoRoot string
}

// WithDeps injects the state store and tmux client (used in tests).
func WithDeps(store *state.Store, client *tmux.Client) Option {
	return func(o *rootOpts) {
		o.store = store
		o.client = client
	}
}

// NewRootCmd creates the root cobra command.
func NewRootCmd(opts ...Option) *cobra.Command {
	var o rootOpts
	for _, apply := range opts {
		apply(&o)
	}

	// Lazy-init defaults for production use.
	// OpenStore (no MkdirAll) keeps read-only commands safe to run
	// when the state directory does not yet exist.
	if o.store == nil {
		o.store = state.OpenStore(state.StateRoot())
	}
	if o.client == nil {
		o.client = tmux.NewExecClient()
	}
	if o.repoRoot == "" {
		o.repoRoot = os.Getenv("PARTY_REPO_ROOT")
	}

	root := &cobra.Command{
		Use:   "questmaster",
		Short: "CLI for questmaster sessions",
		Long: `questmaster is the shared implementation surface for questmaster sessions.

When invoked with no subcommand, it shows help.`,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return cmd.Help()
		},
	}

	root.AddCommand(newVersionCmd())
	root.AddCommand(newListCmd(o.store, o.client))
	root.AddCommand(newSessionsCmd(o.store, o.client))
	root.AddCommand(newStatusCmd(o.store, o.client))
	root.AddCommand(newPruneCmd(o.store, o.client))
	root.AddCommand(newStartCmd(o.store, o.client, o.repoRoot))
	root.AddCommand(newContinueCmd(o.store, o.client, o.repoRoot))
	root.AddCommand(newDeleteCmd(o.store, o.client, o.repoRoot))
	root.AddCommand(newPromoteCmd(o.store, o.client, o.repoRoot))
	root.AddCommand(newSpawnCmd(o.store, o.client, o.repoRoot))
	root.AddCommand(newRelayCmd(o.store, o.client))
	root.AddCommand(newBroadcastCmd(o.store, o.client))
	root.AddCommand(newReadCmd(o.store, o.client))
	root.AddCommand(newReportCmd(o.store, o.client))
	root.AddCommand(newWorkersCmd(o.store, o.client))
	root.AddCommand(newAgentCmd())
	root.AddCommand(newHookCmd(o.store, o.client))
	root.AddCommand(newHooksCmd())
	root.AddCommand(newStateCmd(o.store))
	root.AddCommand(newArtifactCmd(o.client))
	root.AddCommand(newSessionCmd(o.store, o.client, o.repoRoot))
	root.AddCommand(newRepoCmd(o.store))
	root.AddCommand(newServeCmd(o.store, o.client))
	root.AddCommand(newFocusCmd())

	return root
}

func newVersionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print the questmaster version",
		RunE: func(cmd *cobra.Command, _ []string) error {
			fmt.Fprintf(cmd.OutOrStdout(), "questmaster %s\n", appVersion())
			return nil
		},
	}
}

// Execute runs the root command.
func Execute() error {
	return executeWithArgs(
		os.Args[1:],
		os.Stdin,
		os.Stdout,
		os.Stderr,
		func() *cobra.Command { return NewRootCmd() },
	)
}

func executeWithArgs(args []string, in io.Reader, out, stderr io.Writer, rootFactory func() *cobra.Command) error {
	if isHookInvocation(args) {
		if handled, err := executeHookFastPath(args[1:], in, stderr); handled {
			return err
		}
	}
	root := rootFactory()
	root.SetArgs(args)
	root.SetIn(in)
	root.SetOut(out)
	root.SetErr(stderr)
	return root.Execute()
}

func isHookInvocation(args []string) bool {
	return len(args) > 0 && args[0] == "hook"
}

func executeHookFastPath(args []string, in io.Reader, stderr io.Writer) (bool, error) {
	var session string
	positionals := make([]string, 0, 2)
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--help" || arg == "-h":
			return false, nil
		case arg == "--session":
			if i+1 >= len(args) {
				return false, nil
			}
			i++
			session = args[i]
		case strings.HasPrefix(arg, "--session="):
			session = strings.TrimPrefix(arg, "--session=")
		case arg == "--":
			positionals = append(positionals, args[i+1:]...)
			i = len(args)
		case strings.HasPrefix(arg, "-"):
			return false, nil
		default:
			positionals = append(positionals, arg)
		}
	}
	if len(positionals) != 2 {
		return false, nil
	}

	opts := hookOptions{agent: positionals[0], action: positionals[1], session: session}
	if data, err := readStdinNonBlocking(in); err == nil {
		opts.stdin = data
	}
	runHook(defaultHookRunner(), opts, stderr)
	return true, nil
}
