package prstatus

import (
	"reflect"
	"testing"
)

func TestParseLoggedInHostsKeepsHostsWithAValidAccount(t *testing.T) {
	t.Parallel()
	data := []byte(`{"hosts":{
		"github.com":[{"state":"success","active":true,"host":"github.com","login":"example-user"}],
		"GHE.example":[{"state":"error","active":false},{"state":"success","active":true}],
		"expired.example":[{"state":"error","active":true}]
	}}`)
	got, err := parseLoggedInHosts(data)
	if err != nil || !reflect.DeepEqual(got, []string{"ghe.example", "github.com"}) {
		t.Fatalf("logged-in hosts = %v, %v", got, err)
	}
}

func TestParseLoggedInHostsWithoutLogins(t *testing.T) {
	t.Parallel()
	got, err := parseLoggedInHosts([]byte(`{"hosts":{}}`))
	if err != nil || len(got) != 0 {
		t.Fatalf("logged-in hosts = %v, %v", got, err)
	}
}

func TestParseLoggedInHostsRejectsMalformedOutput(t *testing.T) {
	t.Parallel()
	if _, err := parseLoggedInHosts([]byte("You are not logged into any GitHub hosts.")); err == nil {
		t.Fatal("accepted non-JSON gh output")
	}
}
