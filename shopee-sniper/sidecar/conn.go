package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"sync"
	"time"

	utls "github.com/refraction-networking/utls"
	"golang.org/x/net/http2/hpack"
)

const (
	frData         = 0x0
	frHeaders      = 0x1
	frPriority     = 0x2
	frSettings     = 0x4
	frPing         = 0x6
	frGoaway       = 0x7
	frWindowUpdate = 0x8

	flAck        = 0x1
	flEndStream  = 0x1
	flEndHeaders = 0x4
	h2Preface    = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
	chromeWinUp  = 15663105
	chromeMaxHdr = 262144
)

type Result struct {
	Status  int
	Headers [][2]string
	Body    []byte
	TSendNS int64
	TAckNS  int64
}

type Conn struct {
	mu       sync.Mutex
	tc       *tsConn
	u        *utls.UConn
	br       *bufio.Reader
	nextSID  uint32
	inflight *Result
	done     chan struct{}
	err      error
	closed   bool
	host     string
}

func newConn(host, sni, proxy string, chromeMajor int) (*Conn, error) {
	tc, u, err := dialTLS(host, sni, proxy, chromeMajor)
	if err != nil {
		return nil, err
	}
	c := &Conn{tc: tc, u: u, br: bufio.NewReaderSize(u, 64*1024),
		nextSID: 1, done: make(chan struct{}), host: host}
	if _, err := u.Write([]byte(h2Preface)); err != nil {
		return nil, err
	}
	if err := c.writeChromeSettings(); err != nil {
		return nil, err
	}
	go c.readLoop()
	return c, nil
}

func (c *Conn) writeChromeSettings() error {
	var p bytes.Buffer
	for _, kv := range [][2]uint32{
		{0x1, 65536}, {0x2, 0}, {0x3, 1000},
		{0x4, 6291456}, {0x6, chromeMaxHdr},
	} {
		binary.Write(&p, binary.BigEndian, uint16(kv[0]))
		binary.Write(&p, binary.BigEndian, kv[1])
	}
	if err := c.frame(frSettings, 0, 0, p.Bytes()); err != nil {
		return err
	}
	var wu bytes.Buffer
	binary.Write(&wu, binary.BigEndian, uint32(chromeWinUp))
	if err := c.frame(frWindowUpdate, 0, 0, wu.Bytes()); err != nil {
		return err
	}
	var pr bytes.Buffer
	binary.Write(&pr, binary.BigEndian, uint32(0))
	pr.WriteByte(201)
	binary.Write(&pr, binary.BigEndian, uint32(0))
	return c.frame(frPriority, 0, 0, pr.Bytes())
}

func (c *Conn) frame(typ byte, flags byte, sid uint32, payload []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.frameLocked(typ, flags, sid, payload)
}

func (c *Conn) frameLocked(typ byte, flags byte, sid uint32, payload []byte) error {
	h := make([]byte, 9)
	n := len(payload)
	h[0], h[1], h[2] = byte(n>>16), byte(n>>8), byte(n)
	h[3] = typ
	h[4] = flags
	binary.BigEndian.PutUint32(h[5:], sid&0x7fffffff)
	if _, err := c.u.Write(h); err != nil {
		return err
	}
	if n == 0 {
		return nil
	}
	_, err := c.u.Write(payload)
	return err
}

func (c *Conn) writeRequest(method, path, authority string, hdrs [][2]string, body []byte) (uint32, error) {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return 0, errors.New("conn closed")
	}
	sid := c.nextSID
	c.nextSID += 2

	var hb bytes.Buffer
	enc := hpack.NewEncoder(&hb)
	enc.SetMaxDynamicTableSize(65536)
	for _, f := range [][2]string{
		{":method", method}, {":authority", authority},
		{":scheme", "https"}, {":path", path},
	} {
		if err := enc.WriteField(hpack.HeaderField{Name: f[0], Value: f[1]}); err != nil {
			c.mu.Unlock()
			return 0, err
		}
	}
	for _, f := range hdrs {
		name := strings.ToLower(f[0])
		if strings.HasPrefix(name, ":") {
			continue
		}
		if err := enc.WriteField(hpack.HeaderField{Name: name, Value: f[1]}); err != nil {
			c.mu.Unlock()
			return 0, err
		}
	}
	flags := byte(flEndHeaders)
	if len(body) == 0 {
		flags |= flEndStream
	}
	if err := c.frameLocked(frHeaders, flags, sid, hb.Bytes()); err != nil {
		c.mu.Unlock()
		return 0, err
	}
	if len(body) > 0 {
		c.tc.Arm()
		c.mu.Unlock()
		if err := c.frame(frData, flEndStream, sid, body); err != nil {
			return 0, err
		}
		return sid, nil
	}
	c.mu.Unlock()
	return sid, nil
}

