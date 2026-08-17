const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright-core');

const webRoot = path.join(__dirname, 'web');
const edgePath = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const requests = { saveBackup: null, schedule: null, restart: null, checkNow: null };

const serverProfile = {
  id: 'mock', name: '测试服务器', kind: 'test', alive: true, status: 'running', writable: true,
  commandChannel: 'queue', note: '', lanAddress: '127.0.0.1:16261', onlineCount: 2,
  onlineKnown: true, maxPlayers: 32, memoryMB: 8192, memoryPeakMB: 10240,
  startedAt: new Date(Date.now() - 3600000).toISOString(), javaPid: 1234, ports: [16261],
  canStart: false, canStop: true, canRestart: true, jvmMemory: { available: false },
};

let schedule = {
  ok: true, serverId: 'mock', enabled: false, intervalHours: 3, nextRunAt: null,
  running: false, lastRunAt: null, lastStatus: 'never', lastResultCode: null,
  lastMessage: '尚未执行自动 Mod 更新检查。', lastRequestId: null,
  updateNotificationPending: false, lastNotificationAt: null,
  autoRestartOnUpdate: false, autoRestartWarningSeconds: 60,
  restartStabilizationSeconds: 60,
  lastAutoRestartAt: null, lastAutoRestartOperationId: null,
};

let saveBackup = {
  ok: true, serverId: 'mock', autoSaveEnabled: false, saveIntervalMinutes: 10,
  autoBackupEnabled: true, backupIntervalMinutes: 60, backupCount: 3,
  backupDirectory: 'D:\\MockData\\backups\\period', backupDirectoryExists: true,
  backupFileCount: 3, backupTotalBytes: 12884901888, latestBackupAt: new Date().toISOString(),
  latestBackupBytes: 4294967296, latestBackupName: 'backup_1.zip', nextBackupAt: new Date(Date.now() + 3600000).toISOString(),
};

function sendJson(response, status, body) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(body));
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    let value = '';
    request.setEncoding('utf8');
    request.on('data', chunk => { value += chunk; });
    request.on('end', () => {
      try { resolve(value ? JSON.parse(value) : {}); } catch (error) { reject(error); }
    });
    request.on('error', reject);
  });
}

async function handleApi(request, response, url) {
  if (url.pathname === '/api/auth/session') return sendJson(response, 200, { ok: true, authenticated: true, local: true, csrf: 'test', user: { username: 'admin', displayName: '管理员' } });
  if (url.pathname === '/api/status') return sendJson(response, 200, { ok: true, defaultServer: 'mock', serverTime: new Date().toISOString(), servers: [serverProfile] });
  if (url.pathname === '/api/maintenance/save-backup' && request.method === 'GET') return sendJson(response, 200, saveBackup);
  if (url.pathname === '/api/maintenance/save-backup' && request.method === 'PUT') {
    requests.saveBackup = await readBody(request);
    saveBackup = { ...saveBackup, ...requests.saveBackup, message: 'Save and backup settings saved.' };
    return sendJson(response, 200, saveBackup);
  }
  if (url.pathname === '/api/maintenance/schedule' && request.method === 'GET') return sendJson(response, 200, schedule);
  if (url.pathname === '/api/maintenance/schedule' && request.method === 'PUT') {
    requests.schedule = await readBody(request);
    schedule = { ...schedule, ...requests.schedule, nextRunAt: new Date(Date.now() + requests.schedule.intervalHours * 3600000).toISOString() };
    return sendJson(response, 200, { ...schedule, message: '自动 Mod 检查计划已保存。' });
  }
  if (url.pathname === '/api/maintenance/check-now' && request.method === 'POST') {
    requests.checkNow = await readBody(request);
    schedule = { ...schedule, running: true, lastStatus: 'checking', lastRunAt: new Date().toISOString(), lastMessage: '正在等待服务器返回检查结果。' };
    return sendJson(response, 200, { ...schedule, message: 'Mod 更新检查已提交。' });
  }
  if (url.pathname === '/api/server/restart' && request.method === 'POST') {
    requests.restart = await readBody(request);
    return sendJson(response, 202, { ok: true, message: '安全重启已提交。', operationId: '0123456789abcdef0123456789abcdef' });
  }
  if (url.pathname === '/api/server/operation') return sendJson(response, 200, { ok: true, available: true, operation: { id: '0123456789abcdef0123456789abcdef', action: 'restart', status: 'completed', stage: 'completed', message: '安全重启测试已完成。', startedAt: new Date().toISOString(), oldJavaPid: 1234, newJavaPid: 1235, warnings: [] } });
  if (url.pathname === '/api/audit') return sendJson(response, 200, { ok: true, lines: [] });
  if (url.pathname === '/api/log') return sendJson(response, 200, { ok: true, serverId: 'mock', cursor: 0, reset: false, text: '' });
  if (url.pathname === '/api/players') return sendJson(response, 200, { ok: true, serverId: 'mock', onlineKnown: true, online: [], players: [] });
  if (url.pathname === '/api/items/status') return sendJson(response, 200, { ok: true, serverId: 'mock', ready: false, cacheAvailable: false, building: false });
  return sendJson(response, 200, { ok: true, serverId: 'mock' });
}

