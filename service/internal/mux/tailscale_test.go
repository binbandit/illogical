package mux

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tailscale.com/client/tailscale/apitype"
	"tailscale.com/tailcfg"
)

func TestTailscaleAdmissionRequiresExplicitIdentity(t *testing.T) {
	config := TailscaleConfig{Hostname: "fixture", AllowedUsers: []string{"owner@example.test"}, AllowedTags: []string{"tag:trusted-terminal"}}
	if err := config.validate(); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name, login string
		tags        []string
		want        bool
	}{
		{"owner", "owner@example.test", nil, true},
		{"another user", "other@example.test", nil, false},
		{"tagged owner's unapproved node", "owner@example.test", []string{"tag:untrusted"}, false},
		{"explicit trusted tag", "tagged-user", []string{"tag:trusted-terminal"}, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			identity := &apitype.WhoIsResponse{Node: &tailcfg.Node{Tags: test.tags}, UserProfile: &tailcfg.UserProfile{LoginName: test.login}}
			if got := config.permits(identity); got != test.want {
				t.Fatalf("admission=%v, want %v", got, test.want)
			}
		})
	}
	if config.permits(nil) || config.permits(&apitype.WhoIsResponse{}) {
		t.Fatal("missing identity admitted")
	}
	for _, invalid := range []TailscaleConfig{
		{Hostname: "fixture"},
		{Hostname: "fixture", AllowedUsers: []string{"*"}},
		{Hostname: "fixture", AllowedTags: []string{"everyone"}},
		{Hostname: "fixture", AllowedUsers: []string{"owner"}, ServiceName: "svc:illogical-test"},
	} {
		if invalid.validate() == nil {
			t.Fatalf("invalid config accepted: %+v", invalid)
		}
	}
}

func TestTailscaleConfigRejectsUnknownOrTrailingInput(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tailscale.json")
	for _, contents := range []string{
		`{"hostname":"fixture","allowedUsers":["owner"],"allowEveryone":true}`,
		`{"hostname":"fixture","allowedUsers":["owner"]} {}`,
		`{"hostname":"fixture","allowedUsers":["owner"]}` + strings.Repeat(" ", 64<<10),
	} {
		if err := os.WriteFile(path, []byte(contents), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadTailscaleConfig(path); err == nil {
			t.Fatalf("accepted malformed configuration %s", contents)
		}
	}
}

func TestTailscaleConnectionCannotIssueQUICCredentials(t *testing.T) {
	server, _ := startTest(t)
	client, peer := net.Pipe()
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(2 * time.Second))
	connection := &tailscaleConnection{Conn: peer, principal: "owner@example.test"}
	if connection.LocalAddr().Network() != "tailscale" || connection.RemoteAddr().Network() != "tailscale" {
		t.Fatal("Tailscale transport lost its identity")
	}
	go server.serve(connection)
	decoder := json.NewDecoder(client)
	var hello Message
	if err := decoder.Decode(&hello); err != nil {
		t.Fatal(err)
	}
	if err := json.NewEncoder(client).Encode(Request{ID: "pair", Method: "remote.pair", Label: "127.0.0.1"}); err != nil {
		t.Fatal(err)
	}
	for {
		var reply Message
		if err := decoder.Decode(&reply); err != nil {
			t.Fatal(err)
		}
		if reply.ID != "pair" {
			continue
		}
		if reply.Error == "" || reply.Credentials != nil {
			t.Fatalf("network peer issued credentials: %+v", reply)
		}
		break
	}
}
