package main

import (
	"errors"
	"fmt"
	"illogical/internal/mux"
)

func layoutBlocks(n *mux.Layout) []string {
	if n == nil {
		return nil
	}
	if n.Block != "" {
		return []string{n.Block}
	}
	return append(layoutBlocks(n.First), layoutBlocks(n.Second)...)
}
func eventMatches(r mux.Request, m mux.Message, state *mux.State) bool {
	if r.Block == "" && r.Window == "" && r.Session == "" {
		return true
	}
	if m.Type != "event" {
		return false
	}
	if r.Block != "" && m.Block != r.Block {
		return false
	}
	if r.Window == "" && r.Session == "" {
		return true
	}
	if state == nil {
		return false
	}
	for _, ss := range state.Sessions {
		if r.Session != "" && r.Session != ss.ID && r.Session != ss.Name {
			continue
		}
		for _, w := range ss.Windows {
			if r.Window != "" && r.Window != w.ID {
				continue
			}
			for _, id := range layoutBlocks(w.Root) {
				if id == m.Block {
					return true
				}
			}
		}
	}
	return false
}

// A window/session wait observes the children placed there when the atomic
// watch snapshot is taken. New children do not extend an already running wait.
func waitForResource(c *connection, r mux.Request) error {
	if r.Window == "" && r.Session == "" {
		return waitForBlock(c, r.Block)
	}
	m, err := c.request(mux.Request{Method: "watch"})
	if err != nil {
		return err
	}
	if m.State == nil {
		return errors.New("service returned no workspace state")
	}
	ids := []string{}
	found := false
	for _, ss := range m.State.Sessions {
		if r.Session != "" && ss.ID != r.Session && ss.Name != r.Session {
			continue
		}
		if r.Window == "" {
			found = true
		}
		for _, w := range ss.Windows {
			if r.Window != "" && w.ID != r.Window {
				continue
			}
			found = true
			ids = append(ids, layoutBlocks(w.Root)...)
		}
	}
	if !found {
		return errors.New("wait resource not found")
	}
	remaining := map[string]bool{}
	codes := map[string]int{}
	for _, id := range ids {
		remaining[id] = true
	}
	for _, info := range m.State.Blocks {
		if remaining[info.ID] && info.ExitCode != nil {
			codes[info.ID] = *info.ExitCode
			delete(remaining, info.ID)
		}
	}
	for len(remaining) > 0 {
		event, err := c.next()
		if err != nil {
			return fmt.Errorf("connection closed before resource children exited: %w", err)
		}
		if !remaining[event.Block] {
			continue
		}
		if event.Event == "child_exited" && event.ExitCode != nil {
			codes[event.Block] = *event.ExitCode
			delete(remaining, event.Block)
		}
		if event.Event == "block_closed" {
			return errors.New("block was removed before its exit status was observed")
		}
	}
	for _, id := range ids {
		if code := codes[id]; code != 0 {
			return childExitStatus(code)
		}
	}
	return nil
}
