package mux

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
)

const ProtocolVersion = 1
const EngineVersion = "ghostty-27e8b3fa85d9"

type Request struct {
	Viewport     *uint64     `json:"viewport,omitempty"`
	Synchronized *bool       `json:"synchronized,omitempty"`
	ReplayID     string      `json:"replayID,omitempty"`
	Sequence     *uint64     `json:"sequence,omitempty"`
	ID           string      `json:"id"`
	Client       string      `json:"client,omitempty"`
	Kind         string      `json:"kind,omitempty"`
	Key          *KeyInput   `json:"key,omitempty"`
	Mouse        *MouseInput `json:"mouse,omitempty"`
	Method       string      `json:"method"`
	Session      string      `json:"session,omitempty"`
	Window       string      `json:"window,omitempty"`
	Block        string      `json:"block,omitempty"`
	Target       string      `json:"target,omitempty"`
	Label        string      `json:"label,omitempty"`
	Command      []string    `json:"command,omitempty"`
	Cwd          string      `json:"cwd,omitempty"`
	Axis         string      `json:"axis,omitempty"`
	Ratio        float64     `json:"ratio,omitempty"`
	Cols         uint16      `json:"cols,omitempty"`
	Rows         uint16      `json:"rows,omitempty"`
	CellWidth    uint32      `json:"cellWidth,omitempty"`
	CellHeight   uint32      `json:"cellHeight,omitempty"`
	Data         []byte      `json:"data,omitempty"`
	Format       string      `json:"format,omitempty"`
	KeepOpen     bool        `json:"keepOpen,omitempty"`
	Release      bool        `json:"release,omitempty"`
	Theme        *Theme      `json:"theme,omitempty"`
}

type Message struct {
	Features         []string       `json:"features,omitempty"`
	Graphics         *GraphicsState `json:"graphics,omitempty"`
	Viewport         *uint64        `json:"viewport,omitempty"`
	Synchronized     *bool          `json:"synchronized,omitempty"`
	ReplayID         string         `json:"replayID,omitempty"`
	Sequence         *uint64        `json:"sequence,omitempty"`
	PreviousSequence *uint64        `json:"previousSequence,omitempty"`
	ID               string         `json:"id,omitempty"`
	Type             string         `json:"type"`
	Error            string         `json:"error,omitempty"`
	Protocol         int            `json:"protocol,omitempty"`
	Engine           string         `json:"engine,omitempty"`
	Client           string         `json:"client,omitempty"`
	State            *State         `json:"state,omitempty"`
	Block            string         `json:"block,omitempty"`
	Session          string         `json:"session,omitempty"`
	Window           string         `json:"window,omitempty"`
	Stream           string         `json:"stream,omitempty"`
	Data             []byte         `json:"data,omitempty"`
	Text             string         `json:"text,omitempty"`
	Event            string         `json:"event,omitempty"`
	Final            bool           `json:"final,omitempty"`
	Cols             uint16         `json:"cols,omitempty"`
	Rows             uint16         `json:"rows,omitempty"`
	ExitCode         *int           `json:"exitCode,omitempty"`
	Entries          []Directory    `json:"entries,omitempty"`
	Path             string         `json:"path,omitempty"`
	Process          *ProcessInfo   `json:"process,omitempty"`
	Methods          []string       `json:"methods,omitempty"`
	Events           []string       `json:"events,omitempty"`
	BlockInfo        *BlockInfo     `json:"blockInfo,omitempty"`
	SessionInfo      *Session       `json:"sessionInfo,omitempty"`
	WindowInfo       *Window        `json:"windowInfo,omitempty"`
	Clients          []ClientInfo   `json:"clients,omitempty"`
	Server           *ServerInfo    `json:"server,omitempty"`
	Size             *SizeInfo      `json:"size,omitempty"`
	stopServer       bool
	closeClient      bool
	Theme            *Theme             `json:"theme,omitempty"`
	Credentials      *RemoteCredentials `json:"credentials,omitempty"`
}

type Theme struct {
	Background *uint32  `json:"background,omitempty"`
	Foreground *uint32  `json:"foreground,omitempty"`
	Cursor     *uint32  `json:"cursor,omitempty"`
	Palette    []uint32 `json:"palette"`
}

type Directory struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

type ProcessRecord struct {
	PID        int    `json:"pid"`
	UID        uint32 `json:"uid"`
	User       string `json:"user,omitempty"`
	Name       string `json:"name,omitempty"`
	Executable string `json:"executable,omitempty"`
}

