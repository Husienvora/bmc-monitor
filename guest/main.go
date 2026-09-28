// bmcrelay-guest runs INSIDE the Android emulator (via adb shell).
// It listens on 127.0.0.1:5354 for JSON lines describing Blackmagic Camera
// remote-camera services found on the real LAN, and re-advertises them via
// mDNS inside the emulator so the Blackmagic Camera app can discover them.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"sync"

	"github.com/grandcat/zeroconf"
)

type Svc struct {
	Instance string   `json:"instance"`
	Service  string   `json:"service"`
	Port     int      `json:"port"`
	Host     string   `json:"host"`
	IPs      []string `json:"ips"`
	TXT      []string `json:"txt"`
}

type Msg struct {
	Services []Svc `json:"services"`
}

var (
	mu      sync.Mutex
	servers []*zeroconf.Server
)

func apply(m Msg) {
	mu.Lock()
	defer mu.Unlock()
	for _, s := range servers {
		s.Shutdown()
	}
	servers = nil
	for _, s := range m.Services {
		srv, err := zeroconf.RegisterProxy(s.Instance, s.Service, "local.", s.Port, s.Host, s.IPs, s.TXT, nil)
		if err != nil {
			log.Printf("register %q failed: %v", s.Instance, err)
			continue
		}
		servers = append(servers, srv)
		log.Printf("advertising %s (%s) -> %v:%d", s.Instance, s.Service, s.IPs, s.Port)
	}
	if len(m.Services) == 0 {
		log.Printf("no services; cleared")
	}
}

func main() {
	addr := "127.0.0.1:5354"
	if len(os.Args) > 1 {
		addr = os.Args[1]
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("listen %s: %v", addr, err)
	}
	fmt.Println("bmcrelay-guest listening on", addr)
	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go func(c net.Conn) {
			defer c.Close()
			sc := bufio.NewScanner(c)
			sc.Buffer(make([]byte, 1<<20), 1<<20)
			for sc.Scan() {
				var m Msg
				if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
					log.Printf("bad json: %v", err)
					continue
				}
				apply(m)
				fmt.Fprintln(c, "ok")
			}
		}(c)
	}
}
