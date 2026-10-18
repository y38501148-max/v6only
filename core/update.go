package v6core

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const latestReleaseAPI = "https://api.github.com/repos/y38501148-max/v6only/releases/latest"
const releaseBase = "https://github.com/y38501148-max/v6only/releases/"

type UpdateInfo struct {
	CurrentVersion   string `json:"current_version"`
	LatestVersion    string `json:"latest_version"`
	Platform         string `json:"platform"`
	Available        bool   `json:"available"`
	PackageAvailable bool   `json:"package_available"`
	DownloadURL      string `json:"download_url,omitempty"`
	ReleaseURL       string `json:"release_url,omitempty"`
}

type releaseAsset struct {
	Name  string `json:"name"`
	URL   string `json:"browser_download_url"`
	Size  int64  `json:"size"`
	State string `json:"state"`
}
type releaseInfo struct {
	Tag        string         `json:"tag_name"`
	Draft      bool           `json:"draft"`
	Prerelease bool           `json:"prerelease"`
	Assets     []releaseAsset `json:"assets"`
}

var stableVersion = regexp.MustCompile(`^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`)

func versionParts(version string) ([3]uint64, error) {
	var parts [3]uint64
	matches := stableVersion.FindStringSubmatch(version)
	if matches == nil {
		return parts, fmt.Errorf("invalid stable version")
	}
	for i := range parts {
		n, err := strconv.ParseUint(matches[i+1], 10, 64)
		if err != nil {
			return parts, err
		}
		parts[i] = n
	}
	return parts, nil
}

func releaseUpdate(current, platform string, release releaseInfo) (UpdateInfo, error) {
	info := UpdateInfo{CurrentVersion: current, Platform: platform}
	suffix := map[string]string{"windows-x64": "Windows-x64.msi", "macos-arm64": "macOS-arm64.dmg", "android": "Android.apk"}[platform]
	if suffix == "" {
		return info, fmt.Errorf("unsupported update platform")
	}
	installed, err := versionParts(current)
	if err != nil {
		return info, err
	}
	if release.Draft || release.Prerelease {
		return info, nil
	}
	latest, err := versionParts(release.Tag)
	if err != nil {
		return info, err
	}
	info.LatestVersion = strings.TrimPrefix(release.Tag, "v")
	newer := false
	for i := range installed {
		if latest[i] != installed[i] {
			newer = latest[i] > installed[i]
			break
		}
	}
	if !newer {
		return info, nil
	}
	info.ReleaseURL = releaseBase + "tag/" + release.Tag
	name := "V6Only-" + info.LatestVersion + "-" + suffix
	expected := releaseBase + "download/" + release.Tag + "/" + name
	for _, asset := range release.Assets {
		if asset.Name == name && asset.URL == expected && asset.Size > 0 && asset.State == "uploaded" {
			info.Available = true
			info.PackageAvailable = true
			info.DownloadURL = expected
			break
		}
	}
	return info, nil
}

// CheckUpdate performs a read-only request without depending on the VPN/service.
func CheckUpdate(ctx context.Context, current, platform string) (UpdateInfo, error) {
	client := &http.Client{Timeout: 12 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	return checkUpdate(ctx, client, latestReleaseAPI, current, platform)
}

func checkUpdate(ctx context.Context, client *http.Client, endpoint, current, platform string) (UpdateInfo, error) {
	var empty UpdateInfo
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return empty, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "V6Only/"+current)
	response, err := client.Do(req)
	if err != nil {
		return empty, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return empty, fmt.Errorf("update service returned HTTP %d", response.StatusCode)
	}
	const maxSize = 512 * 1024
	body, err := io.ReadAll(io.LimitReader(response.Body, maxSize+1))
	if err != nil {
		return empty, err
	}
	if len(body) > maxSize {
		return empty, fmt.Errorf("update response too large")
	}
	var release releaseInfo
	if err = json.Unmarshal(body, &release); err != nil {
		return empty, err
	}
	return releaseUpdate(current, platform, release)
}