const contentTypes = { '.html': 'text/html; charset=utf-8', '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8' };
const testServer = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, 'http://127.0.0.1');
    if (url.pathname.startsWith('/api/')) return await handleApi(request, response, url);
    const relative = url.pathname === '/' ? 'index.html' : url.pathname.replace(/^\/+/, '');
    const filePath = path.resolve(webRoot, relative);
    if (!filePath.startsWith(path.resolve(webRoot) + path.sep) && filePath !== path.join(path.resolve(webRoot), 'index.html')) {
      response.writeHead(403); return response.end();
    }
    const data = fs.readFileSync(filePath);
    response.writeHead(200, { 'Content-Type': contentTypes[path.extname(filePath)] || 'application/octet-stream' });
    response.end(data);
  } catch (error) {
    response.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
    response.end(error.stack || error.message);
  }
});

function collectErrors(page, label, errors) {
  page.on('pageerror', error => errors.push(`${label} pageerror: ${error.message}`));
  page.on('console', message => { if (message.type() === 'error') errors.push(`${label} console: ${message.text()}`); });
}

async function inspectLayout(page) {
  return page.evaluate(() => {
    const saveBackupPanel = document.querySelector('.save-backup-plan').getBoundingClientRect();
    const schedulePanel = document.querySelector('.maintenance-schedule').getBoundingClientRect();
    const restartRow = document.querySelector('.restart-row').getBoundingClientRect();
    const restartButton = document.querySelector('#restartServer').getBoundingClientRect();
    return {
      clientWidth: document.documentElement.clientWidth,
      scrollWidth: document.documentElement.scrollWidth,
      saveBackupRight: saveBackupPanel.right,
      scheduleRight: schedulePanel.right,
      restartRight: restartRow.right,
      restartButtonRight: restartButton.right,
      restartButtonWidth: restartButton.width,
    };
  });
}

