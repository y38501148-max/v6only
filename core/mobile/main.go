//go:build android

package main

/*
#include <stdlib.h>
#include <android/log.h>
#cgo LDFLAGS: -llog
int protect_fd(int fd);
void core_failed(long long generation, char *message);
*/
import "C"
import (
	"encoding/json"
	"fmt"
	core "github.com/y38501148-max/v6only/core"
	"golang.org/x/sys/unix"
	"log"
	"strconv"
	"sync"
	"syscall"
	"unsafe"
)

var mu sync.Mutex
var active *core.Tunnel
var traffic *core.TrafficStore

type androidLogger struct{}

func (androidLogger) Write(p []byte) (int, error) {
	msg := C.CString(string(p))
	tag := C.CString("v6core")
	C.__android_log_write(C.ANDROID_LOG_ERROR, tag, msg)
	C.free(unsafe.Pointer(msg))
	C.free(unsafe.Pointer(tag))
	return len(p), nil
}

//export startCore
func startCore(fd C.int, config *C.char) *C.char {
	log.SetOutput(androidLogger{})
	mu.Lock()
	defer mu.Unlock()
	if active != nil {
		return C.CString("core already running")
	}
	var cfg core.Config
	if e := json.Unmarshal([]byte(C.GoString(config)), &cfg); e != nil {
		return C.CString(e.Error())
	}
	copyFD, e := unix.Dup(int(fd))
	if e != nil {
		return C.CString(e.Error())
	}
	r := core.New(cfg, func(n, a string, raw syscall.RawConn) error {
		var protected bool
		e := raw.Control(func(fd uintptr) { protected = C.protect_fd(C.int(fd)) != 0 })
		if e != nil {
			return e
		}
		if !protected {
			return fmt.Errorf("cannot protect/bind physical socket")
		}
		return nil
	})
	if cfg.StatsDB != "" {
		traffic, e = core.OpenTraffic(cfg.StatsDB)
		if e != nil {
			unix.Close(copyFD)
			r.Close()
			return C.CString(e.Error())
		}
		r.Traffic = traffic
	}
	t, e := r.StartDevice(strconv.Itoa(copyFD), copyFD)
	if e != nil {
		r.Close()
		if traffic != nil {
			traffic.Close()
			traffic = nil
		}
		return C.CString(e.Error())
	}
	active = t
	go func() {
		if e, ok := <-r.WatchDataPlane(); ok {
			message := C.CString(e.Error())
			C.core_failed(C.longlong(cfg.Generation), message)
			C.free(unsafe.Pointer(message))
		}
	}()
	return C.CString("")
}

//export stopCore
func stopCore() {
	mu.Lock()
	defer mu.Unlock()
	if active != nil {
		active.Close()
		active = nil
	}
	if traffic != nil {
		traffic.Close()
		traffic = nil
	}
}

//export coreStats
func coreStats(path *C.char, from, to C.longlong) *C.char {
	mu.Lock()
	defer mu.Unlock()
	var report core.TrafficReport
	var e error
	if traffic != nil {
		report, e = traffic.Report(int64(from), int64(to))
	} else {
		report, e = core.ReadTraffic(C.GoString(path), int64(from), int64(to))
	}
	if e != nil {
		return C.CString(`{"error":"` + "暂无记录" + `"}`)
	}
	b, _ := json.Marshal(report)
	return C.CString(string(b))
}

//export coreFlows
func coreFlows() *C.char {
	mu.Lock()
	defer mu.Unlock()
	if active == nil {
		return C.CString("[]")
	}
	return C.CString(active.Router.JSONFlows(""))
}
func main() {}
