package mux

import "fmt"

// Viewport sharing is ephemeral client state. It never changes terminal modes,
// dimensions, selection, or the authoritative viewport and does not wake parks.
func (b *Block) handleViewport(c *client, r Request) Message {
	fail := func(text string) Message { return Message{Type: "error", Error: text} }
	c.mu.Lock()
	attached := c.subscriptions[b.info.ID] != ""
	enabled := c.viewportSync[b.info.ID]
	c.mu.Unlock()
	if !attached {
		return fail("viewport sharing requires an attached terminal")
	}
	if r.Synchronized != nil {
		enabled = *r.Synchronized
	}
	if r.Viewport != nil {
		if !enabled {
			return fail("viewport sharing is disabled for this client")
		}
		limit := b.parkedScrollback
		if b.terminal != nil {
			rows, err := b.terminal.ScrollbackRows()
			if err != nil {
				return fail(err.Error())
			}
			limit = uint64(rows)
		}
		if *r.Viewport > limit {
			return fail(fmt.Sprintf("viewport exceeds available scrollback (%d lines)", limit))
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
		b.server.clientsMu.RLock()
		for _, peer := range b.server.clients {
			if peer == c {
				continue
			}
			peer.mu.Lock()
			stream := peer.subscriptions[b.info.ID]
			subscribed := peer.viewportSync[b.info.ID]
			peer.mu.Unlock()
			if stream != "" && subscribed {
				peer.send(Message{Type: "viewport", Block: b.info.ID, Client: c.id, Stream: stream, Viewport: r.Viewport})
			}
		}
		b.server.clientsMu.RUnlock()
	}
	return Message{Block: b.info.ID, Synchronized: &enabled, Viewport: r.Viewport}
}
