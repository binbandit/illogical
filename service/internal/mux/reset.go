package mux

import "time"

func (s *Server) resetTerminal(r Request) Message {
	s.mu.Lock()
	b := s.blocks[r.Block]
	s.mu.Unlock()
	if b == nil {
		return Message{Type: "error", Error: "terminal block not found"}
	}
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return Message{Type: "error", Error: "terminal is closed"}
	}
	if err := b.wake(); err != nil {
		b.mu.Unlock()
		return Message{Type: "error", Error: err.Error()}
	}
	ground, err := b.terminal.VTGround()
	if err != nil {
		b.mu.Unlock()
		return Message{Type: "error", Error: err.Error()}
	}
	if ground {
		b.finishReset(false)
		b.mu.Unlock()
		return Message{}
	}
	pending := b.resetPending
	if pending == nil {
		pending = make(chan struct{})
		b.resetPending = pending
		go func() {
			timer := time.NewTimer(250 * time.Millisecond)
			defer timer.Stop()
			select {
			case <-timer.C:
				b.mu.Lock()
				if !b.closed && b.resetPending == pending {
					b.finishReset(true)
				}
				b.mu.Unlock()
			case <-pending:
			case <-b.done:
			}
		}()
	}
	b.mu.Unlock()
	select {
	case <-pending:
		return Message{}
	case <-b.done:
		return Message{Type: "error", Error: "terminal closed during reset"}
	}
}

// Called with b.mu held. The timeout route replaces replicas from a coherent
// snapshot because injecting bytes into an unfinished parser is ambiguous.
func (b *Block) finishReset(resync bool) {
	if resync {
		b.replay.invalidate()
		b.terminal.VTWrite([]byte{0x18})
		b.terminal.Reset()
	} else {
		data := []byte("\x1bc")
		b.terminal.VTWrite(data)
		b.publishMutation(Message{Type: "output", Data: data})
	}
	b.applyTheme()
	// An explicit reset discards both screen registries, allowing parking again.
	oldGraphics := b.graphics.retained || len(b.graphics.scene.Placements) > 0
	b.graphics = graphicsTracker{}
	_ = b.terminal.SetContinuationMaxBytes(1 << 20)
	_ = b.configureGraphics()
	if oldGraphics && !resync {
		b.publishMutation(Message{Type: "graphics", Graphics: b.graphicsSnapshot()})
	}
	b.server.parkingChanged()
	if resync {
		b.server.clientsMu.RLock()
		viewers := make([]*client, 0, len(b.server.clients))
		for _, c := range b.server.clients {
			viewers = append(viewers, c)
		}
		b.server.clientsMu.RUnlock()
		for _, c := range viewers {
			c.mu.Lock()
			attached := c.subscriptions[b.info.ID] != ""
			c.mu.Unlock()
			if attached {
				if err := b.server.attach(c, b, ""); err != nil {
					c.send(Message{Type: "error", Block: b.info.ID, Error: "reset snapshot: " + err.Error()})
				}
			}
		}
	}
	if pending := b.resetPending; pending != nil {
		b.resetPending = nil
		close(pending)
	}
}

func (b *Block) writeOutput(data []byte) {
	if b.resetPending != nil {
		consumed, err := b.terminal.VTWriteUntilGround(data)
		if consumed > 0 {
			b.publishMutation(Message{Type: "output", Data: data[:consumed]})
			b.graphicsOutput(data[:consumed])
		}
		data = data[consumed:]
		if err == nil {
			b.finishReset(false)
		} else if len(data) > 0 { // Unexpected parser error: recover coherently.
			b.finishReset(true)
		}
	}
	if len(data) > 0 {
		b.publishMutation(Message{Type: "output", Data: data})
		b.terminal.VTWrite(data)
		b.graphicsOutput(data)
	}
}
