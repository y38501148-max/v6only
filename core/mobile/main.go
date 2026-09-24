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
	r.Log = func(f core.Flow) { b, _ := json.Marshal(f); fmt.Println("v6core " + string(b)) }
	t, e := r.StartDevice(strconv.Itoa(copyFD), copyFD)
	if e != nil {
		r.Close()
		unix.Close(copyFD)
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