type ProcessInfo struct {
	Child         *ProcessRecord `json:"child,omitempty"`
	Foreground    *ProcessRecord `json:"foreground,omitempty"`
	PID           int            `json:"pid"`
	ForegroundPID int            `json:"foregroundPID"`
	User          string         `json:"user"`
	Command       []string       `json:"command"`
	Cwd           string         `json:"cwd"`
	Home          string         `json:"home"`
	ExitCode      *int           `json:"exitCode,omitempty"`
}

type State struct {
	Revision uint64      `json:"revision"`
	Sessions []*Session  `json:"sessions"`
	Blocks   []BlockInfo `json:"blocks"`
	Clients  int         `json:"clients"`
}

type Session struct {
	ID            string    `json:"id"`
	FocusedWindow string    `json:"focusedWindow,omitempty"`
	Name          string    `json:"name"`
	Windows       []*Window `json:"windows"`
}

type Window struct {
	ID           string  `json:"id"`
	FocusedBlock string  `json:"focusedBlock,omitempty"`
	Name         string  `json:"name"`
	Root         *Layout `json:"root"`
	Zoomed       string  `json:"zoomed,omitempty"`
}

type Layout struct {
	ID           string  `json:"id"`
	FocusedBlock string  `json:"focusedBlock,omitempty"`
	Block        string  `json:"block,omitempty"`
	Axis         string  `json:"axis,omitempty"`
	Ratio        float64 `json:"ratio,omitempty"`
	First        *Layout `json:"first,omitempty"`
	Second       *Layout `json:"second,omitempty"`
}

type BlockInfo struct {
	Label    string   `json:"label,omitempty"`
	Creator  string   `json:"creator,omitempty"`
	Host     string   `json:"host,omitempty"`
	Flavor   string   `json:"flavor,omitempty"`
	Session  string   `json:"session,omitempty"`
	Window   string   `json:"window,omitempty"`
	ID       string   `json:"id"`
	Title    string   `json:"title"`
	Cwd      string   `json:"cwd"`
	PID      int      `json:"pid"`
	Cols     uint16   `json:"cols"`
	Rows     uint16   `json:"rows"`
	Parked   bool     `json:"parked"`
	ExitCode *int     `json:"exitCode,omitempty"`
	Command  []string `json:"command"`
	KeepOpen bool     `json:"keepOpen"`
	Owner    string   `json:"owner,omitempty"`
}

func NewID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}

func DefaultDirectory() string {
	if value := os.Getenv("ILLOGICAL_HOME"); value != "" {
		return value
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share", "illogical")
}

func SocketPath() string {
	if value := os.Getenv("ILLOGICAL_SOCKET"); value != "" {
		return value
	}
	return filepath.Join(DefaultDirectory(), "daemon.sock")
}

func leaf(block string) *Layout { return &Layout{ID: NewID(), Block: block} }

func (n *Layout) contains(block string) bool {
	if n == nil || block == "" {
		return false
	}
	return n.Block == block || n.First.contains(block) || n.Second.contains(block)
}

func (n *Layout) blocks() []string {
	if n == nil {
		return nil
	}
	if n.Block != "" {
		return []string{n.Block}
	}
	return append(n.First.blocks(), n.Second.blocks()...)
}

func (n *Layout) remove(block string) *Layout {
	if n == nil || n.Block == block {
		return nil
	}
	if n.Block != "" {
		return n
	}
	n.First = n.First.remove(block)
	n.Second = n.Second.remove(block)
	if n.First == nil {
		return n.Second
	}
	if n.Second == nil {
		return n.First
	}
	return n
}

func (n *Layout) insert(target, block, axis string) bool {
	if n == nil {
		return false
	}
	if n.Block == target {
		old := leaf(target)
		n.Block = ""
		n.Axis = axis
		n.Ratio = 0.5
		n.First, n.Second = old, leaf(block)
		return true
	}
	return n.First.insert(target, block, axis) || n.Second.insert(target, block, axis)
}

func (n *Layout) resize(id string, ratio float64) bool {
	if n == nil {
		return false
	}
	if n.ID == id && n.Block == "" {
		n.Ratio = max(0.1, min(0.9, ratio))
		return true
	}
	return n.First.resize(id, ratio) || n.Second.resize(id, ratio)
}
