package agent

// Role identifies a logical agent slot in a session.
type Role string

const (
	RoleAgent Role = "agent"
)

// RoleBinding maps a role to an agent.
type RoleBinding struct {
	Role  Role
	Agent Agent
}
