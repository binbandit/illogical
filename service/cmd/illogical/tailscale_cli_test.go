package main

import (
	"net/netip"
	"testing"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
)

func TestTailscaleDiscoveryOnlyOffersRegisteredTerminalServices(t *testing.T) {
	service := func(address string, proto int, first, last uint16) tailcfg.ServiceDetails {
		return tailcfg.ServiceDetails{Addrs: []netip.Addr{netip.MustParseAddr(address)}, Ports: []tailcfg.ProtoPortRange{{Proto: proto, Ports: tailcfg.PortRange{First: first, Last: last}}}}
	}
	services := map[tailcfg.ServiceName]tailcfg.ServiceDetails{
		"svc:illogical-work":   service("100.100.1.1", 6, 7243, 7243),
		"svc:unrelated":        service("100.100.1.2", 6, 7243, 7243),
		"svc:illogical-public": service("192.0.2.1", 6, 7243, 7243),
		"svc:illogical-udp":    service("100.100.1.3", 17, 7243, 7243),
		"svc:illogical-range":  service("100.100.1.4", 6, 1, 65535),
		"svc:illogical-ipv6":   service("fd7a:115c:a1e0::1", 6, 1234, 1234),
	}
	got := tailscaleServiceEntries(services)
	if len(got) != 2 || got[0].Address != "tailscale:[fd7a:115c:a1e0::1]:1234" || got[1].Address != "tailscale:100.100.1.1:7243" {
		t.Fatalf("unexpected discovery: %+v", got)
	}
}

func TestTailscaleRoutingRequiresTrustedNetworkMap(t *testing.T) {
	peerIP := netip.MustParseAddr("100.90.1.2")
	serviceIP := netip.MustParseAddr("100.100.1.1")
	status := &ipnstate.Status{CurrentTailnet: &ipnstate.TailnetStatus{MagicDNSSuffix: "example.ts.net"}, Peer: map[key.NodePublic]*ipnstate.PeerStatus{
		{}: {DNSName: "work.example.ts.net.", TailscaleIPs: []netip.Addr{peerIP}},
	}}
	services := map[tailcfg.ServiceName]tailcfg.ServiceDetails{"svc:illogical-work": {Addrs: []netip.Addr{serviceIP}}}
	for _, name := range []string{"work", "WORK.EXAMPLE.TS.NET.", "100.90.1.2"} {
		got := resolveTailnetHost(name, status, services)
		if len(got) != 1 || got[0] != peerIP {
			t.Fatalf("%q: %v", name, got)
		}
	}
	for _, name := range []string{"illogical-work", "illogical-work.example.ts.net", "100.100.1.1"} {
		got := resolveTailnetHost(name, status, services)
		if len(got) != 1 || got[0] != serviceIP {
			t.Fatalf("%q: %v", name, got)
		}
	}
	for _, name := range []string{"100.90.1.3", "192.168.0.1", "example.com", "work.example.com"} {
		if got := resolveTailnetHost(name, status, services); len(got) != 0 {
			t.Fatalf("untrusted destination %q resolved: %v", name, got)
		}
	}
}
