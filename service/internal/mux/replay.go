package mux

const (
	maxReplayBytes   = 8 << 20
	maxReplayRecords = 4096
)

type replayRecord struct {
	message Message
	charge  int
}
type replayBuffer struct {
	epoch    string
	sequence uint64
	floor    uint64
	records  []replayRecord
	head     int
	bytes    int
}

func (r *replayBuffer) clear() {
	r.floor = r.sequence
	r.records = nil
	r.head = 0
	r.bytes = 0
}
func (r *replayBuffer) invalidate() { r.epoch = NewID(); r.sequence = 0; r.clear() }
func (r *replayBuffer) append(message Message) Message {
	previous := r.sequence
	r.sequence++
	sequence := r.sequence
	message.ReplayID = r.epoch
	message.PreviousSequence = &previous
	message.Sequence = &sequence
	charge := len(message.Data) + graphicsCharge(message.Graphics) + 256
	if message.Theme != nil {
		charge += len(message.Theme.Palette)*4 + 32
	}
	if charge > maxReplayBytes {
		r.clear()
		return message
	}
	for r.bytes+charge > maxReplayBytes || len(r.records)-r.head >= maxReplayRecords {
		old := r.records[r.head]
		r.floor = *old.message.Sequence
		r.bytes -= old.charge
		r.records[r.head] = replayRecord{}
		r.head++
	}
	if r.head >= 1024 && r.head >= len(r.records)/2 {
		n := copy(r.records, r.records[r.head:])
		clear(r.records[n:])
		r.records = r.records[:n]
		r.head = 0
	}
	r.records = append(r.records, replayRecord{message: message, charge: charge})
	r.bytes += charge
	return message
}

// Data already belongs to the immutable PTY read chunk; the bounded replay
// window shares it with outbound queues without copying the bytes again.
func (b *Block) publishMutation(message Message) {
	message.Block = b.info.ID
	message = b.replay.append(message)
	b.server.broadcast(message, b.info.ID)
}
func replayAdjacent(previous, next Message) bool {
	if previous.ReplayID != next.ReplayID {
		return false
	}
	if previous.Sequence == nil || next.PreviousSequence == nil {
		return previous.Sequence == nil && next.PreviousSequence == nil
	}
	return *previous.Sequence == *next.PreviousSequence
}

// Caller holds b.mu, excluding output/resize/theme mutations until all retained
// records and the new subscription are enqueued in exactly the same order.
func (b *Block) resume(c *client, r Request) bool {
	reason := ""
	switch {
	case r.ReplayID != b.replay.epoch:
		reason = "terminal generation changed"
	case *r.Sequence > b.replay.sequence:
		reason = "cursor is ahead of terminal"
	case *r.Sequence < b.replay.floor:
		reason = "recent output is no longer retained"
	}
	if reason != "" {
		c.send(Message{Type: "resync", Block: b.info.ID, ReplayID: b.replay.epoch, Text: reason})
		return false
	}
	stream := NewID()
	c.mu.Lock()
	c.subscriptions[b.info.ID] = stream
	c.mu.Unlock()
	baseline := *r.Sequence
	if !c.send(Message{Type: "resume", Block: b.info.ID, Stream: stream, ReplayID: b.replay.epoch, Sequence: &baseline}) {
		return true
	}
	for _, record := range b.replay.records[b.replay.head:] {
		if *record.message.Sequence <= baseline {
			continue
		}
		message := record.message
		message.Stream = stream
		if !c.send(message) {
			return true
		}
	}
	b.notifyViewerChange()
	return true
}
