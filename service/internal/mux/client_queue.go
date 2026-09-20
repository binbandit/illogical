package mux

import (
	"sync"
)

const (
	maxClientQueuedBytes    = 32 << 20
	maxClientQueuedPackets  = 4096
	maxOutputBatchBytes     = 256 << 10
	maxOutputBatchFragments = 512
	primaryOutputHighWater  = 1 << 20
	primaryOutputLowWater   = 512 << 10
)

type queuedMessage struct {
	message   Message
	fragments [][]byte
	dataBytes int
	charge    int
}

// A byte budget accommodates short bursts while snapshots or a busy UI catch
// up. Adjacent output is batched without delaying interactive writes, crossing
// protocol barriers, or making one client's socket block any other client.
type messageQueue struct {
	mu      sync.Mutex
	packets []queuedMessage
	head    int
	bytes   int
	ready   chan struct{}
	space   chan struct{}
	blocked bool
}

func newMessageQueue() *messageQueue {
	return &messageQueue{ready: make(chan struct{}, 1), space: make(chan struct{})}
}

// The primary viewer controls its PTY's production rate. A small high-water
// mark leaves room for protocol replies and other panes on this connection.
func (q *messageQueue) waitForSpace() <-chan struct{} {
	q.mu.Lock()
	defer q.mu.Unlock()
	if !q.blocked && q.bytes < primaryOutputHighWater {
		return nil
	}
	q.blocked = true
	return q.space
}

func (q *messageQueue) stats() (queuedBytes, queuedPackets int) {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.bytes, len(q.packets) - q.head
}

func (q *messageQueue) push(message Message) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	charge := len(message.Data) + len(message.Text) + len(message.Error) + graphicsCharge(message.Graphics) + 512
	if len(q.packets) > q.head && message.Type == "output" {
		previous := &q.packets[len(q.packets)-1]
		if previous.message.Type == "output" && previous.message.Block == message.Block && previous.message.Stream == message.Stream && replayAdjacent(previous.message, message) &&
			previous.dataBytes+len(message.Data) <= maxOutputBatchBytes && len(previous.fragments) < maxOutputBatchFragments {
			charge = len(message.Data) + 24
			if q.bytes+charge > maxClientQueuedBytes {
				return false
			}
			if previous.fragments == nil {
				previous.fragments = [][]byte{previous.message.Data}
				previous.message.Data = nil
			}
			previous.fragments = append(previous.fragments, message.Data)
			previous.message.Sequence = message.Sequence
			previous.dataBytes += len(message.Data)
			previous.charge += charge
			q.bytes += charge
			return true
		}
	}
	if q.bytes+charge > maxClientQueuedBytes || len(q.packets)-q.head >= maxClientQueuedPackets {
		return false
	}
	q.packets = append(q.packets, queuedMessage{message: message, dataBytes: len(message.Data), charge: charge})
	q.bytes += charge
	select {
	case q.ready <- struct{}{}:
	default:
	}
	return true
}

func (q *messageQueue) pop() (Message, bool) {
	q.mu.Lock()
	if q.head == len(q.packets) {
		q.mu.Unlock()
		return Message{}, false
	}
	packet := q.packets[q.head]
	q.packets[q.head] = queuedMessage{}
	q.head++
	q.bytes -= packet.charge
	if q.blocked && q.bytes <= primaryOutputLowWater {
		close(q.space)
		q.space = make(chan struct{})
		q.blocked = false
	}
	if q.head == len(q.packets) {
		q.packets = q.packets[:0]
		q.head = 0
	} else if q.head >= 1024 && q.head >= len(q.packets)/2 {
		remaining := copy(q.packets, q.packets[q.head:])
		clear(q.packets[remaining:])
		q.packets = q.packets[:remaining]
		q.head = 0
	}
	q.mu.Unlock()
	if packet.fragments != nil {
		packet.message.Data = make([]byte, 0, packet.dataBytes)
		for _, fragment := range packet.fragments {
			packet.message.Data = append(packet.message.Data, fragment...)
		}
	}
	return packet.message, true
}
