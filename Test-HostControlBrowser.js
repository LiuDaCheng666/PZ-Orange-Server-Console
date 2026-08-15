const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright-core');

const webRoot = path.join(__dirname, 'web');
const edgePath = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const requests = { startup: null, autoLogon: 0, restart: null, cancel: null };
let allServersStopped = false;
let restartPending = false;

function sendJson(response, status, body) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(body));
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    let value = '';
    request.setEncoding('utf8');
    request.on('data', chunk => { value += chunk; });
    request.on('end', () => { try { resolve(value ? JSON.parse(value) : {}); } catch (error) { reject(error); } });
    request.on('error', reject);
  });
}

async function handleApi(request, response, url) {
  if (url.pathname === '/api/auth/session') return sendJson(response, 200, { ok: true, authenticated: true, local: true, csrf: 'test', user: { username: 'admin', displayName: '管理员' } });
  if (url.pathname === '/api/status') return sendJson(response, 200, { ok: true, defaultServer: 'production', serverTime: new Date().toISOString(), servers: [{ id: 'production', name: '正式服', kind: 'production', alive: !allServersStopped, status: allServersStopped ? 'stopped' : 'running', writable: true, javaPid: allServersStopped ? null : 816, ports: allServersStopped ? [] : [16261], onlineKnown: true, onlineCount: 0, maxPlayers: 100, canStart: allServersStopped, canStop: !allServersStopped, canRestart: !allServersStopped, jvmMemory: { available: false } }, { id: 'server2', name: '2服', kind: 'production', alive: !allServersStopped, status: allServersStopped ? 'stopped' : 'running', writable: true, javaPid: allServersStopped ? null : 817, ports: allServersStopped ? [] : [17271], onlineKnown: true, onlineCount: 0, maxPlayers: 100, canStart: allServersStopped, canStop: !allServersStopped, canRestart: !allServersStopped, jvmMemory: { available: false } }] });
  if (url.pathname === '/api/system') return sendJson(response, 200, {
    ok: true, sampledAt: new Date().toISOString(),
    host: { cpuName: 'Test CPU', physicalCores: 16, logicalProcessors: 32, cpuPercent: 12.5, memoryTotalBytes: 137438953472, memoryUsedBytes: 68719476736, memoryAvailableBytes: 68719476736, uptimeSeconds: 3600 },
    disks: [{ drive: 'C:', label: 'Windows', totalBytes: 1099511627776, usedBytes: 549755813888, freeBytes: 549755813888 }],
    network: [{ name: 'Ethernet', linkSpeed: '10 Gbps', receiveBytesPerSecond: 1024, sendBytesPerSecond: 2048, bytesPerSecond: 3072 }],
    processes: [
      { kind: 'panel', name: 'Web 控制面板', pid: 100, cpuPercent: 0.5, workingSetBytes: 104857600, peakWorkingSetBytes: 125829120, threadCount: 12, affinity: Array.from({ length: 32 }, (_, index) => index) },
      { kind: 'server', serverId: 'production', name: '正式服', pid: 816, cpuPercent: 18.5, workingSetBytes: 68719476736, peakWorkingSetBytes: 73014444032, threadCount: 128, affinity: Array.from({ length: 16 }, (_, index) => index * 2) },
      { kind: 'server', serverId: 'server2', name: '2服', pid: 817, cpuPercent: 12.5, workingSetBytes: 34359738368, peakWorkingSetBytes: 38654705664, threadCount: 96, affinity: Array.from({ length: 16 }, (_, index) => index * 2 + 1) },
    ],
    logicalProcessors: Array.from({ length: 32 }, (_, index) => ({ index, usagePercent: (index * 13) % 101, userPercent: (index * 11) % 90, privilegedPercent: index % 7 })),
    hostControl: {
      authorized: true,
      startupTask: { installed: true, enabled: true, state: 'Ready', userId: 'WIND25\\Administrator', logonType: 'S4U', lastTaskResult: 0 },
      autoLogon: { enabled: false, userName: '', domainName: '' },
      allServersStopped,
      runningServers: allServersStopped ? [] : [{ id: 'production', name: '正式服', javaPid: 816 }],
      restartPending,
      restartExecuteAt: restartPending ? new Date(Date.now() + 30000).toISOString() : null,
    },
  });
  if (url.pathname === '/api/host/startup-task' && request.method === 'POST') { requests.startup = await readBody(request); return sendJson(response, 200, { ok: true, message: '开机任务已更新。' }); }
  if (url.pathname === '/api/host/autologon/launcher' && request.method === 'GET') { requests.autoLogon += 1; response.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Disposition': 'attachment; filename=Configure-PZPanelAutoLogon.bat' }); return response.end('@echo off\r\n'); }
  if (url.pathname === '/api/host/restart' && request.method === 'POST') { requests.restart = await readBody(request); restartPending = true; return sendJson(response, 202, { ok: true, message: '物理机将在 30 秒后重新启动。' }); }
  if (url.pathname === '/api/host/restart/cancel' && request.method === 'POST') { requests.cancel = await readBody(request); restartPending = false; return sendJson(response, 200, { ok: true, message: '重启已取消。' }); }
  if (url.pathname === '/api/log' || url.pathname === '/api/chat') return sendJson(response, 200, { ok: true, cursor: 0, text: '', messages: [] });
  if (url.pathname === '/api/items/status') return sendJson(response, 200, { ok: true, ready: false, building: false });
  if (url.pathname === '/api/notices/status') return sendJson(response, 200, { ok: true, channel: { usable: false } });
  return sendJson(response, 200, { ok: true });
}

const contentTypes = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8' };
const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, 'http://127.0.0.1');
    if (url.pathname.startsWith('/api/')) return await handleApi(request, response, url);
    const relative = url.pathname === '/' ? 'index.html' : url.pathname.replace(/^\/+/, '');
    const filePath = path.resolve(webRoot, relative);
    if (!filePath.startsWith(path.resolve(webRoot) + path.sep) && filePath !== path.join(path.resolve(webRoot), 'index.html')) { response.writeHead(403); return response.end(); }
    response.writeHead(200, { 'Content-Type': contentTypes[path.extname(filePath)] || 'application/octet-stream' });
    response.end(fs.readFileSync(filePath));
  } catch (error) { response.writeHead(500); response.end(error.stack || error.message); }
});

