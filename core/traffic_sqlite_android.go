//go:build android

package v6core

import _ "github.com/mattn/go-sqlite3"

// Bionic's native SQLite file operations use Android-compatible syscall wrappers.
// The desktop pure-Go libc calls lstat(6) on x86_64, blocked by Android seccomp.
const trafficDriver = "sqlite3"

func trafficDSN(path string, write bool) string {
	if write {
		return "file:" + path + "?_busy_timeout=5000&_journal_mode=WAL&_synchronous=FULL"
	}
	return "file:" + path + "?mode=ro&_busy_timeout=5000"
}
