const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

async function desktop({installed = false, enabled = false, installError, flows = [], statusError = null, busyFailures = 0, version = '2.1.11'} = {}) {
  const elements = new Map(), calls = [];
  function element(id) {
    if (!elements.has(id)) elements.set(id, {
      value: 'all', textContent: '', hidden: false, disabled: false, style: {},
      children: [], classList: {toggle() {}}, append(...nodes) { this.children.push(...nodes); }, replaceChildren(...nodes) { this.children = nodes; }, setAttribute() {}, addEventListener() {},
    });
    return elements.get(id);
  }
  const context = vm.createContext({
    document: {getElementById: element, querySelector: element, querySelectorAll: () => [], createElement: () => element(Symbol()), hidden: false},
    window: {__TAURI__: {core: {invoke: async (command, args) => {
      calls.push([command, args?.action]);
      if (command === 'install_service') {
        assert.equal(element('control').disabled, true, 'disable button during installation');
        if (installError) throw Error(installError);
        installed = true;
        version = '2.1.11';
        return {installed, enabled};
      }
      if (!installed) throw Error('SERVICE_MISSING: Service not installed');
      if (args.action === 'status' && statusError) throw Error(statusError);
      if (args.action === 'enable' && busyFailures-- > 0) throw Error('SERVICE_BUSY: watcher running');
      if (args.action === 'enable') enabled = true;
      if (args.action === 'disable') enabled = false;
      if (args.action === 'status') return {installed, enabled, health: {}, flows,version};
      return {};
    }}}},
    setInterval() {}, setTimeout: callback => setImmediate(callback),
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../ui/app.js'), 'utf8'), context);
  for (let i = 0; i < 10 && vm.runInContext('polling', context); i++) await new Promise(setImmediate);
  calls.length = 0;
  return {element, calls, click: () => element('control').onclick(), refresh: () => vm.runInContext('refresh()', context), setStatusError: e => {statusError=e}, fallback: () => element('allow-fallback').onchange()};
}

test('Install and enable completes both operations in one click', async () => {
  const app = await desktop();
  await app.click();
  assert.deepEqual(app.calls.slice(0, 2), [['install_service', undefined], ['service', 'enable']]);
  assert.equal(app.element('control').textContent, '关闭转发');
  assert.equal(app.element('control').disabled, false);
});

test('Cancelled/failed authorization shows an error and does not enable', async () => {
  const app = await desktop({installError: 'Authorization cancelled'});
  await app.click();
  assert.ok(!app.calls.some(([, action]) => action === 'enable'));
  assert.match(app.element('notice').textContent, /Authorization cancelled/);
  assert.equal(app.element('control').disabled, false);
  assert.equal(app.element('control').textContent, '安装并启用');
});

test('An installed service enables and disables without reinstalling', async () => {
  const app = await desktop({installed: true});
  await app.click();
  assert.deepEqual(app.calls[0], ['service', 'enable']);
  app.calls.length = 0;
  await app.click();
  assert.deepEqual(app.calls[0], ['service', 'disable']);
  assert.equal(app.element('control').textContent, '启用转发');
});

// Windows PowerShell 5.1 attaches extended properties to Invoke-RestMethod
// arrays. A rendering error used to reset installed=false in refresh().
test('Windows PowerShell wrapped flow arrays do not masquerade as missing service', async () => {
  for (const flows of [{value: [], Count: 0}, {value: [{host: 'v4.example', remote: '127.0.0.1:80', network: 'tcp4'}], Count: 1}]) {
    const app = await desktop({installed: true, enabled: true, flows});
    assert.equal(app.element('control').textContent, '关闭转发');
    await app.click();
    assert.deepEqual(app.calls[0], ['service', 'disable']);
    assert.ok(!app.calls.some(([command]) => command === 'install_service'));
  }
});


test('Actual PowerShell nested wrappers render domain, address, protocol and traffic', async () => {
  const flow = {host: 'video.bilivideo.com', remote: '[2001:db8::80]:443', network: 'tcp6', upload_bytes: 2048, download_bytes: 3145728};
  for (const flows of [[flow], {value:[flow],Count:1}, [{value:[flow],Count:1}]]) {
    const app = await desktop({installed:true, enabled:true, flows});
    const rows = app.element('flows-body').children;
    assert.equal(rows.length, 1);
    assert.equal(rows[0].children[0].textContent, flow.host);
    assert.equal(rows[0].children[1].textContent, flow.remote);
    assert.equal(rows[0].children[2].children[0].textContent, 'IPv6');
    assert.equal(rows[0].children[3].textContent, '↑ 2.00 KiB / ↓ 3.00 MiB');
  }
});

test('Empty nested wrapper renders empty state, never a blank IPv4 connection', async () => {
  const app = await desktop({installed:true, enabled:true, flows:[{value:[],Count:0}]});
  const rows = app.element('flows-body').children;
  assert.equal(rows.length, 1);
  assert.equal(rows[0].children[0].textContent, '暂无符合条件的连接');
});


test('Temporary status errors preserve an installed service and the stop action', async () => {
  const app = await desktop({installed:true, enabled:true});
  app.setStatusError('controller timeout');
  await app.refresh();
  assert.equal(app.element('control').textContent, '关闭转发');
  assert.equal(app.element('header-state').textContent, '状态暂时不可用');
  await app.click();
  assert.deepEqual(app.calls[app.calls.findIndex(([,a]) => a === 'disable')], ['service','disable']);
  assert.ok(!app.calls.some(([command]) => command === 'install_service'));
});

test('An unknown unavailable service offers retry without installation', async () => {
  const app = await desktop({installed:true, statusError:'SERVICE_UNAVAILABLE: starting'});
  assert.equal(app.element('control').textContent, '重试连接');
  await app.click();
  assert.ok(!app.calls.some(([command]) => command === 'install_service'));
  app.setStatusError(null);
  await app.refresh();
  assert.equal(app.element('control').textContent, '启用转发');
});

test('IPv4 fallback is an explicit service action and off by default', async () => {
  const app = await desktop({installed:true});
  assert.equal(app.element('allow-fallback').checked, false);
  app.element('allow-fallback').checked = true;
  await app.fallback();
  assert.deepEqual(app.calls[0], ['service','set_fallback']);
});


test('One click waits for a busy watcher and enables without a second click', async () => {
  const app=await desktop({installed:true,busyFailures:1});
  await app.click();
  assert.equal(app.calls.filter(([,a])=>a==='enable').length,2);
  assert.equal(app.element('control').textContent,'关闭转发');
  assert.equal(app.element('notice').textContent,'');
});

test('Proxy labels distinguish IPv6 and IPv4 loopback without claiming public egress', async () => {
  for (const [network,label] of [['tcp6_proxy','IPv6 本机代理'],['tcp4_proxy','IPv4 本机代理']]) {
    const app = await desktop({installed:true, enabled:true, flows:[{host:'chatgpt.com',remote:network==='tcp6_proxy'?'[::1]:7890':'127.0.0.1:7890',network,reason:'chatgpt_proxy'}]});
    assert.equal(app.element('flows-body').children[0].children[2].children[0].textContent,label);
  }
});


test('An outdated service is upgraded without toggling forwarding off', async () => {
 const app = await desktop({installed:true, enabled:true, version:'2.1.6'});
 assert.equal(app.element('control').textContent,'更新后台服务');
 await app.click();
 assert.deepEqual(app.calls[0],['install_service',undefined]);
 assert.ok(!app.calls.some(([,action])=>action==='disable'));
 assert.equal(app.element('control').textContent,'关闭转发');
});


test('A newer service is not downgraded by this desktop', async () => {
 const app=await desktop({installed:true,enabled:true,version:'2.2.0'});
 assert.equal(app.element('control').textContent,'关闭转发');
});

test('Recent connections are sorted by time instead of old cumulative traffic', async () => {
 const app=await desktop({installed:true,enabled:true,flows:[{host:'old.example',remote:'127.0.0.1:7890',network:'tcp4_proxy',time:'2026-10-10T10:00:00Z',download_bytes:999999},{host:'chatgpt.com',remote:'[::1]:7890',network:'tcp6_proxy',time:'2026-10-10T11:00:00Z',download_bytes:1}]});
 assert.equal(app.element('flows-body').children[0].children[0].textContent,'chatgpt.com');
});
