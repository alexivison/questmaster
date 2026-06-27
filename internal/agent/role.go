package agent

// Role identifies a logical agent slot in a session.
type Role string

const (
	RolePrimary Role = "primary"
)

// RoleBinding maps a role to an agent.
type RoleBinding struct {
	Role  Role
	Agent Agent
}