(async () => {
  await new Promise((resolve, reject) => {
    testServer.once('error', reject);
    testServer.listen(0, '127.0.0.1', resolve);
  });
  const port = testServer.address().port;
  const browser = await chromium.launch({ executablePath: edgePath, headless: true });
  const errors = [];
  try {
    const desktop = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    collectErrors(desktop, 'desktop', errors);
    await desktop.addInitScript(() => { window.confirm = () => true; });
    await desktop.goto(`http://127.0.0.1:${port}/?view=maintenance&server=mock`, { waitUntil: 'domcontentloaded' });
    await desktop.waitForSelector('#authScreen', { state: 'hidden' });
    await desktop.waitForFunction(() => document.querySelector('#maintenanceLastResult').textContent.includes('尚未执行'));

    await desktop.check('#saveBackupPlanForm input[name="autoSaveEnabled"]');
    await desktop.fill('#saveBackupPlanForm input[name="saveIntervalMinutes"]', '10');
    await desktop.fill('#saveBackupPlanForm input[name="backupIntervalMinutes"]', '120');
    await desktop.fill('#saveBackupPlanForm input[name="backupCount"]', '5');
    await desktop.click('#saveBackupPlanForm button[type="submit"]');
    await desktop.waitForFunction(() => document.querySelector('#saveBackupPlanBadge').textContent.includes('全部启用'));

    await desktop.check('#maintenanceScheduleForm input[name="enabled"]');
    await desktop.fill('#maintenanceScheduleForm input[name="intervalHours"]', '6');
    await desktop.fill('#maintenanceScheduleForm input[name="restartStabilizationSeconds"]', '90');
    await desktop.check('#maintenanceScheduleForm input[name="autoRestartOnUpdate"]');
    await desktop.click('#maintenanceScheduleForm button[type="submit"]');
    await desktop.waitForFunction(() => document.querySelector('#maintenanceScheduleBadge').textContent.includes('已启用'));
    await desktop.click('#maintenanceCheckNow');
    await desktop.waitForFunction(() => document.querySelector('#maintenanceLastResult').textContent.includes('检查中'));
    await desktop.fill('#restartWarningSeconds', '90');
    await desktop.click('#restartServer');
    await desktop.waitForFunction(() => document.querySelector('#lifecycleBadge').textContent.includes('成功'));
    const desktopLayout = await inspectLayout(desktop);

    const mobile = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true });
    collectErrors(mobile, 'mobile', errors);
    await mobile.goto(`http://127.0.0.1:${port}/?view=maintenance&server=mock`, { waitUntil: 'domcontentloaded' });
    await mobile.waitForSelector('#authScreen', { state: 'hidden' });
    await mobile.waitForFunction(() => document.querySelector('#saveBackupPlanForm input[name="backupIntervalMinutes"]').value === '120' && document.querySelector('#maintenanceScheduleForm input[name="intervalHours"]').value === '6' && document.querySelector('#maintenanceLastResult').textContent.includes('检查中'));
    const mobileLayout = await inspectLayout(mobile);

    const result = { requests, desktop: desktopLayout, mobile: mobileLayout, browserErrors: errors };
    console.log(JSON.stringify(result, null, 2));
    if (errors.length) process.exitCode = 2;
    if (!requests.saveBackup || requests.saveBackup.serverId !== 'mock' || requests.saveBackup.autoSaveEnabled !== true || requests.saveBackup.saveIntervalMinutes !== 10 || requests.saveBackup.autoBackupEnabled !== true || requests.saveBackup.backupIntervalMinutes !== 120 || requests.saveBackup.backupCount !== 5) process.exitCode = 7;
    if (!requests.schedule || requests.schedule.serverId !== 'mock' || requests.schedule.enabled !== true || requests.schedule.intervalHours !== 6 || requests.schedule.restartStabilizationSeconds !== 90 || requests.schedule.autoRestartOnUpdate !== true) process.exitCode = 3;
    if (!requests.checkNow || requests.checkNow.serverId !== 'mock') process.exitCode = 4;
    if (!requests.restart || requests.restart.serverId !== 'mock' || requests.restart.confirm !== 'SAVE_QUIT_RESTART' || requests.restart.warningSeconds !== 90 || requests.restart.restartStabilizationSeconds !== 90) process.exitCode = 5;
    for (const layout of [desktopLayout, mobileLayout]) {
      if (layout.scrollWidth > layout.clientWidth || layout.saveBackupRight > layout.clientWidth || layout.scheduleRight > layout.clientWidth || layout.restartRight > layout.clientWidth || layout.restartButtonRight > layout.clientWidth || layout.restartButtonWidth < 80) process.exitCode = 6;
    }
  } finally {
    await browser.close();
    await new Promise(resolve => testServer.close(resolve));
  }
})().catch(error => {
  console.error(error.stack || error.message);
  testServer.close();
  process.exit(1);
});
