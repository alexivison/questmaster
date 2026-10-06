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
--steer to ask Codex app-server to steer a turn it can control. If it cannot
control the active thread, --steer falls back to the durable queue. If the
daemon is unavailable, the existing tmux fallback applies. With --steer,
delivery_mode reports the selected transport, not model receipt.
Use --message-file <path> or --message-file - for file or stdin input.

For Claude, Pi, OpenCode, and tmux targets, --steer keeps the existing transport behavior.`,
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
			var deliveryMode message.DeliveryMode
			switch recipient {
			case "master":
				sender, err := discoverSession(ctx, client)
				if err != nil {
					return err
				}
				deliveryMode, err = svc.ReportWithMode(ctx, sender, text)
				if err != nil {
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
				response := struct {
					Recipient     string                       `json:"recipient"`
					Registered    int                          `json:"registered"`
					Submitted     int                          `json:"submitted"`
					DeliveryModes map[message.DeliveryMode]int `json:"delivery_modes,omitempty"`
				}{recipient, result.Registered, result.Delivered, nil}
				if steer {
					response.DeliveryModes = result.DeliveryModes
				}
				return writeJSON(cmd.OutOrStdout(), response)
			default:
				sender, err := discoverSession(ctx, client)
				if err != nil {
					deliveryMode, err = svc.RelayWithMode(ctx, recipient, text)
				} else if source, readErr := store.Read(sender); readErr == nil && source.ExtraString("parent_session") == recipient {
					deliveryMode, err = svc.ReportWithMode(ctx, sender, text)
				} else {
					deliveryMode, err = svc.RelayFromWithMode(ctx, sender, recipient, text)
				}
				if err != nil {
					return err
				}
			}
			response := struct {
				Recipient    string               `json:"recipient"`
				Submitted    bool                 `json:"submitted"`
				DeliveryMode message.DeliveryMode `json:"delivery_mode,omitempty"`
			}{Recipient: recipient, Submitted: true}
			if steer {
				response.DeliveryMode = deliveryMode
			}
			return writeJSON(cmd.OutOrStdout(), response)
		},
	}
	cmd.Flags().StringVar(&messageFile, "message-file", "", "read message from a file, or '-' for stdin")
	cmd.Flags().BoolVar(&steer, "steer", false, "request Codex active-turn steering and report the selected route")
	return cmd
}
