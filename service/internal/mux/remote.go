package mux

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"time"

	quic "github.com/quic-go/quic-go"
)

// Credentials travel only over the existing authenticated SSH connection.
// They authorize one Unix user's service, never a privileged login broker.
type RemoteCredentials struct {
	Address     string `json:"address"`
	Authority   string `json:"authority"`
	Certificate string `json:"certificate"`
	PrivateKey  string `json:"privateKey"`
}

type remoteListener struct {
	listener    *quic.Listener
	authority   *x509.Certificate
	key         *ecdsa.PrivateKey
	certificate []byte
}

type quicStream struct {
	*quic.Stream
	connection *quic.Conn
}

func (c *quicStream) LocalAddr() net.Addr  { return c.connection.LocalAddr() }
func (c *quicStream) RemoteAddr() net.Addr { return c.connection.RemoteAddr() }
func (c *quicStream) Close() error {
	c.CancelRead(0)
	_ = c.Stream.Close()
	return c.connection.CloseWithError(0, "client detached")
}

func serialNumber() *big.Int {
	value, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	return value
}

func (s *Server) pairRemote(address string) (*RemoteCredentials, error) {
	ip := net.ParseIP(address)
	if ip == nil || ip.IsUnspecified() || ip.IsMulticast() {
		return nil, errors.New("a concrete host IP is required for QUIC")
	}
	remote := s.remotes[address]
	if remote == nil {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return nil, err
		}
		template := &x509.Certificate{SerialNumber: serialNumber(), Subject: pkix.Name{CommonName: "illogical user service"}, DNSNames: []string{"illogical.internal"}, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().AddDate(1, 0, 0), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth}}
		der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
		if err != nil {
			return nil, err
		}
		authority, err := x509.ParseCertificate(der)
		if err != nil {
			return nil, err
		}
		pool := x509.NewCertPool()
		pool.AddCert(authority)
		listener, err := quic.ListenAddr(net.JoinHostPort(address, "0"), &tls.Config{MinVersion: tls.VersionTLS13, NextProtos: []string{"illogical/1"}, Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}, ClientAuth: tls.RequireAndVerifyClientCert, ClientCAs: pool}, &quic.Config{MaxIncomingStreams: 1, MaxIncomingUniStreams: -1, HandshakeIdleTimeout: 5 * time.Second, MaxIdleTimeout: 45 * time.Second, KeepAlivePeriod: 15 * time.Second})
		if err != nil {
			return nil, err
		}
		remote = &remoteListener{listener: listener, authority: authority, key: key, certificate: der}
		s.remotes[address] = remote
		go func() {
			for {
				connection, err := listener.Accept(context.Background())
				if err != nil {
					return
				}
				go func() {
					ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
					defer cancel()
					stream, err := connection.AcceptStream(ctx)
					if err != nil {
						_ = connection.CloseWithError(1, "stream required")
						return
					}
					s.serve(&quicStream{Stream: stream, connection: connection})
				}()
			}
		}()
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	template := &x509.Certificate{SerialNumber: serialNumber(), Subject: pkix.Name{CommonName: "illogical SSH-authenticated client"}, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(15 * time.Minute), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, remote.authority, &key.PublicKey, remote.key)
	if err != nil {
		return nil, err
	}
	encodedKey, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, err
	}
	encode := func(kind string, data []byte) string {
		return string(pem.EncodeToMemory(&pem.Block{Type: kind, Bytes: data}))
	}
	return &RemoteCredentials{Address: remote.listener.Addr().String(), Authority: encode("CERTIFICATE", remote.certificate), Certificate: encode("CERTIFICATE", der), PrivateKey: encode("PRIVATE KEY", encodedKey)}, nil
}

func DialRemote(ctx context.Context, credentials RemoteCredentials) (net.Conn, error) {
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM([]byte(credentials.Authority)) {
		return nil, errors.New("invalid service authority")
	}
	certificate, err := tls.X509KeyPair([]byte(credentials.Certificate), []byte(credentials.PrivateKey))
	if err != nil {
		return nil, err
	}
	connection, err := quic.DialAddr(ctx, credentials.Address, &tls.Config{MinVersion: tls.VersionTLS13, ServerName: "illogical.internal", RootCAs: pool, Certificates: []tls.Certificate{certificate}, NextProtos: []string{"illogical/1"}}, &quic.Config{MaxIdleTimeout: 45 * time.Second, KeepAlivePeriod: 15 * time.Second})
	if err != nil {
		return nil, err
	}
	stream, err := connection.OpenStreamSync(ctx)
	if err != nil {
		_ = connection.CloseWithError(1, "stream unavailable")
		return nil, err
	}
	// Opening a QUIC stream is lazy. One whitespace byte makes it visible to
	// the peer before waiting for the protocol's server-first greeting.
	if _, err = stream.Write([]byte(" ")); err != nil {
		_ = connection.CloseWithError(1, "stream unavailable")
		return nil, err
	}
	return &quicStream{Stream: stream, connection: connection}, nil
}
