package main

import (
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"sync"
	"time"
)

type shotReq struct {
	ConnID  string
	Host    string
	SNI     string
	Proxy   string
	Method  string
	Path    string
	Headers [][2]string
	Body    string
}

type shotResp struct {
	Status  int
	Headers [][2]string
	Body    string
	TSendNS int64
	TAckNS  int64
	Error   string
}

type warmReq struct {
	ConnID      string
	Host        string
	SNI         string
	Proxy       string
	ChromeMajor int
	PingSec     int
}

var (
	mu    sync.Mutex
	conns = map[string]*Conn{}
)

func main() {
	addr := flag.String("addr", "127.0.0.1:8731", "listen address")
	flag.Parse()

	mux := http.NewServeMux()
	mux.HandleFunc("/warm", handleWarm)
	mux.HandleFunc("/shot", handleShot)
	mux.HandleFunc("/close", handleClose)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})
	log.Printf("sidecar listening on %s", *addr)
	log.Fatal(http.ListenAndServe(*addr, mux))
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("content-type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func handleWarm(w http.ResponseWriter, r *http.Request) {
	var q warmReq
	if err := json.NewDecoder(r.Body).Decode(&q); err != nil {
		writeJSON(w, shotResp{Error: err.Error()})
		return
	}
	if q.SNI == "" {
		q.SNI = q.Host
	}
	if q.ChromeMajor == 0 {
		q.ChromeMajor = 131
	}
	c, err := newConn(q.Host, q.SNI, q.Proxy, q.ChromeMajor)
	if err != nil {
		writeJSON(w, shotResp{Error: "warm: " + err.Error()})
		return
	}
	mu.Lock()
	if old, ok := conns[q.ConnID]; ok {
		go old.close()
	}
	conns[q.ConnID] = c
	mu.Unlock()

	if q.PingSec > 0 {
		go func() {
			t := time.NewTicker(time.Duration(q.PingSec) * time.Second)
			defer t.Stop()
			for range t.C {
				if err := c.ping(); err != nil {
					return
				}
			}
		}()
	}
	writeJSON(w, shotResp{Status: 200})
}

func handleShot(w http.ResponseWriter, r *http.Request) {
	var q shotReq
	if err := json.NewDecoder(r.Body).Decode(&q); err != nil {
		writeJSON(w, shotResp{Error: err.Error()})
		return
	}
	mu.Lock()
	c := conns[q.ConnID]
	mu.Unlock()
	if c == nil {
		writeJSON(w, shotResp{Error: "unknown connid"})
		return
	}
	res, err := c.shot(q.Method, q.Path, q.Headers, []byte(q.Body))
	if err != nil {
		writeJSON(w, shotResp{Error: err.Error()})
		return
	}
	writeJSON(w, shotResp{
		Status:  res.Status,
		Headers: res.Headers,
		Body:    string(res.Body),
		TSendNS: res.TSendNS,
		TAckNS:  res.TAckNS,
	})
}

func handleClose(w http.ResponseWriter, r *http.Request) {
	var q shotReq
	json.NewDecoder(r.Body).Decode(&q)
	mu.Lock()
	c := conns[q.ConnID]
	delete(conns, q.ConnID)
	mu.Unlock()
	if c != nil {
		c.close()
	}
	writeJSON(w, shotResp{Status: 200})
}