package mux

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
	"time"
)

// The wire protocol is one JSON object per line in each direction. Clients
// send Requests; the service replies with a Message carrying the request ID
// and also pushes unsolicited Messages (state, terminal output, events).
const ProtocolVersion = 1
const EngineVersion = "ghostty-27e8b3fa85d9"

type Request struct {
	ID       string      `json:"id"`
	Method   string      `json:"method"`
	Client   string      `json:"client,omitempty"`
	Kind     string      `json:"kind,omitempty"`
	Session  string      `json:"session,omitempty"`
	Window   string      `json:"window,omitempty"`
	Block    string      `json:"block,omitempty"`
	Target   string      `json:"target,omitempty"`
	Label    string      `json:"label,omitempty"`
	Command  []string    `json:"command,omitempty"`
	Cwd      string      `json:"cwd,omitempty"`
	Axis     string      `json:"axis,omitempty"`
	Ratio    float64     `json:"ratio,omitempty"`
	KeepOpen bool        `json:"keepOpen,omitempty"`
	Data     []byte      `json:"data,omitempty"`
	Key      *KeyInput   `json:"key,omitempty"`
	Mouse    *MouseInput `json:"mouse,omitempty"`
	Format   string      `json:"format,omitempty"`
	Theme    *Theme      `json:"theme,omitempty"`

	Cols       uint16 `json:"cols,omitempty"`
	Rows       uint16 `json:"rows,omitempty"`
	CellWidth  uint32 `json:"cellWidth,omitempty"`
	CellHeight uint32 `json:"cellHeight,omitempty"`
	Release    bool   `json:"release,omitempty"`

	// Reattach from a replay cursor (block.attach) and viewport sharing.
	ReplayID     string  `json:"replayID,omitempty"`
	Sequence     *uint64 `json:"sequence,omitempty"`
	Viewport     *uint64 `json:"viewport,omitempty"`
	Synchronized *bool   `json:"synchronized,omitempty"`
}

type Message struct {
	ID       string   `json:"id,omitempty"`
	Type     string   `json:"type"`
	Error    string   `json:"error,omitempty"`
	Protocol int      `json:"protocol,omitempty"`
	Engine   string   `json:"engine,omitempty"`
	Features []string `json:"features,omitempty"`
	Client   string   `json:"client,omitempty"`
	State    *State   `json:"state,omitempty"`
	Block    string   `json:"block,omitempty"`
	Session  string   `json:"session,omitempty"`
	Window   string   `json:"window,omitempty"`
	Stream   string   `json:"stream,omitempty"`
	Data     []byte   `json:"data,omitempty"`
	Text     string   `json:"text,omitempty"`
	Event    string   `json:"event,omitempty"`
	Final    bool     `json:"final,omitempty"`
	Cols     uint16   `json:"cols,omitempty"`
	Rows     uint16   `json:"rows,omitempty"`
	ExitCode *int     `json:"exitCode,omitempty"`
	Theme    *Theme   `json:"theme,omitempty"`

	// Replay ordering of terminal mutations; see replayBuffer.
	ReplayID         string  `json:"replayID,omitempty"`
	Sequence         *uint64 `json:"sequence,omitempty"`
	PreviousSequence *uint64 `json:"previousSequence,omitempty"`

	Viewport     *uint64        `json:"viewport,omitempty"`
	Synchronized *bool          `json:"synchronized,omitempty"`
	Graphics     *GraphicsState `json:"graphics,omitempty"`

	Entries     []Directory        `json:"entries,omitempty"`
	Path        string             `json:"path,omitempty"`
	Process     *ProcessInfo       `json:"process,omitempty"`
	Methods     []string           `json:"methods,omitempty"`
	Events      []string           `json:"events,omitempty"`
	BlockInfo   *BlockInfo         `json:"blockInfo,omitempty"`
	SessionInfo *Session           `json:"sessionInfo,omitempty"`
	WindowInfo  *Window            `json:"windowInfo,omitempty"`
	Clients     []ClientInfo       `json:"clients,omitempty"`
	Server      *ServerInfo        `json:"server,omitempty"`
	Size        *SizeInfo          `json:"size,omitempty"`
	Credentials *RemoteCredentials `json:"credentials,omitempty"`

	// Actions the connection writer performs after delivering this reply.
	stopServer  bool
	closeClient bool
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

// Window is a tab. The protocol and CLI call it a window for tmux familiarity.
type Window struct {
	ID           string  `json:"id"`
	FocusedBlock string  `json:"focusedBlock,omitempty"`
	Name         string  `json:"name"`
	Root         *Layout `json:"root"`
	Zoomed       string  `json:"zoomed,omitempty"`
}

// BlockInfo describes one terminal pane and its child process.
type BlockInfo struct {
	ID       string   `json:"id"`
	Label    string   `json:"label,omitempty"`
	Creator  string   `json:"creator,omitempty"`
	Host     string   `json:"host,omitempty"`
	Session  string   `json:"session,omitempty"`
	Window   string   `json:"window,omitempty"`
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

type Theme struct {
	Background *uint32  `json:"background,omitempty"`
	Foreground *uint32  `json:"foreground,omitempty"`
	Cursor     *uint32  `json:"cursor,omitempty"`
	Palette    []uint32 `json:"palette"`
}

type KeyInput struct {
	Name   string `json:"name"`
	Action string `json:"action,omitempty"`
	Mods   string `json:"mods,omitempty"`
	Text   string `json:"text,omitempty"`
}

type MouseInput struct {
	Button string `json:"button,omitempty"`
	Action string `json:"action,omitempty"`
	Mods   string `json:"mods,omitempty"`
	X      uint32 `json:"x"`
	Y      uint32 `json:"y"`
	Pixels bool   `json:"pixels,omitempty"`
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

type ClientInfo struct {
	ID            string    `json:"id"`
	Label         string    `json:"label,omitempty"`
	Kind          string    `json:"kind"`
	Transport     string    `json:"transport"`
	ConnectedAt   time.Time `json:"connectedAt"`
	Block         string    `json:"block,omitempty"`
	Session       string    `json:"session,omitempty"`
	Window        string    `json:"window,omitempty"`
	Subscriptions []string  `json:"subscriptions"`
}

type ServerInfo struct {
	PID       int       `json:"pid"`
	UID       int       `json:"uid"`
	Host      string    `json:"host"`
	Socket    string    `json:"socket"`
	StartedAt time.Time `json:"startedAt"`
	Protocol  int       `json:"protocol"`
	Engine    string    `json:"engine"`
	Version   string    `json:"version"`
}

// DesiredSize is what one client would like a terminal to be; the owner's wins.
type DesiredSize struct {
	Cols       uint16 `json:"cols"`
	Rows       uint16 `json:"rows"`
	CellWidth  uint32 `json:"cellWidth"`
	CellHeight uint32 `json:"cellHeight"`
}

type SizeInfo struct {
	Desired    map[string]DesiredSize `json:"desired"`
	Cols       uint16                 `json:"cols"`
	Rows       uint16                 `json:"rows"`
	CellWidth  uint32                 `json:"cellWidth"`
	CellHeight uint32                 `json:"cellHeight"`
	Owner      string                 `json:"owner,omitempty"`
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