async function assertLayout(page) {
  return page.evaluate(() => {
    const root = document.documentElement;
    const controls = document.querySelector('.host-control-section').getBoundingClientRect();
    const clipped = [...document.querySelectorAll('.host-control-section button')].filter(button => button.scrollWidth > button.clientWidth + 2).map(button => button.id);
    return { viewport: root.clientWidth, pageWidth: root.scrollWidth, left: controls.left, right: controls.right, clipped };
  });
}

(async () => {
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const port = server.address().port;
  const browser = await chromium.launch({ executablePath: edgePath, headless: true });
  const errors = [];
  try {
    const desktop = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    desktop.on('pageerror', error => errors.push(error.message));
    await desktop.addInitScript(() => { window.confirm = () => true; window.prompt = () => '重启物理机'; });
    await desktop.goto(`http://127.0.0.1:${port}/?view=system&server=production`, { waitUntil: 'domcontentloaded' });
    await desktop.waitForSelector('#authScreen', { state: 'hidden' });
    await desktop.waitForFunction(() => document.querySelector('#hostStartupDetail').textContent.includes('登录前启动'));
    await desktop.waitForFunction(() => document.querySelectorAll('.cpu-core-tile').length === 32 && document.querySelectorAll('.cpu-core-tile.allowed').length === 16);
    if (!(await desktop.locator('#cpuCoreScope').textContent()).includes('PID 816')) throw new Error('Selected server CPU affinity scope is missing.');
    const coreLabels = await desktop.evaluate(() => [0, 1].map(index => document.querySelector(`[data-core-index="${index}"] .cpu-core-servers`).textContent));
    if (!coreLabels[0].includes('正式服') || coreLabels[0].includes('2服') || !coreLabels[1].includes('2服') || coreLabels[1].includes('正式服')) throw new Error(`Server-to-core labels are incorrect: ${JSON.stringify(coreLabels)}`);
    if (await desktop.locator('#cpuServerLegend .cpu-server-key').count() !== 2) throw new Error('Running server CPU legend is incomplete.');
    if (!await desktop.locator('#restartPhysicalHost').isDisabled()) throw new Error('Restart must be disabled while a game server is running.');
    await desktop.click('#toggleHostStartup');
    await desktop.waitForFunction(() => document.querySelector('#toast').textContent.includes('开机任务'));
    if (!requests.startup || requests.startup.confirm !== 'CHANGE_HOST_STARTUP') throw new Error('Startup task confirmation was not sent.');
    const [download] = await Promise.all([desktop.waitForEvent('download'), desktop.click('#openHostAutoLogon')]);
    if (download.suggestedFilename() !== 'Configure-PZPanelAutoLogon.bat') throw new Error('Unexpected Autologon launcher filename.');
    if (requests.autoLogon !== 1) throw new Error('Local Autologon tool request was not sent.');
    allServersStopped = true;
    await desktop.evaluate(() => pollSystem());
    await desktop.waitForFunction(() => !document.querySelector('#restartPhysicalHost').disabled);
    await desktop.click('#restartPhysicalHost');
    await desktop.waitForFunction(() => !document.querySelector('#cancelHostRestart').hidden);
    if (!requests.restart || requests.restart.confirm !== 'RESTART_PHYSICAL_HOST') throw new Error('Typed host restart confirmation was not sent.');
    await desktop.click('#cancelHostRestart');
    await desktop.waitForFunction(() => document.querySelector('#cancelHostRestart').hidden);
    if (!requests.cancel || requests.cancel.confirm !== 'CANCEL_HOST_RESTART') throw new Error('Host restart cancellation was not sent.');
    const desktopLayout = await assertLayout(desktop);
    await desktop.screenshot({ path: path.join(__dirname, 'pz-panel-host-control-desktop.png'), fullPage: true });

    const mobile = await browser.newPage({ viewport: { width: 390, height: 844 } });
    mobile.on('pageerror', error => errors.push(error.message));
    await mobile.goto(`http://127.0.0.1:${port}/?view=system&server=production`, { waitUntil: 'domcontentloaded' });
    await mobile.waitForSelector('#authScreen', { state: 'hidden' });
    await mobile.waitForFunction(() => document.querySelector('#hostStartupDetail').textContent.includes('登录前启动'));
    const mobileLayout = await assertLayout(mobile);
    await mobile.screenshot({ path: path.join(__dirname, 'pz-panel-host-control-mobile.png'), fullPage: true });

    if (desktopLayout.pageWidth > desktopLayout.viewport + 1 || mobileLayout.pageWidth > mobileLayout.viewport + 1 || desktopLayout.clipped.length || mobileLayout.clipped.length || errors.length) {
      throw new Error(JSON.stringify({ desktopLayout, mobileLayout, errors }));
    }
    console.log(JSON.stringify({ ok: true, desktopLayout, mobileLayout, requests }, null, 2));
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error.stack || error.message); process.exitCode = 1; });
