// Release checks do not depend on service installation or hold network controls.
(() => {
  const byId = id => document.getElementById(id), invoke = window.__TAURI__?.core.invoke;
  const interval = 6 * 60 * 60 * 1000;
  const read = key => { try { return localStorage.getItem(`update-${key}`) || ''; } catch (_) { return ''; } };
  const save = (key, value) => { try { localStorage.setItem(`update-${key}`, String(value)); } catch (_) {} };
  let pending = false, nextCheck = 0, available = null;
  const status = byId('update-status'), button = byId('check-update'), banner = byId('update-banner');
  async function check(manual = false) {
    if (!invoke || pending || (!manual && (document.hidden || Date.now() < nextCheck))) return;
    pending = true; button.disabled = true;
    if (manual) status.textContent = '正在检查更新…';
    try {
      const result = await invoke('check_update');
      nextCheck = Date.now() + interval;
      available = result.available ? result : null;
      if (manual) save('dismissed', '');
      banner.hidden = !available || read('dismissed') === result.latest_version;
      if (available) {
        byId('update-title').textContent = `发现新版本 ${result.latest_version}`;
        byId('update-detail').textContent = `当前版本 ${result.current_version}`;
        status.textContent = `可更新至 ${result.latest_version}`;
      } else if (result.release_url) {
        status.textContent = '新版暂未提供当前设备安装包';
      } else {
        status.textContent = result.latest_version ? '已是当前设备可用的最新版本' : '暂无可用更新';
      }
    } catch (_) {
      nextCheck = Date.now() + 15 * 60 * 1000;
      if (manual) status.textContent = '检查失败，请稍后重试';
    } finally { pending = false; button.disabled = false; }
  }
  async function open(key) {
    if (!available) return;
    try { await invoke('open_update', {url: available[key]}); }
    catch (_) { status.textContent = '无法打开更新链接，请稍后重试'; }
  }
  button.onclick = () => check(true);
  byId('download-update').onclick = () => open('download_url');
  byId('release-notes').onclick = () => open('release_url');
  byId('dismiss-update').onclick = () => { save('dismissed', available?.latest_version || ''); banner.hidden = true; };
  document.addEventListener('visibilitychange', () => { if (!document.hidden) check(); });
  window.addEventListener('focus', () => check());
  setInterval(() => check(), 60 * 1000);
  check();
})();