func (c *Conn) readLoop() {
	defer close(c.done)
	var bodyBuf bytes.Buffer
	var hdr [9]byte
	for {
		if _, err := io.ReadFull(c.br, hdr[:]); err != nil {
			c.err = err
			return
		}
		n := int(hdr[0])<<16 | int(hdr[1])<<8 | int(hdr[2])
		typ := hdr[3]
		flags := hdr[4]
		sid := binary.BigEndian.Uint32(hdr[5:]) & 0x7fffffff
		payload := make([]byte, n)
		if n > 0 {
			if _, err := io.ReadFull(c.br, payload); err != nil {
				c.err = err
				return
			}
		}
		switch typ {
		case frSettings:
			if flags&flAck == 0 {
				c.frame(frSettings, flAck, 0, nil)
			}
		case frPing:
			if flags&flAck == 0 {
				c.frame(frPing, flAck, 0, payload)
			}
		case frGoaway:
			c.mu.Lock()
			c.closed = true
			c.mu.Unlock()
		case frHeaders:
			c.mu.Lock()
			if c.inflight != nil && sid == c.nextSID-2 {
				c.parseHeaders(payload)
			}
			c.mu.Unlock()
		case frData:
			c.mu.Lock()
			if c.inflight != nil && sid == c.nextSID-2 {
				bodyBuf.Write(payload)
				if flags&flEndStream != 0 {
					c.inflight.Body = append([]byte(nil), bodyBuf.Bytes()...)
					bodyBuf.Reset()
					c.inflight.TAckNS = c.tc.AckNS()
					c.inflight = nil
				}
			}
			c.mu.Unlock()
			c.frame(frWindowUpdate, 0, 0, winInc(len(payload)))
		}
		if flags&flEndStream != 0 && typ == frHeaders {
			c.mu.Lock()
			if c.inflight != nil && sid == c.nextSID-2 {
				c.inflight.TAckNS = c.tc.AckNS()
				c.inflight = nil
			}
			c.mu.Unlock()
		}
	}
}

func winInc(n int) []byte {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, uint32(n))
	return b
}

func (c *Conn) parseHeaders(payload []byte) {
	dec := hpack.NewDecoder(4096, nil)
	fields, err := dec.DecodeFull(payload)
	if err != nil {
		return
	}
	for _, f := range fields {
		if f.Name == ":status" {
			if v, err := strconv.Atoi(f.Value); err == nil {
				c.inflight.Status = v
			}
		} else {
			c.inflight.Headers = append(c.inflight.Headers, [2]string{f.Name, f.Value})
		}
	}
}

func (c *Conn) shot(method, path string, hdrs [][2]string, body []byte) (*Result, error) {
	res := &Result{}
	c.mu.Lock()
	if c.inflight != nil {
		c.mu.Unlock()
		return nil, errors.New("conn busy")
	}
	c.inflight = res
	c.mu.Unlock()

	if _, err := c.writeRequest(method, path, c.host, hdrs, body); err != nil {
		return nil, err
	}
	res.TSendNS = time.Now().UnixNano()

	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		c.mu.Lock()
		fin := c.inflight == nil
		e := c.err
		c.mu.Unlock()
		if fin {
			return res, nil
		}
		if e != nil {
			return nil, e
		}
		time.Sleep(300 * time.Microsecond)
	}
	return nil, fmt.Errorf("shot timeout")
}

func (c *Conn) ping() error {
	return c.frame(frPing, 0, 0, make([]byte, 8))
}

func (c *Conn) close() {
	c.mu.Lock()
	c.closed = true
	c.mu.Unlock()
	c.frame(frGoaway, 0, 0, make([]byte, 8))
	c.u.Close()
}