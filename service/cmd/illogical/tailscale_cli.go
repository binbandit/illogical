package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
)

type discoveredTailscaleService struct {
	Name    string `json:"name"`
	Address string `json:"address"`
	Service string `json:"service"`
}

func discoverTailscaleServices() error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	services, err := (&local.Client{}).GetServices(ctx)
	if err != nil {
		return fmt.Errorf("read Tailscale services: %w", err)
	}
	return json.NewEncoder(os.Stdout).Encode(tailscaleServiceEntries(services))
}

func tailscaleServiceEntries(services map[tailcfg.ServiceName]tailcfg.ServiceDetails) []discoveredTailscaleService {
	result := make([]discoveredTailscaleService, 0)
	for name, service := range services {
		// Service names are explicit registrations, not every online machine.
		if !strings.HasPrefix(string(name), "svc:illogical-") {
			continue
		}
		port := uint16(0)
		for _, candidate := range service.Ports {
			if candidate.Proto == 6 && candidate.Ports.First == candidate.Ports.Last {
				port = candidate.Ports.First
				break
			}
		}
		if port == 0 {
			continue
		}
		for _, address := range service.Addrs {
			if !isTailscaleAddress(address) {
				continue
			}
			label := service.DisplayName
			if label == "" {
				label = strings.TrimPrefix(string(name), "svc:")
			}
			result = append(result, discoveredTailscaleService{Name: label, Service: string(name), Address: "tailscale:" + net.JoinHostPort(address.String(), strconv.Itoa(int(port)))})
			break
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Service < result[j].Service })
	return result
}

func isTailscaleAddress(address netip.Addr) bool {
	address = address.Unmap()
	return netip.MustParsePrefix("100.64.0.0/10").Contains(address) || netip.MustParsePrefix("fd7a:115c:a1e0::/48").Contains(address)
}

func dialTailscale(address string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		host = address
		port = "7243"
	}
	number, err := strconv.ParseUint(port, 10, 16)
	if err != nil || number == 0 || strings.TrimSpace(host) == "" {
		return nil, errors.New("invalid Tailscale service address")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	client := &local.Client{}
	status, err := client.Status(ctx)
	if err != nil {
		return nil, err
	}
	if status.BackendState != "Running" {
		return nil, errors.New("the local Tailscale client is not connected")
	}
	services, err := client.GetServices(ctx)
	if err != nil {
		return nil, err
	}
	addresses := resolveTailnetHost(strings.Trim(host, "[]"), status, services)
	var lastError error
	for _, ip := range addresses {
		// The raw RPC relies on WireGuard peer identity. Never send it to a
		// public/LAN IP just because an untrusted DNS answer named that IP.
		if !isTailscaleAddress(ip) {
			continue
		}
		conn, err := client.DialTCP(ctx, ip.String(), uint16(number))
		if err == nil {
			return conn, nil
		}
		lastError = err
	}
	if lastError != nil {
		return nil, lastError
	}
	return nil, errors.New("address does not resolve to a Tailscale IP; connect the local Tailscale client first")
}

func resolveTailnetHost(host string, status *ipnstate.Status, services map[tailcfg.ServiceName]tailcfg.ServiceDetails) []netip.Addr {
	var result []netip.Addr
	wantedIP, _ := netip.ParseAddr(host)
	appendMatch := func(names []string, addresses []netip.Addr) {
		match := false
		for _, name := range names {
			if strings.EqualFold(strings.TrimSuffix(host, "."), strings.TrimSuffix(name, ".")) {
				match = true
			}
		}
		for _, ip := range addresses {
			if isTailscaleAddress(ip) && (match || wantedIP.IsValid() && ip.Unmap() == wantedIP.Unmap()) {
				result = append(result, ip)
			}
		}
	}
	if status != nil {
		for _, peer := range status.Peer {
			appendMatch([]string{peer.DNSName, strings.Split(peer.DNSName, ".")[0]}, peer.TailscaleIPs)
		}
		if status.Self != nil {
			appendMatch([]string{status.Self.DNSName, strings.Split(status.Self.DNSName, ".")[0]}, status.Self.TailscaleIPs)
		}
	}
	for name, service := range services {
		names := []string{strings.TrimPrefix(string(name), "svc:")}
		if status != nil && status.CurrentTailnet != nil && status.CurrentTailnet.MagicDNSSuffix != "" {
			names = append(names, names[0]+"."+status.CurrentTailnet.MagicDNSSuffix)
		}
		appendMatch(names, service.Addrs)
	}
	return result
}
