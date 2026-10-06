package cmd

import (
	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newSendCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	var messageFile string
	cmd := &cobra.Command{
		Use:   "send <recipient|master|all> [message]",
		Short: "Send to a session, report to your master, or broadcast to workers",
		Long: `Send a message using one recipient form:

  questmaster send <session-id> "message"  Send directly to a session
  questmaster send master "message"        Worker report to its parent
  questmaster send all "message"           Master broadcast to its workers

Questmaster-launched or continued Codex sessions with a per-session app-server
receive active-turn input by default. If there is no active turn, steering is
unsupported, the app-server is unavailable, or the session is older, external,
or started without that server, send uses Codex's durable queue. If Codex's
queue daemon or required native transport is unavailable, the existing tmux
fallback applies.
delivery_mode reports the selected transport, not model receipt. If steer
acceptance is uncertain, send errors without retrying through the queue or tmux.
Use --message-file <path> or --message-file - for file or stdin input.

For Claude, Pi, OpenCode, and tmux targets, send keeps the existing transport behavior.`,
		Args: cobra.RangeArgs(1, 2),
		RunE: func(cmd *cobra.Command, args []string) error {
			text, err := messageFromArgsAndFile(cmd, args[1:], messageFile)
			if err != nil {
				return err
			}
			ctx := cmd.Context()
			recipient := args[0]
			svc := message.NewService(store, client)
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
					DeliveryModes map[message.DeliveryMode]int `json:"delivery_modes"`
				}{recipient, result.Registered, result.Delivered, nil}
				response.DeliveryModes = result.DeliveryModes
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
				DeliveryMode message.DeliveryMode `json:"delivery_mode"`
			}{Recipient: recipient, Submitted: true, DeliveryMode: deliveryMode}
			return writeJSON(cmd.OutOrStdout(), response)
		},
	}
	cmd.Flags().StringVar(&messageFile, "message-file", "", "read message from a file, or '-' for stdin")
	return cmd
}
