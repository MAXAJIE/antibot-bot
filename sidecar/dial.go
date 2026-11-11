package main

import (
	"crypto/tls"
	"fmt"
	"net"
	"syscall"
	"time"

	utls "github.com/refraction-networking/utls"
)

const (
	tcpFastOpenConnect = 25
	soTimestampNS      = 35
	scmTimestampNS     = 35
	soBusyPoll         = 46
)

func sockOpts(network, addr string, c syscall.RawConn) error {
	var inner error
	err := c.Control(func(fd uintptr) {
		h := syscall.Handle(fd)
		must := func(e error) {
			if e != nil && inner == nil {
				inner = e
			}
		}
		must(syscall.SetsockoptInt(h, syscall.IPPROTO_TCP, syscall.TCP_NODELAY, 1))
		must(syscall.SetsockoptInt(h, syscall.SOL_SOCKET, soTimestampNS, 1))
		must(syscall.SetsockoptInt(h, syscall.SOL_SOCKET, soBusyPoll, 50000))
		must(syscall.SetsockoptInt(h, syscall.IPPROTO_TCP, tcpFastOpenConnect, 1))
	})
	if err != nil {
		return err
	}
	return inner
}

type tsConn struct {
	net.Conn
	armed  bool
	ackNS  int64
	stamps bool
}

func (c *tsConn) Arm() { c.armed = true; c.ackNS = 0 }

func (c *tsConn) AckNS() int64 { return c.ackNS }

func (c *tsConn) Read(p []byte) (int, error) {
	if !c.armed || c.ackNS != 0 {
		return c.Conn.Read(p)
	}
	sc, ok := c.Conn.(syscall.Conn)
	if !ok {
		n, err := c.Conn.Read(p)
		c.ackNS = time.Now().UnixNano()
		c.armed = false
		return n, err
	}
	rc, err := sc.SyscallConn()
	if err != nil {
		n, err2 := c.Conn.Read(p)
		c.ackNS = time.Now().UnixNano()
		c.armed = false
		return n, err2
	}
	var n int
	var rerr error
	buf := make([]byte, 128)
	rc.Read(func(fd uintptr) bool {
		n, rerr = syscall.Read(int(fd), buf)
		if rerr == syscall.EAGAIN {
			return false
		}
		return true
	})
	if rerr != nil {
		return 0, rerr
	}
	// Windows does not support SO_TIMESTAMPNS via Recvmsg; fall back to wall clock
	if c.ackNS == 0 {
		c.ackNS = time.Now().UnixNano()
	}
	c.armed = false
	copy(p, buf[:n])
	return n, nil
}

func dialRaw(hostport, proxy string) (*tsConn, error) {
	d := &net.Dialer{Timeout: 8 * time.Second, Control: sockOpts}
	var nc net.Conn
	var err error
	if proxy == "" {
		nc, err = d.Dial("tcp", hostport)
	} else {
		var pnc net.Conn
		pnc, err = d.Dial("tcp", proxy)
		if err == nil {
			if cerr := httpConnect(pnc, hostport); cerr != nil {
				pnc.Close()
				err = cerr
			} else {
				nc = pnc
			}
		}
	}
	if err != nil {
		return nil, err
	}
	return &tsConn{Conn: nc}, nil
}

func httpConnect(c net.Conn, hostport string) error {
	req := fmt.Sprintf("CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", hostport, hostport)
	if _, err := c.Write([]byte(req)); err != nil {
		return err
	}
	buf := make([]byte, 0, 256)
	one := make([]byte, 1)
	for len(buf) < 256 {
		if _, err := c.Read(one); err != nil {
			return err
		}
		buf = append(buf, one[0])
		if len(buf) >= 4 && string(buf[len(buf)-4:]) == "\r\n\r\n" {
			if buf[9] != '2' {
				return fmt.Errorf("CONNECT rejected: %q", string(buf))
			}
			return nil
		}
	}
	return fmt.Errorf("CONNECT response too long")
}

func dialTLS(hostport, sni, proxy string, chromeMajor int) (*tsConn, *utls.UConn, error) {
	tc, err := dialRaw(hostport, proxy)
	if err != nil {
		return nil, nil, err
	}
	cfg := &utls.Config{
		ServerName: sni,
		NextProtos: []string{"h2"},
		MinVersion: tls.VersionTLS12,
	}
	u := utls.UClient(tc, cfg, helloID(chromeMajor))
	if err := u.Handshake(); err != nil {
		tc.Close()
		return nil, nil, err
	}
	return tc, u, nil
}

func helloID(major int) utls.ClientHelloID {
	_ = major
	return utls.HelloChrome_Auto
}