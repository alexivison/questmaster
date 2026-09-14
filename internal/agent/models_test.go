package agent

import "testing"

func TestRoleDefaultsKey(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		role SessionRole
		want string
	}{
		"master":     {role: RoleMaster, want: "master"},
		"worker":     {role: RoleWorker, want: "worker"},
		"standalone": {role: RoleStandalone, want: "standalone"},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if got := RoleDefaultsKey(tc.role); got != tc.want {
				t.Fatalf("RoleDefaultsKey(%v) = %q, want %q", tc.role, got, tc.want)
			}
		})
	}
}
