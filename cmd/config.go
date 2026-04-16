package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
	"github.com/spf13/cobra"
)

func newConfigCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "config",
		Short: "Manage user-global party-cli preferences",
	}
	cmd.AddCommand(
		newConfigInitCmd(),
		newConfigShowCmd(),
		newConfigPathCmd(),
		newConfigSetPrimaryCmd(),
		newConfigSetCompanionCmd(),
		newConfigUnsetCompanionCmd(),
	)
	return cmd
}

func newConfigInitCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "init",
		Short: "Create the default user-global config file",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path, err := agent.UserConfigPath()
			if err != nil {
				return err
			}
			if info, err := os.Stat(path); err == nil {
				if info.IsDir() {
					return fmt.Errorf("config path %s is a directory", path)
				}
				fmt.Fprintf(cmd.OutOrStdout(), "config already exists at %s\n", path)
				return nil
			} else if !os.IsNotExist(err) {
				return fmt.Errorf("stat %s: %w", path, err)
			}

			if err := writeTextAtomically(path, defaultConfigTemplate()); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "config initialized at %s\n", path)
			return nil
		},
	}
}

func newConfigShowCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "show",
		Short: "Print the resolved config",
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := agent.LoadConfig(nil)
			if err != nil {
				return err
			}
			fmt.Fprintln(cmd.OutOrStdout(), renderConfig(cfg))
			return nil
		},
	}
}

func newConfigPathCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "path",
		Short: "Print the user-global config path",
		RunE: func(cmd *cobra.Command, _ []string) error {
			path, err := agent.UserConfigPath()
			if err != nil {
				return err
			}
			fmt.Fprintln(cmd.OutOrStdout(), path)
			return nil
		},
	}
}

func newConfigSetPrimaryCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "set-primary <agent>",
		Short: "Set the default primary agent",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return mutateConfig(cmd, func(cfg *agent.Config) (string, error) {
				if err := validateConfiguredAgent(cfg, args[0]); err != nil {
					return "", err
				}
				if cfg.Roles.Primary == nil {
					cfg.Roles.Primary = &agent.RoleConfig{Window: -1}
				}
				cfg.Roles.Primary.Agent = args[0]
				return fmt.Sprintf("primary set to %q", args[0]), nil
			})
		},
	}
}

func newConfigSetCompanionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "set-companion <agent>",
		Short: "Set the default companion agent",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return mutateConfig(cmd, func(cfg *agent.Config) (string, error) {
				if err := validateConfiguredAgent(cfg, args[0]); err != nil {
					return "", err
				}
				if cfg.Roles.Companion == nil {
					cfg.Roles.Companion = &agent.RoleConfig{Window: 0}
				}
				cfg.Roles.Companion.Agent = args[0]
				return fmt.Sprintf("companion set to %q", args[0]), nil
			})
		},
	}
}

func newConfigUnsetCompanionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "unset-companion",
		Short: "Remove the default companion agent",
		RunE: func(cmd *cobra.Command, _ []string) error {
			return mutateConfig(cmd, func(cfg *agent.Config) (string, error) {
				cfg.Roles.Companion = nil
				return "companion unset", nil
			})
		},
	}
}

func mutateConfig(cmd *cobra.Command, mutate func(*agent.Config) (string, error)) error {
	cfg, err := agent.LoadConfig(nil)
	if err != nil {
		return err
	}

	message, err := mutate(cfg)
	if err != nil {
		return err
	}

	path, err := agent.UserConfigPath()
	if err != nil {
		return err
	}
	if err := writeTextAtomically(path, renderConfig(cfg)+"\n"); err != nil {
		return err
	}

	fmt.Fprintln(cmd.OutOrStdout(), message)
	return nil
}

func validateConfiguredAgent(cfg *agent.Config, name string) error {
	if cfg == nil {
		return fmt.Errorf("config is not loaded")
	}
	if _, ok := cfg.Agents[name]; ok {
		return nil
	}
	if _, ok := agent.DefaultConfig().Agents[name]; ok {
		return nil
	}
	return fmt.Errorf("agent %q is not configured", name)
}

func defaultConfigTemplate() string {
	return strings.TrimSpace(`
# party-cli config — user-global agent preferences
# Location: ~/.config/party-cli/config.toml
#
# This file controls which agents party-cli uses. Delete it to revert to defaults
# (Claude as primary, Codex as companion).
#
# CLI flags override this file per-session:
#   party.sh --primary codex "task"   # one-off override
#   party.sh --no-companion "task"    # run without companion
`) + "\n\n" + renderConfig(agent.DefaultConfig()) + "\n"
}

func renderConfig(cfg *agent.Config) string {
	if cfg == nil {
		cfg = agent.DefaultConfig()
	}

	sections := make([]string, 0, 4)

	if len(cfg.Agents) > 0 {
		names := make([]string, 0, len(cfg.Agents))
		for name := range cfg.Agents {
			names = append(names, name)
		}
		sort.Strings(names)

		for _, name := range names {
			var b strings.Builder
			fmt.Fprintf(&b, "[agents.%s]\n", name)
			fmt.Fprintf(&b, "cli = %q\n", cfg.Agents[name].CLI)
			sections = append(sections, strings.TrimSuffix(b.String(), "\n"))
		}
	}

	if cfg.Roles.Primary != nil {
		sections = append(sections, renderRoleConfig("primary", cfg.Roles.Primary))
	}
	if cfg.Roles.Companion != nil {
		sections = append(sections, renderRoleConfig("companion", cfg.Roles.Companion))
	}
	if len(cfg.Evidence.Required) > 0 {
		sections = append(sections, renderEvidenceConfig(cfg.Evidence.Required))
	}

	return strings.Join(sections, "\n\n")
}

func renderRoleConfig(name string, cfg *agent.RoleConfig) string {
	var b strings.Builder
	fmt.Fprintf(&b, "[roles.%s]\n", name)
	fmt.Fprintf(&b, "agent = %q\n", cfg.Agent)
	if cfg.Window >= 0 {
		fmt.Fprintf(&b, "window = %d\n", cfg.Window)
	}
	return strings.TrimSuffix(b.String(), "\n")
}

func renderEvidenceConfig(required []string) string {
	quoted := make([]string, 0, len(required))
	for _, value := range required {
		quoted = append(quoted, fmt.Sprintf("%q", value))
	}
	return "[evidence]\nrequired = [" + strings.Join(quoted, ", ") + "]"
}

func writeTextAtomically(path, body string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}

	tmpPath := path + ".tmp"
	if err := os.WriteFile(tmpPath, []byte(body), 0o644); err != nil {
		return fmt.Errorf("write %s: %w", tmpPath, err)
	}
	if err := os.Rename(tmpPath, path); err != nil {
		_ = os.Remove(tmpPath)
		return fmt.Errorf("rename %s to %s: %w", tmpPath, path, err)
	}
	return nil
}
