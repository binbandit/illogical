package mux

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"tailscale.com/client/tailscale/apitype"
	"tailscale.com/tailcfg"
	"tailscale.com/tsnet"
)

// Configuration is opt-in. The local service never enrolls a Tailscale node
// merely because the library is linked or TS_AUTHKEY exists in its environment.
type TailscaleConfig struct {
	Hostname       string   `json:"hostname"`
	StateDirectory string   `json:"stateDirectory,omitempty"`
	AuthKeyFile    string   `json:"authKeyFile,omitempty"`
	ControlURL     string   `json:"controlURL,omitempty"`
	AdvertiseTags  []string `json:"advertiseTags,omitempty"`
	ServiceName    string   `json:"serviceName,omitempty"`
	Port           uint16   `json:"port,omitempty"`
	AllowedUsers   []string `json:"allowedUsers,omitempty"`
	AllowedTags    []string `json:"allowedTags,omitempty"`
}

func LoadTailscaleConfig(path string) (TailscaleConfig, error) {
	file, err := os.Open(path)
	if err != nil {
		return TailscaleConfig{}, err
	}
	defer file.Close()
	contents, err := io.ReadAll(io.LimitReader(file, (64<<10)+1))
	if err != nil {
		return TailscaleConfig{}, err
	}
	if len(contents) > 64<<10 {
		return TailscaleConfig{}, errors.New("tailscale config exceeds 64 KiB")
	}
	decoder := json.NewDecoder(bytes.NewReader(contents))
	decoder.DisallowUnknownFields()
	var config TailscaleConfig
	if err := decoder.Decode(&config); err != nil {
		return config, err
	}
	if err := decoder.Decode(new(json.RawMessage)); err != io.EOF {
		return config, errors.New("tailscale config must contain one JSON object")
	}
	return config, config.validate()
}

func (config TailscaleConfig) validate() error {
	if strings.TrimSpace(config.Hostname) == "" {
		return errors.New("tailscale hostname is required")
	}
	if len(config.AllowedUsers) == 0 && len(config.AllowedTags) == 0 {
		return errors.New("tailscale requires an explicit allowedUsers or allowedTags list")
	}
	for _, value := range config.AllowedUsers {
		if strings.TrimSpace(value) == "" || value == "*" {
			return errors.New("tailscale allowedUsers must contain explicit login names")
		}
	}
	for _, tag := range append(append([]string{}, config.AllowedTags...), config.AdvertiseTags...) {
		if !strings.HasPrefix(tag, "tag:") || len(tag) <= 4 || strings.ContainsAny(tag, "* \t\n") {
			return fmt.Errorf("invalid tailscale tag %q", tag)
		}
	}
	if config.ServiceName != "" {
		if err := tailcfg.ServiceName(config.ServiceName).Validate(); err != nil {
			return err
		}
		if len(config.AdvertiseTags) == 0 {
			return errors.New("a Tailscale Service requires a tagged host")
		}
	}
	return nil
}

func (config TailscaleConfig) permits(identity *apitype.WhoIsResponse) bool {
	if identity == nil || identity.Node == nil || identity.UserProfile == nil {
		return false
	}
	if identity.Node.IsTagged() {
		for _, actual := range identity.Node.Tags {
			for _, allowed := range config.AllowedTags {
				if actual == allowed {
					return true
				}
			}
		}
		return false
	}
	for _, allowed := range config.AllowedUsers {
		if identity.UserProfile.LoginName == allowed {
			return true
		}
	}
	return false
}

type tailscaleTransport struct {
	node     *tsnet.Server
	listener net.Listener
	cancel   context.CancelFunc
	once     sync.Once
}

func (t *tailscaleTransport) Close() error {
	var err error
	t.once.Do(func() { t.cancel(); _ = t.listener.Close(); err = t.node.Close() })
	return err
}

func (s *Server) StartTailscale(config TailscaleConfig) (io.Closer, error) {
	if err := config.validate(); err != nil {
		return nil, err
	}
	if config.Port == 0 {
		config.Port = 7243
	}
	if config.StateDirectory == "" {
		config.StateDirectory = filepath.Join(s.directory, "tailscale")
	}
	if err := os.MkdirAll(config.StateDirectory, 0700); err != nil {
		return nil, err
	}
	if err := os.Chmod(config.StateDirectory, 0700); err != nil {
		return nil, err
	}
	authKey := ""
	if config.AuthKeyFile != "" {
		info, err := os.Stat(config.AuthKeyFile)
		if err != nil {
			return nil, err
		}
		if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
			return nil, errors.New("tailscale auth key file must be a private regular file (0600)")
		}
		key, err := os.ReadFile(config.AuthKeyFile)
		if err != nil {
			return nil, err
		}
		authKey = strings.TrimSpace(string(key))
		if authKey == "" {
			return nil, errors.New("tailscale auth key file is empty")
		}
	}
	node := &tsnet.Server{Hostname: config.Hostname, Dir: config.StateDirectory, AuthKey: authKey, ControlURL: config.ControlURL,
		AdvertiseTags: config.AdvertiseTags, UserLogf: log.Printf, Logf: func(string, ...any) {}}
	startup, cancelStartup := context.WithTimeout(context.Background(), 2*time.Minute)
	_, err := node.Up(startup)
	cancelStartup()
	if err != nil {
		_ = node.Close()
		return nil, fmt.Errorf("start tailscale node: %w", err)
	}
	var listener net.Listener
	if config.ServiceName != "" {
		listener, err = node.ListenService(config.ServiceName, tsnet.ServiceModeTCP{Port: config.Port})
	} else {
		listener, err = node.Listen("tcp", fmt.Sprintf(":%d", config.Port))
	}
	if err != nil {
		_ = node.Close()
		return nil, err
	}
	client, err := node.LocalClient()
	if err != nil {
		_ = listener.Close()
		_ = node.Close()
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	transport := &tailscaleTransport{node: node, listener: listener, cancel: cancel}
	authenticating := make(chan struct{}, 32)
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			select {
			case authenticating <- struct{}{}:
			default:
				_ = conn.Close()
				continue
			}
			go func() {
				lookupCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
				var identity *apitype.WhoIsResponse
				var err error
				if config.ServiceName != "" {
					identity, err = client.WhoIsForService(lookupCtx, conn.RemoteAddr().String(), tailcfg.ServiceName(config.ServiceName))
				} else {
					identity, err = client.WhoIs(lookupCtx, conn.RemoteAddr().String())
				}
				cancel()
				<-authenticating
				if err != nil || !config.permits(identity) {
					_ = conn.Close()
					return
				}
				// Never classify this as Unix: remote credential issuance must
				// remain restricted to a genuine local authenticated bootstrap.
				s.serve(&tailscaleConnection{Conn: conn, principal: identity.UserProfile.LoginName})
			}()
		}
	}()
	return transport, nil
}

type tailscaleConnection struct {
	net.Conn
	principal string
}

func (c *tailscaleConnection) LocalAddr() net.Addr {
	return tailscaleAddress(c.Conn.LocalAddr().String())
}

func (c *tailscaleConnection) RemoteAddr() net.Addr {
	return tailscaleAddress(c.principal + "@" + c.Conn.RemoteAddr().String())
}

type tailscaleAddress string

func (a tailscaleAddress) Network() string { return "tailscale" }
func (a tailscaleAddress) String() string  { return string(a) }
