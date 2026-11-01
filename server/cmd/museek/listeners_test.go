package main

import (
	"net"
	"net/http"
	"testing"
)

func TestBindServersRejectsOverlappingListenersAndCleansUp(t *testing.T) {
	reserved, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := reserved.Addr().String()
	reserved.Close()
	_, err = bindServers([]*http.Server{{Addr: address}, {Addr: address}})
	if err == nil {
		t.Fatal("overlapping public and private listeners accepted")
	}
	listener, err := net.Listen("tcp", address)
	if err != nil {
		t.Fatalf("partial listener leaked: %v", err)
	}
	listener.Close()
}

func TestBindServersBindsSeparateSockets(t *testing.T) {
	listeners, err := bindServers([]*http.Server{{Addr: "127.0.0.1:0"}, {Addr: "127.0.0.1:0"}})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, listener := range listeners {
			listener.Close()
		}
	}()
	if len(listeners) != 2 || listeners[0].Addr().String() == listeners[1].Addr().String() {
		t.Fatal("listeners not separate")
	}
}
