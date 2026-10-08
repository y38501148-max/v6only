//go:build !android

package v6core

import _ "modernc.org/sqlite"

const trafficDriver = "sqlite"

func trafficDSN(path string, write bool) string {
	if write {
		return "file:" + path + "?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=synchronous(FULL)"
	}
	return "file:" + path + "?mode=ro&_pragma=busy_timeout(5000)"
}
