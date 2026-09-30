package mux

import (
	"errors"
	"fmt"
)

// handleViewport shares scroll positions between clients that opt in. It is
// ephemeral client state: it never changes terminal modes, dimensions, or the
// authoritative viewport, and never wakes a parked terminal.
func (b *Block) handleViewport(c *client, r Request) (Message, error) {
	c.mu.Lock()
	attached := c.subscriptions[b.info.ID] != ""
	enabled := c.viewportSync[b.info.ID]
	c.mu.Unlock()
	if !attached {
		return Message{}, errors.New("viewport sharing requires an attached terminal")
	}
	if r.Synchronized != nil {
		enabled = *r.Synchronized
	}
	if r.Viewport != nil {
		if !enabled {
			return Message{}, errors.New("viewport sharing is disabled for this client")
		}
		limit := b.parkedScrollback
		if b.terminal != nil {
			rows, err := b.terminal.ScrollbackRows()
			if err != nil {
				return Message{}, err
			}
			limit = uint64(rows)
		}
		if *r.Viewport > limit {
			return Message{}, fmt.Errorf("viewport exceeds available scrollback (%d lines)", limit)
		}
	}
	if r.Synchronized != nil {
		c.mu.Lock()
		if c.viewportSync == nil {
			c.viewportSync = map[string]bool{}
		}
		if enabled {
			c.viewportSync[b.info.ID] = true
		} else {
			delete(c.viewportSync, b.info.ID)
		}
		c.mu.Unlock()
	}
	if r.Viewport != nil {
		for _, peer := range b.server.attachedClients(b.info.ID) {
			if peer == c {
				continue
			}
			peer.mu.Lock()
			stream, subscribed := peer.subscriptions[b.info.ID], peer.viewportSync[b.info.ID]
			peer.mu.Unlock()
			if subscribed {
				peer.send(Message{Type: "viewport", Block: b.info.ID, Client: c.id, Stream: stream, Viewport: r.Viewport})
			}
		}
	}
	return Message{Block: b.info.ID, Synchronized: &enabled, Viewport: r.Viewport}, nil
}
