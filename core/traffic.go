package v6core

import (
	"database/sql"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

type Bytes struct {
	V4Up   int64 `json:"v4_up"`
	V4Down int64 `json:"v4_down"`
	V6Up   int64 `json:"v6_up"`
	V6Down int64 `json:"v6_down"`
}
type TrafficPoint struct {
	At int64 `json:"at"`
	Bytes
}
type TrafficReport struct {
	From      int64 `json:"from"`
	To        int64 `json:"to"`
	StartedAt int64 `json:"started_at"`
	Bytes
	Points     []TrafficPoint `json:"points"`
	Resolution int64          `json:"resolution"`
}
type TrafficStore struct {
	db      *sql.DB
	mu      sync.Mutex
	flushMu sync.Mutex
	pending map[int64]Bytes
	stop    chan struct{}
	done    chan struct{}
	err     string
}

func OpenTraffic(path string) (*TrafficStore, error) {
	db, e := sql.Open(trafficDriver, trafficDSN(path, true))
	if e != nil {
		return nil, e
	}
	db.SetMaxOpenConns(1)
	_, e = db.Exec(`CREATE TABLE IF NOT EXISTS traffic(at INTEGER PRIMARY KEY,v4_up INTEGER NOT NULL,v4_down INTEGER NOT NULL,v6_up INTEGER NOT NULL,v6_down INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value INTEGER); INSERT OR IGNORE INTO meta VALUES('started_at',strftime('%s','now'));`)
	if e != nil {
		db.Close()
		return nil, e
	}
	s := &TrafficStore{db: db, pending: map[int64]Bytes{}, stop: make(chan struct{}), done: make(chan struct{})}
	go func() {
		defer close(s.done)
		t := time.NewTicker(time.Second)
		defer t.Stop()
		for {
			select {
			case <-s.stop:
				return
			case <-t.C:
				if e := s.Flush(); e != nil {
					s.mu.Lock()
					s.err = e.Error()
					s.mu.Unlock()
				}
			}
		}
	}()
	return s, nil
}
func addBytes(a, b Bytes) Bytes {
	return Bytes{a.V4Up + b.V4Up, a.V4Down + b.V4Down, a.V6Up + b.V6Up, a.V6Down + b.V6Down}
}
func (s *TrafficStore) add(v6, up bool, n int) {
	if n <= 0 {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	at := time.Now().Unix()
	b := s.pending[at]
	if v6 {
		if up {
			b.V6Up += int64(n)
		} else {
			b.V6Down += int64(n)
		}
	} else {
		if up {
			b.V4Up += int64(n)
		} else {
			b.V4Down += int64(n)
		}
	}
	s.pending[at] = b
}
func (s *TrafficStore) Flush() error {
	s.flushMu.Lock()
	defer s.flushMu.Unlock()
	s.mu.Lock()
	batch := s.pending
	s.pending = map[int64]Bytes{}
	s.mu.Unlock()
	if len(batch) == 0 {
		return nil
	}
	e := func() error {
		tx, e := s.db.Begin()
		if e != nil {
			return e
		}
		defer tx.Rollback()
		for at, b := range batch {
			_, e = tx.Exec(`INSERT INTO traffic VALUES(?,?,?,?,?) ON CONFLICT(at) DO UPDATE SET v4_up=v4_up+excluded.v4_up,v4_down=v4_down+excluded.v4_down,v6_up=v6_up+excluded.v6_up,v6_down=v6_down+excluded.v6_down`, at, b.V4Up, b.V4Down, b.V6Up, b.V6Down)
			if e != nil {
				return e
			}
		}
		return tx.Commit()
	}()
	s.mu.Lock()
	defer s.mu.Unlock()
	if e != nil {
		for at, b := range batch {
			s.pending[at] = addBytes(s.pending[at], b)
		}
		s.err = e.Error()
	} else {
		s.err = ""
	}
	return e
}
func (s *TrafficStore) Error() string { s.mu.Lock(); defer s.mu.Unlock(); return s.err }
func (s *TrafficStore) Close() error {
	close(s.stop)
	<-s.done
	e := s.Flush()
	d := s.db.Close()
	if e != nil {
		return e
	}
	return d
}
func (s *TrafficStore) Report(from, to int64) (TrafficReport, error) {
	if e := s.Flush(); e != nil {
		return TrafficReport{}, e
	}
	return ReadTrafficDB(s.db, from, to)
}
func ReadTraffic(path string, from, to int64) (TrafficReport, error) {
	db, e := sql.Open(trafficDriver, trafficDSN(path, false))
	if e != nil {
		return TrafficReport{}, e
	}
	defer db.Close()
	return ReadTrafficDB(db, from, to)
}
func ReadTrafficDB(db *sql.DB, from, to int64) (TrafficReport, error) {
	if from < 0 || to <= from {
		return TrafficReport{}, fmt.Errorf("invalid time range")
	}
	step := int64(60)
	if to-from > 86400*2 {
		step = 3600
	}
	if to-from > 86400*60 {
		step = 86400
	}
	r := TrafficReport{From: from, To: to, Points: []TrafficPoint{}, Resolution: step}
	if e := db.QueryRow(`SELECT value FROM meta WHERE key='started_at'`).Scan(&r.StartedAt); e != nil {
		return r, e
	}
	rows, e := db.Query(`SELECT (at / ?) * ?,SUM(v4_up),SUM(v4_down),SUM(v6_up),SUM(v6_down) FROM traffic WHERE at>=? AND at<? GROUP BY at / ? ORDER BY at / ?`, step, step, from, to, step, step)
	if e != nil {
		return r, e
	}
	defer rows.Close()
	for rows.Next() {
		p := TrafficPoint{}
		if e = rows.Scan(&p.At, &p.V4Up, &p.V4Down, &p.V6Up, &p.V6Down); e != nil {
			return r, e
		}
		r.Bytes = addBytes(r.Bytes, p.Bytes)
		r.Points = append(r.Points, p)
	}
	return r, rows.Err()
}

type countingConn struct {
	net.Conn
	s        *TrafficStore
	v6       bool
	up, down atomic.Int64
}

func (s *TrafficStore) Wrap(c net.Conn) net.Conn {
	host, _, e := net.SplitHostPort(c.RemoteAddr().String())
	if e != nil {
		return c
	}
	ip := net.ParseIP(host)
	if ip == nil || ip.IsLoopback() {
		return c
	}
	wrapped := &countingConn{Conn: c, s: s, v6: ip.To4() == nil}
	if packet, ok := c.(net.PacketConn); ok {
		return &countingPacketConn{wrapped, packet}
	}
	return wrapped
}
func (c *countingConn) Read(b []byte) (int, error) {
	n, e := c.Conn.Read(b)
	c.down.Add(int64(n))
	if c.s != nil {
		c.s.add(c.v6, false, n)
	}
	return n, e
}
func (c *countingConn) Write(b []byte) (int, error) {
	n, e := c.Conn.Write(b)
	c.up.Add(int64(n))
	if c.s != nil {
		c.s.add(c.v6, true, n)
	}
	return n, e
}
func (c *countingConn) CloseWrite() error {
	if v, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return v.CloseWrite()
	}
	return c.Conn.SetReadDeadline(time.Now().Add(2 * time.Second))
}

// Keep net.PacketConn visible to protocol libraries. DNS uses this interface
// to select datagram framing; hiding it would prepend TCP lengths to UDP DNS.
type countingPacketConn struct {
	*countingConn
	packet net.PacketConn
}

func (c *countingPacketConn) ReadFrom(b []byte) (int, net.Addr, error) {
	n, a, e := c.packet.ReadFrom(b)
	c.down.Add(int64(n))
	if c.s != nil {
		c.s.add(c.v6, false, n)
	}
	return n, a, e
}
func (c *countingPacketConn) WriteTo(b []byte, a net.Addr) (int, error) {
	n, e := c.packet.WriteTo(b, a)
	c.up.Add(int64(n))
	if c.s != nil {
		c.s.add(c.v6, true, n)
	}
	return n, e
}

func (c *countingConn) FlowBytes() (int64, int64) { return c.up.Load(), c.down.Load() }
