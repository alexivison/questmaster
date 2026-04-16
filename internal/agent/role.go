package agent

// Role identifies a logical agent slot in a session.
type Role string

const (
	RolePrimary   Role = "primary"
	RoleCompanion Role = "companion"
)

// RoleBinding maps a role to an agent and tmux layout position.
type RoleBinding struct {
	Role     Role
	Agent    Agent
	PaneRole string
	Window   int
}
