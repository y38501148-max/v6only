use serde_json::Value;
use std::process::Command;
use tauri::Manager;

const RELEASE_BASE: &str = "https://github.com/y38501148-max/v6only/releases/";

fn platform() -> Result<&'static str, String> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("windows", "x86_64") => Ok("windows-x64"),
        ("macos", "aarch64") => Ok("macos-arm64"),
        _ => Err("当前设备暂无桌面安装包。".into()),
    }
}

#[tauri::command]
pub async fn check_update(app: tauri::AppHandle) -> Result<Value, String> {
    let target = platform()?;
    let resource = app.path().resource_dir().map_err(|e| e.to_string())?;
    let core = if cfg!(windows) { resource.join("windows/v6core.exe") } else { resource.join("macos/v6core") };
    tauri::async_runtime::spawn_blocking(move || {
        let mut command = Command::new(core);
        #[cfg(windows)] {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000);
        }
        let output = command.args(["--check-update", target, "--current-version", env!("CARGO_PKG_VERSION")])
            .output().map_err(|e| e.to_string())?;
        if !output.status.success() { return Err("检查更新失败，请稍后重试。".into()); }
        serde_json::from_slice(&output.stdout).map_err(|e| e.to_string())
    }).await.map_err(|e| e.to_string())?
}

fn trusted_url(url: &str) -> bool {
    let Some(path) = url.strip_prefix(RELEASE_BASE) else { return false; };
    let parts: Vec<&str> = path.split('/').collect();
    if parts.len() < 2 { return false; }
    let version = parts[1].strip_prefix('v').unwrap_or(parts[1]);
    let numbers: Vec<&str> = version.split('.').collect();
    if numbers.len() != 3 || numbers.iter().any(|n| n.is_empty() || !n.bytes().all(|c| c.is_ascii_digit()) || n.parse::<u64>().is_err() || (n.len() > 1 && n.starts_with('0'))) { return false; }
    match parts.as_slice() {
        ["tag", _] => true,
        ["download", _, asset] => ["Windows-x64.msi", "macOS-arm64.dmg"].iter().any(|suffix| *asset == format!("V6Only-{version}-{suffix}")),
        _ => false,
    }
}

#[tauri::command]
pub async fn open_update(url: String) -> Result<(), String> {
    if !trusted_url(&url) { return Err("更新链接无效。".into()); }
    tauri::async_runtime::spawn_blocking(move || {
        #[cfg(windows)]
        let mut command = {
            use std::os::windows::process::CommandExt;
            let mut c = Command::new("rundll32.exe");
            c.creation_flags(0x08000000).arg("url.dll,FileProtocolHandler"); c
        };
        #[cfg(not(windows))]
        let mut command = Command::new("/usr/bin/open");
        let status = command.arg(url).status().map_err(|e| e.to_string())?;
        if status.success() { Ok(()) } else { Err("无法打开浏览器，请稍后重试。".into()) }
    }).await.map_err(|e| e.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn update_links_are_confined_to_our_release_installers() {
        for path in ["tag/v2.1.12", "download/v2.1.12/V6Only-2.1.12-Windows-x64.msi", "download/v2.1.12/V6Only-2.1.12-macOS-arm64.dmg"] { assert!(trusted_url(&format!("{RELEASE_BASE}{path}"))); }
        for url in ["file:///tmp/app", "https://github.com.evil.test/y38501148-max/v6only/releases/tag/v2.1.12", "https://github.com/other/repo/releases/tag/v2.1.12"] { assert!(!trusted_url(url)); }
        for path in ["tag/v2.1.12?x=1", "tag/../../settings", "tag/v2.1.12/extra", "download/v2.1.12/evil.exe", "download/v2.1.12/V6Only-9.0.0-Windows-x64.msi", "tag/v02.1.12"] { assert!(!trusted_url(&format!("{RELEASE_BASE}{path}"))); }
    }
}
