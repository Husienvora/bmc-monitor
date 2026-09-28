// bmcrelay-guest runs INSIDE the Android emulator (via adb shell).
// It listens on 127.0.0.1:5354 for JSON lines describing Blackmagic Camera
// remote-camera services found on the real LAN, and re-advertises them via
// mDNS inside the emulator so the Blackmagic Camera app can discover them.
//
// Records are diffed: an unchanged record is left alone (no goodbye/re-announce),
// because a goodbye packet makes the app drop its connection to that camera.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os"
	"sort"
	"strings"
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

type entry struct {
	sig string
	srv *zeroconf.Server
}

var (
	mu      sync.Mutex
	current = map[string]*entry{} // key: service|instance
)

func (s Svc) key() string { return s.Service + "|" + s.Instance }

func (s Svc) sig() string {
	ips := append([]string(nil), s.IPs...)
	txt := append([]string(nil), s.TXT...)
	sort.Strings(ips)
	sort.Strings(txt)
	return fmt.Sprintf("%s|%d|%s|%s", s.Host, s.Port, strings.Join(ips, ","), strings.Join(txt, ","))
}

func apply(m Msg) (added, changed, removed, kept int) {
	mu.Lock()
	defer mu.Unlock()
	want := map[string]Svc{}
	for _, s := range m.Services {
		want[s.key()] = s
	}
	// Drop records that vanished or changed.
	for k, e := range current {
		s, ok := want[k]
		if ok && s.sig() == e.sig {
			kept++
			continue
		}
		e.srv.Shutdown()
		delete(current, k)
		if ok {
			changed++
		} else {
			removed++
			log.Printf("withdrawn %s", k)
		}
	}
	// Register new / changed records.
	for k, s := range want {
		if _, ok := current[k]; ok {
			continue
		}
		srv, err := zeroconf.RegisterProxy(s.Instance, s.Service, "local.", s.Port, s.Host, s.IPs, s.TXT, nil)
		if err != nil {
			log.Printf("register %q failed: %v", s.Instance, err)
			continue
		}
		current[k] = &entry{sig: s.sig(), srv: srv}
		added++
		log.Printf("advertising %s (%s) -> %v:%d", s.Instance, s.Service, s.IPs, s.Port)
	}
	return
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
				a, ch, r, k := apply(m)
				fmt.Fprintf(c, "ok added=%d changed=%d removed=%d kept=%d\n", a+ch, ch, r, k)
			}
		}(c)
	}
}
