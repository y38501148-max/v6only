#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod app_update;
use std::io::{BufRead,BufReader,Write};
#[cfg(unix)] use std::{os::unix::net::UnixStream,time::Duration,process::Command};
use serde_json::{Value,json};
use tauri::Manager;
#[cfg(unix)]
fn shell_quote(s:&str)->String {format!("'{}'",s.replace('\'',"'\\''"))}
fn rpc(q:Value)->Result<Value,String>{
 #[cfg(unix)]
 let mut stream=UnixStream::connect("/var/run/v6only-desktop.sock").map_err(|e| if !std::path::Path::new("/usr/local/lib/v6only/v6service").exists() {
  "SERVICE_MISSING: 后台服务尚未安装，点击「安装并启用」完成配置。".to_string()
 } else {format!("SERVICE_UNAVAILABLE: 后台服务暂时无法连接，请稍后重试。{}",e)})?;
 #[cfg(windows)]
 let mut stream={
  use std::os::windows::process::CommandExt;
  let mut attempts=0;
  loop {match std::fs::OpenOptions::new().read(true).write(true).open(r"\\.\pipe\v6only-desktop") {
   Ok(stream)=>break stream,
   Err(error) if error.raw_os_error()==Some(231) && attempts<30=>{attempts+=1;std::thread::sleep(std::time::Duration::from_millis(100));},
   Err(error)=>{
    let missing=std::process::Command::new("sc.exe").args(["query","V6Only"]).creation_flags(0x08000000).output().map(|o|o.status.code()==Some(1060)).unwrap_or(false);
    return Err(if missing {"SERVICE_MISSING: 后台服务尚未安装，请点击「安装并启用」。".into()} else {format!("SERVICE_UNAVAILABLE: 后台服务暂时无法连接，请稍后重试。{}",error)})
   }
  }}
 };
 #[cfg(unix)]
 stream.set_read_timeout(Some(Duration::from_secs(90))).map_err(|e|e.to_string())?;
 #[cfg(unix)]
 stream.set_write_timeout(Some(Duration::from_secs(5))).map_err(|e|e.to_string())?;
 writeln!(stream,"{}",q).map_err(|e|e.to_string())?;let mut buf=String::new();BufReader::new(stream).read_line(&mut buf).map_err(|e|e.to_string())?;
 let r:Value=serde_json::from_str(&buf).map_err(|e|e.to_string())?;
 if r["ok"]==true {Ok(r["data"].clone())}else{Err(r["error"].as_str().unwrap_or("操作失败").to_string())}
}
#[tauri::command]
async fn service(action:String,from:Option<i64>,to:Option<i64>,url:Option<String>,allow_fallback:Option<bool>)->Result<Value,String>{
 if !["status","enable","disable","stats","diagnose","set_fallback"].contains(&action.as_str()){return Err("无效操作".into())}
 tauri::async_runtime::spawn_blocking(move||rpc(json!({"action":action,"from":from.unwrap_or(0),"to":to.unwrap_or(0),"url":url.unwrap_or_default(),"allow_fallback":allow_fallback.unwrap_or(false)}))).await.map_err(|e|e.to_string())?
}
#[tauri::command]
async fn install_service(app:tauri::AppHandle)->Result<Value,String>{
 #[cfg(windows)]
 {
  use std::os::windows::process::CommandExt;
  let installer=app.path().resource_dir().map_err(|e|e.to_string())?.join("windows/desktop-install.ps1");
  tauri::async_runtime::spawn_blocking(move||{
   if !installer.is_file(){return Err("后台服务安装脚本缺失，请重新安装完整 MSI。".to_string())}
   let output=std::process::Command::new("powershell.exe")
    .args(["-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File"])
    .arg(installer).creation_flags(0x08000000).output().map_err(|e|e.to_string())?;
   if !output.status.success(){return Err(format!("后台服务配置未完成：{}",String::from_utf8_lossy(&output.stderr).trim()))}
   rpc(json!({"action":"status"}))
  }).await.map_err(|e|e.to_string())?
 }
 #[cfg(unix)]
 {
 let resource=app.path().resource_dir().map_err(|e|e.to_string())?.join("macos/desktop-install.sh");
 let uid=Command::new("/usr/bin/id").arg("-u").output().map_err(|e|e.to_string())?;
 let uid=String::from_utf8_lossy(&uid.stdout).trim().to_string();if uid.parse::<u32>().is_err(){return Err("无法确定用户".into())};
 tauri::async_runtime::spawn_blocking(move||{
 let mode=match rpc(json!({"action":"status"})) { Ok(status) if status["suspended"]==true || status["enabled"]==false => "pause", _ => "enable" };
 let cmd=format!("/bin/bash {} {} {}",shell_quote(&resource.to_string_lossy()),uid,mode);
 let script=format!("do shell script {} with administrator privileges",serde_json::to_string(&cmd).unwrap());
 let output=Command::new("/usr/bin/osascript").args(["-e",&script]).output().map_err(|e|e.to_string())?;
 if !output.status.success(){return Err(String::from_utf8_lossy(&output.stderr).to_string())};
 rpc(json!({"action":"status"}))
 }).await.map_err(|e|e.to_string())?
 }
}
#[tauri::command]
async fn save_export(app:tauri::AppHandle,from:i64,to:i64)->Result<String,String>{
 let dir=app.path().download_dir().map_err(|e|e.to_string())?;
 tauri::async_runtime::spawn_blocking(move||{
 let r=rpc(json!({"action":"stats","from":from,"to":to}))?;let filename=format!("V6Only-{}-{}.csv",from,to);let path=dir.join(filename);
 let mut csv=String::from("unix_time,ipv4_upload_bytes,ipv4_download_bytes,ipv6_upload_bytes,ipv6_download_bytes\n");
 if let Some(points)=r["points"].as_array(){for p in points{csv.push_str(&format!("{},{},{},{},{}\n",p["at"],p["v4_up"],p["v4_down"],p["v6_up"],p["v6_down"]))}}
 std::fs::write(&path,csv).map_err(|e|e.to_string())?;Ok(path.to_string_lossy().into_owned())
 }).await.map_err(|e|e.to_string())?
}
fn main(){tauri::Builder::default().invoke_handler(tauri::generate_handler![service,install_service,save_export,app_update::check_update,app_update::open_update]).run(tauri::generate_context!()).expect("V6Only failed to run");}
