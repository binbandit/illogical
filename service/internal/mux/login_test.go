package mux

import (
	"os/exec"
	"reflect"
	"testing"
)

func TestLoginCommandIsExplicitAndPreservesArgumentBoundaries(t *testing.T) {
	cmd := exec.Command("/bin/sh", "-c", "printf '%s' '$HOME; literal'")
	original := append([]string(nil), cmd.Args...)
	s := &Server{}
	if err := s.prepareLoginCommand(cmd); err != nil || !reflect.DeepEqual(original, cmd.Args) {
		t.Fatalf("disabled login mutated command: %v %+v", err, cmd.Args)
	}
	s.loginHelper = "/run/wrappers/bin/illogical-login"
	if err := s.prepareLoginCommand(cmd); err != nil {
		t.Fatal(err)
	}
	if cmd.Path != s.loginHelper || !reflect.DeepEqual(cmd.Args, append([]string{s.loginHelper, "--", "/bin/sh"}, original...)) {
		t.Fatalf("argument boundaries changed: %+v", cmd.Args)
	}
}

func TestLoginHelperRejectsUntrustedOrUnsupportedPath(t *testing.T) {
	s := &Server{}
	if err := WithLoginHelper("")(s); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"relative", "/bin/sh"} {
		if err := WithLoginHelper(path)(s); err == nil {
			t.Fatalf("unsafe helper accepted: %s", path)
		}
	}
}
