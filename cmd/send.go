package cmd

import (
	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newSendCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	var messageFile string
	var steer bool
	cmd := &cobra.Command{
		Use:   "send <recipient|master|all> [message]",
		Short: "Send to a session, report to your master, or broadcast to workers",
		Long: `Send a message using one recipient form:

  questmaster send <session-id> "message"  Send directly to a session
  questmaster send master "message"        Worker report to its parent
  questmaster send all "message"           Master broadcast to its workers

Use the default Codex queue when a message can wait for the next turn; use
--steer for a mid-turn correction.
If the daemon is running but no active turn can be steered, --steer falls back to the queue.
If Codex's daemon is unavailable, the existing tmux fallback applies.
Use --message-file <path> or --message-file - for file or stdin input.

For Claude, Pi, and tmux targets, --steer keeps the existing transport behavior.`,
		Args: cobra.RangeArgs(1, 2),
		RunE: func(cmd *cobra.Command, args []string) error {
			text, err := messageFromArgsAndFile(cmd, args[1:], messageFile)
			if err != nil {
				return err
			}
			ctx := cmd.Context()
			recipient := args[0]
			svc := message.NewService(store, client)
			svc.Steer = steer
			switch recipient {
			case "master":
				sender, err := discoverSession(ctx, client)
				if err != nil {
					return err
				}
				if err := svc.Report(ctx, sender, text); err != nil {
					return err
				}
			case "all":
				master, err := discoverMasterSession(ctx, store, client)
				if err != nil {
					return err
				}
				result, err := svc.BroadcastFrom(ctx, master, master, text)
				if err != nil {
					return err
				}
				return writeJSON(cmd.OutOrStdout(), struct {
					Recipient  string `json:"recipient"`
					Registered int    `json:"registered"`
					Submitted  int    `json:"submitted"`
				}{recipient, result.Registered, result.Delivered})
			default:
				sender, err := discoverSession(ctx, client)
				if err != nil {
					err = svc.Relay(ctx, recipient, text)
				} else if source, readErr := store.Read(sender); readErr == nil && source.ExtraString("parent_session") == recipient {
					err = svc.Report(ctx, sender, text)
				} else {
					err = svc.RelayFrom(ctx, sender, recipient, text)
				}
				if err != nil {
					return err
				}
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				Recipient string `json:"recipient"`
				Submitted bool   `json:"submitted"`
			}{recipient, true})
		},
	}
	cmd.Flags().StringVar(&messageFile, "message-file", "", "read message from a file, or '-' for stdin")
	cmd.Flags().BoolVar(&steer, "steer", false, "steer Codex's active turn; queue if inactive")
	return cmd
}
