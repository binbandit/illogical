package main

import (
	"errors"
	"fmt"

	"illogical/internal/mux"
)

// childExitStatus makes `illogical wait` exit with the child's status.
type childExitStatus int

func (status childExitStatus) Error() string {
	return fmt.Sprintf("process exited with status %d", status)
}

func exitResult(code *int) error {
	if code == nil {
		return errors.New("service did not report the process exit status")
	}
	if *code == 0 {
		return nil
	}
	return childExitStatus(*code)
}

// waitForBlock waits for one block's child to exit. Subscribing and reading
// the state happen atomically on the service, and events arriving before the
// reply are kept, so even a child that exits immediately is observed.
func waitForBlock(c *connection, block string) error {
	if block == "" {
		return errors.New("wait requires --block or ILLOGICAL_BLOCK")
	}
	message, err := c.request(mux.Request{Method: "watch"})
	if err != nil {
		return err
	}
	found := false
	if message.State != nil {
		for _, info := range message.State.Blocks {
			if info.ID == block {
				if info.ExitCode != nil {
					return exitResult(info.ExitCode)
				}
				found = true
				break
			}
		}
	}
	if !found {
		for _, event := range c.pending {
			if event.Event == "child_exited" && event.Block == block {
				return exitResult(event.ExitCode)
			}
		}
		return errors.New("block not found")
	}
	for {
		event, err := c.next()
		if err != nil {
			return fmt.Errorf("connection closed before the process exited: %w", err)
		}
		if event.Event == "child_exited" && event.Block == block {
			return exitResult(event.ExitCode)
		}
	}
}

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
	if m.Session != "" && m.Window != "" {
		session := r.Session
		if resolved := findStateSession(state, session); resolved != nil {
			session = resolved.ID
		}
		return (session == "" || session == m.Session) && (r.Window == "" || r.Window == m.Window)
	}
	// Older services omit event routing. Retain their state-based behavior.
	if state == nil {
		return false
	}
	selected := findStateSession(state, r.Session)
	for _, ss := range state.Sessions {
		if r.Session != "" && ss != selected {
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

func findStateSession(state *mux.State, value string) *mux.Session {
	if state == nil || value == "" {
		return nil
	}
	for _, session := range state.Sessions {
		if session.ID == value {
			return session
		}
	}
	for _, session := range state.Sessions {
		if session.Name == value {
			return session
		}
	}
	return nil
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
	selected := findStateSession(m.State, r.Session)
	for _, ss := range m.State.Sessions {
		if r.Session != "" && ss != selected {
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
