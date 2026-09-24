//go:build android

package main

/*
#include <stdlib.h>
int protect_fd(int fd);
*/
import "C"
import (
	"encoding/json"
	"fmt"
	core "github.com/y38501148-max/v6only/core"
	"golang.org/x/sys/unix"
	"strconv"
	"sync"
	"syscall"
)

var mu sync.Mutex
var active *core.Tunnel

//export startCore
func startCore(fd C.int, config *C.char) *C.char {
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
