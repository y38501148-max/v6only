const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

async function desktop({installed = false, enabled = false, installError, flows = []} = {}) {
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
        return {installed, enabled};
      }
      if (!installed) throw Error('Service unavailable');
      if (args.action === 'enable') enabled = true;
      if (args.action === 'disable') enabled = false;
      if (args.action === 'status') return {installed, enabled, health: {}, flows};
      return {};
    }}}},
    setInterval() {},
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../ui/app.js'), 'utf8'), context);
  for (let i = 0; i < 10 && vm.runInContext('polling', context); i++) await new Promise(setImmediate);
  calls.length = 0;
  return {element, calls, click: () => element('control').onclick()};
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
