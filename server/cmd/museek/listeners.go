package main

import (
	"fmt"
	"net"
	"net/http"
)

// Bind the public socket first and require every listener to bind successfully
// before serving. Overlapping configuration must never race to expose private
// routes on the public address.
func bindServers(servers []*http.Server) ([]net.Listener, error) {
	listeners := make([]net.Listener, 0, len(servers))
	for _, server := range servers {
		listener, err := net.Listen("tcp", server.Addr)
		if err != nil {
			for _, prior := range listeners {
				_ = prior.Close()
			}
			return nil, fmt.Errorf("listen %s: %w", server.Addr, err)
		}
		listeners = append(listeners, listener)
	}
	return listeners, nil
}
