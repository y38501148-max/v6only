package v6core

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func updateFixture(tag string) releaseInfo {
	v := strings.TrimPrefix(tag, "v")
	r := releaseInfo{Tag: tag}
	for _, suffix := range []string{"Windows-x64.msi", "macOS-arm64.dmg", "Android.apk"} {
		name := "V6Only-" + v + "-" + suffix
		r.Assets = append(r.Assets, releaseAsset{Name: name, URL: releaseBase + "download/" + tag + "/" + name, Size: 100, State: "uploaded"})
	}
	return r
}

func TestUpdateVersionAndPlatform(t *testing.T) {
	for _, platform := range []string{"windows-x64", "macos-arm64", "android"} {
		info, err := releaseUpdate("2.1.9", platform, updateFixture("v2.1.11"))
		if err != nil || !info.Available || !info.PackageAvailable || !strings.HasPrefix(info.DownloadURL, releaseBase) {
			t.Fatal(info, err)
		}
	}
	for _, pair := range [][2]string{{"2.1.11", "v2.1.11"}, {"2.1.12", "v2.1.11"}, {"3.0.0", "v2.99.99"}} {
		info, err := releaseUpdate(pair[0], "android", updateFixture(pair[1]))
		if err != nil || info.Available {
			t.Fatal(info, err)
		}
	}
	info, err := releaseUpdate("2.9.99", "android", updateFixture("v2.10.0"))
	if err != nil || !info.Available {
		t.Fatal("lexical version comparison", info, err)
	}
	for _, version := range []string{"2.1.11-beta", "2.1", "02.1.11", "2.1.11?x=1", "9999999999999999999999.0.0"} {
		if _, err := releaseUpdate("2.1.11", "android", updateFixture(version)); err == nil {
			t.Fatal("accepted invalid version", version)
		}
	}
	if _, err := releaseUpdate("2.1.11", "linux", updateFixture("v2.1.12")); err == nil {
		t.Fatal("unsupported platform")
	}
}

func TestUpdateOnlyAdvertisesUploadedTrustedInstaller(t *testing.T) {
	for _, mode := range []string{"draft", "prerelease", "missing", "empty", "uploading", "wrong_host", "wrong_version", "wrong_platform"} {
		t.Run(mode, func(t *testing.T) {
			r := updateFixture("v2.1.12")
			switch mode {
			case "draft":
				r.Draft = true
			case "prerelease":
				r.Prerelease = true
			case "missing":
				r.Assets = nil
			case "empty":
				r.Assets[2].Size = 0
			case "uploading":
				r.Assets[2].State = "new"
			case "wrong_host":
				r.Assets[2].URL = "https://evil.test/package.apk"
			case "wrong_version":
				r.Assets[2].URL = strings.ReplaceAll(r.Assets[2].URL, "2.1.12", "2.1.13")
			case "wrong_platform":
				r.Assets = r.Assets[:2]
			}
			info, err := releaseUpdate("2.1.11", "android", r)
			if err != nil || info.Available {
				t.Fatal(info, err)
			}
			if mode == "missing" && info.ReleaseURL == "" {
				t.Fatal("missing installer must not masquerade as latest")
			}
		})
	}
}

func TestUpdateHTTPBoundaries(t *testing.T) {
	for _, mode := range []string{"ok", "rate_limit", "malformed", "oversized", "redirect", "timeout"} {
		t.Run(mode, func(t *testing.T) {
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("User-Agent") != "V6Only/2.1.11" || r.Header.Get("Accept") != "application/vnd.github+json" {
					t.Error("missing metadata headers")
				}
				switch mode {
				case "rate_limit":
					w.WriteHeader(403)
				case "malformed":
					w.Write([]byte("not json"))
				case "oversized":
					w.Write([]byte(strings.Repeat(" ", 512*1024+1)))
				case "redirect":
					w.Header().Set("Location", "https://evil.test/")
					w.WriteHeader(302)
				case "timeout":
					<-r.Context().Done()
				default:
					json.NewEncoder(w).Encode(updateFixture("v2.1.12"))
				}
			}))
			defer s.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
			defer cancel()
			client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
			info, err := checkUpdate(ctx, client, s.URL, "2.1.11", "android")
			if mode == "ok" {
				if err != nil || !info.Available {
					t.Fatal(info, err)
				}
			} else if err == nil {
				t.Fatal("accepted invalid response", mode)
			}
		})
	}
}
