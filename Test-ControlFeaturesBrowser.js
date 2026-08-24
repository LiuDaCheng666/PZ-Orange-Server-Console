const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright-core');

const webRoot = path.join(__dirname, 'web');
const edgePath = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const requests = { policy: null, schedule: null, runNow: null, itemGrant: null, access: null, playerPassword: null, playerAudit: null, banSync: null, itemResultQueries: 0, itemSubmissionQueries: 0, aiRuntime: null };

const profile = {
  id: 'mock', name: '测试服务器', kind: 'test', alive: true, status: 'running', writable: true,
  commandChannel: 'queue', lanAddress: '127.0.0.1:16261', onlineCount: 2, onlineKnown: true,
  maxPlayers: 32, memoryMB: 8192, memoryPeakMB: 10240, javaPid: 1234, ports: [16261],
  canStart: false, canStop: true, canRestart: true, jvmMemory: { available: false },
};
const players = [
  { username: 'Alice', steamId: '76561198000000001', online: true },
  { username: '玩家乙', steamId: '76561198000000002', online: true },
];
const operations = [
  { id: 'query_status', label: '查询服务器状态', risk: 'low' },
  { id: 'give_self_item', label: '给自己发放物品', risk: 'high' },
  { id: 'kick_player', label: '踢出其他玩家', risk: 'critical' },
];
let policies = [];
let schedules = [];
let history = [{
  id: 'history-initial', serverId: 'mock', category: 'update', action: 'check-mod-updates',
  source: 'scheduled', summary: '自动检查 Mod 更新', status: 'success', resultCode: 'mods-current',
  message: '检查完成：Mods updated，当前没有需要下载的 Mod 更新。', detail: 'CheckModsNeedUpdate: Mods updated',
  createdAt: new Date(Date.now() - 60000).toISOString(), updatedAt: new Date(Date.now() - 59000).toISOString(),
}];

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

const policyPayload = message => ({ ok: true, message: message || '执行器尚未接入。', operations, policies });
const schedulePayload = message => ({ ok: true, serverId: 'mock', message, schedules });

async function handleApi(request, response, url) {
  if (url.pathname === '/api/auth/session') return sendJson(response, 200, { ok: true, authenticated: true, local: false, csrf: 'test', user: { username: 'admin', displayName: '管理员', canManagePlayerData: true } });
  if (url.pathname === '/api/status') return sendJson(response, 200, { ok: true, defaultServer: 'mock', serverTime: new Date().toISOString(), servers: [profile] });
  if (url.pathname === '/api/log') return sendJson(response, 200, { ok: true, serverId: 'mock', cursor: 0, reset: false, text: '' });
  if (url.pathname === '/api/chat') return sendJson(response, 200, { ok: true, serverId: 'mock', cursor: 0, file: '', messages: [] });
  if (url.pathname === '/api/players') return sendJson(response, 200, { ok: true, serverId: 'mock', onlineKnown: true, online: players, players });
  if (url.pathname === '/api/items/status') return sendJson(response, 200, { ok: true, serverId: 'mock', ready: false, cacheAvailable: false, building: false });
  if (url.pathname === '/api/notices/status') return sendJson(response, 200, { ok: true, serverId: 'mock', channel: { usable: true, v3Compatible: true, heartbeatAgeSeconds: 1 } });
  if (url.pathname === '/api/notices/receipt') return sendJson(response, 200, { ok: true, status: 'broadcast', expectedClients: 2, acknowledgedClients: 2, acknowledgedPlayers: ['Alice', '玩家乙'] });
  if (url.pathname === '/api/player-admin' && request.method === 'GET') return sendJson(response, 200, {
    ok: true, serverId: 'mock', serverName: '测试服务器', steamId: '76561198000000001', found: true,
    accounts: [{ username: 'Alice', displayName: 'Alice', lastConnection: new Date().toISOString(), steamId: '76561198000000001', ownerId: '', authType: 'Steam', role: 'user', online: true }],
    characters: [], allowed: true, banned: false, serverRunning: true, lifecycleActive: false,
  });
  if (url.pathname === '/api/player-admin/password' && request.method === 'POST') {
    requests.playerPassword = await readBody(request);
    return sendJson(response, 202, { ok: true, message: `账号 ${requests.playerPassword.username} 的密码修改命令已提交。`, requestId: 'password-request-1', command: '[redacted]' });
  }
  if (url.pathname === '/api/server-patches' && request.method === 'GET') return sendJson(response, 200, {
    ok: true, canManage: true,
    patch: {
      id: 'OrangeAntiCheat', name: 'OrangeAntiCheat 服务端命令防护', version: '2.0.0', protectedCommands: 13, enabled: true,
      scopes: [{ runtimeRoot: 'D:\\PZ Test Server', target: 'D:\\PZ Test Server\\server-patches\\OrangeAntiCheat-agent.jar', installed: true, installedVersion: '2.0.0', pendingRestart: false, servers: [{ id: 'mock', name: '测试服务器', running: true, configured: true, active: true, activeVersion: '2.0.0' }] }],
      sourceFiles: [{ path: 'patches/OrangeAntiCheat/manifest.json', present: true, sha256: 'a'.repeat(64) }],
    },
    components: [
      { id: 'OrangeAntiCheat', name: '服务端危险命令鉴权', technicalName: 'OrangeAntiCheat', category: '安全鉴权', description: 'Java Agent 在 Lua 事件触发前拒绝普通玩家调用原版管理员或调试命令，不修改任何游戏 Lua 文件。', target: 'LuaEventManager / TransactionManager', risk: '精确类哈希门禁，不修改存档。', version: '2.0.0', compatibility: 'PZ 42.20.2（精确类哈希）', manageable: true, enabled: true, scopes: [{ runtimeRoot: 'D:\\PZ Test Server', filePath: 'D:\\PZ Test Server\\server-patches\\OrangeAntiCheat-agent.jar', filePresent: true, fileVersion: '2.0.0', buildTime: '2026-08-21 18:00', sha256: 'c'.repeat(64), pendingRestart: false, servers: [{ id: 'mock', name: '测试服务器', running: true, configured: true, active: true, activeVersion: '2.0.0', detail: 'Java Agent 已生效' }] }] },
      { id: 'PZTimedActionIsolationFix', name: '多人长读条动作隔离', technicalName: 'PZTimedActionIsolationFix', category: '联机修复', description: '按玩家和动作实例精确停止制作、拆解、加油等动作，防止动作编号撞号误删其他玩家读条；这是一条故意较长的中文备注，用于验证表格会完整换行。', target: 'ActionManager.stop(Action)', risk: '不能与长读条诊断探针同时加载。', version: '', compatibility: 'PZ 42.20.x', manageable: false, enabled: true, scopes: [{ runtimeRoot: 'D:\\PZ Test Server', filePath: 'D:\\PZ Test Server\\server-patches\\PZTimedActionIsolationFix-agent.jar', filePresent: true, fileVersion: '', buildTime: '2026-08-20 11:50', sha256: 'b'.repeat(64), pendingRestart: false, servers: [{ id: 'mock', name: '测试服务器', running: true, configured: true, processMounted: true, active: false, activeVersion: '', detail: '当前 Java 进程已确认挂载；ACTIVE 在 PZ 日志初始化前输出，server-console 不会收录' }] }] },
    ],
    jarInventory: [{ name: 'OrangeAntiCheat-agent.jar', registered: true, componentId: 'OrangeAntiCheat', classification: 'registered', modifiedAt: '2026-08-24 12:00' }],
  });
  if ((url.pathname === '/api/anticheat' && request.method === 'GET') || (url.pathname === '/api/anticheat/scan' && request.method === 'POST')) {
    const result = {
    ok: true, serverId: 'mock', generatedAt: new Date().toISOString(), hours: 168, canBan: true,
    patch: { installed: true, active: true, pendingRestart: false, version: '2.0.0' },
    summary: { suspiciousPlayers: 2, criticalPlayers: 0, protectedCalls: 0, blockedCalls: 0, nativeSignals: 2, speedNoiseSignals: 1, checksumSignals: 0, bannedPlayers: 1 },
    diagnostics: { filesScanned: 12, linesScanned: 3200 },
    players: [
      { steamId: '76561198000000001', usernames: ['Alice'], ips: ['127.0.0.1'], score: 8, severity: 'low', protectedCalls: 0, blockedCalls: 0, nativeSignals: 1, actionableNativeSignals: 1, speedSignals: 0, speedNoiseSignals: 0, speedNoiseOnly: false, checksumSignals: 0, peakCommandsPerMinute: 12, firstSeen: new Date(Date.now() - 3600000).toISOString(), lastSeen: new Date().toISOString(), reasons: [{ label: '原版反作弊信号', count: 1, severity: 'warning' }], topCommands: [{ command: 'player.onHealthCheatCurrentPlayer', count: 1194 }, { command: 'PhunSprinters.isSprinter', count: 744 }, { command: 'OrangeTradingMod.RequestDomainState', count: 429 }, { command: 'newmusic_device.request_registry_sync', count: 363 }, { command: 'PZWebNotices.ack', count: 184 }, { command: 'LS.ChangeCharacterMoodGroup', count: 152 }, { command: 'LS.SavePlayerData', count: 114 }, { command: 'SleepWithFriends.Sleep', count: 95 }], banned: false },
      { steamId: '76561198000000003', usernames: ['LagPlayer'], ips: [], score: 0, severity: 'low', protectedCalls: 0, blockedCalls: 0, nativeSignals: 1, actionableNativeSignals: 0, speedSignals: 1, speedNoiseSignals: 1, speedNoiseOnly: true, checksumSignals: 0, peakCommandsPerMinute: 3, firstSeen: new Date(Date.now() - 7200000).toISOString(), lastSeen: new Date().toISOString(), reasons: [{ label: '速度信号（疑似网络波动）', count: 1, severity: 'low' }], topCommands: [], banned: false },
      { steamId: '76561198000000004', usernames: ['BannedPlayer'], ips: [], score: 82, severity: 'critical', protectedCalls: 1, blockedCalls: 0, nativeSignals: 0, actionableNativeSignals: 0, speedSignals: 0, speedNoiseSignals: 0, speedNoiseOnly: false, checksumSignals: 0, peakCommandsPerMinute: 4, firstSeen: new Date(Date.now() - 7200000).toISOString(), lastSeen: new Date().toISOString(), reasons: [{ label: '未授权调试命令', count: 1, severity: 'critical' }], topCommands: [], banned: true, banReason: 'Confirmed exploit' },
    ],
    events: [
      { time: new Date().toISOString(), severity: 'high', type: 'native-anticheat', code: 'Power', steamId: '76561198000000001', username: 'Alice', detail: 'PlayerPacketReliable: invalid mode；action=Log', sourceFile: 'Logs/example_DebugLog-server-with-a-deliberately-long-name.txt', lineNumber: 12 },
      { time: new Date().toISOString(), severity: 'critical', type: 'protected-command', code: 'health-cheat', command: 'player.onHealthCheatCurrentPlayer', steamId: '76561198000000001', username: 'Alice', detail: '客户端调用了仅应由管理员或调试权限使用的原版命令。', coordinate: '10000,9000,0', sourceFile: 'Logs/example_cmd.txt', lineNumber: 14 },
      { time: new Date().toISOString(), severity: 'low', type: 'native-anticheat', code: 'Speed', speed: 24, noiseLikely: true, steamId: '76561198000000003', username: 'LagPlayer', detail: 'speed=24 > limit=20', sourceFile: 'Logs/example_DebugLog-server.txt', lineNumber: 13 },
    ],
    banSummary: { count: 1, targets: [{ id: 'server2', name: '2服' }] },
    };
    return sendJson(response, 200, url.pathname === '/api/anticheat/scan' ? {
      ok: true, id: 'b'.repeat(32), status: 'complete', serverId: 'mock', hours: 168,
      progress: { status: 'complete', phase: 'cached', percent: 100, message: '已命中分析缓存', filesDone: 12, filesTotal: 12, bytesDone: 1048576, bytesTotal: 1048576, linesScanned: 3200 },
      result,
    } : result);
  }
  if (url.pathname === '/api/anticheat/bans/sync' && request.method === 'POST') {
    requests.banSync = await readBody(request);
    return sendJson(response, 200, { ok: true, sourceServerId: 'mock', sourceCount: 1, added: 1, message: '封禁名单合并同步已提交，共补充 1 条。', results: [{ serverId: 'server2', name: '2服', status: 'queued', added: 1, mode: 'server-command', message: '1 条封禁已进入运行中服务器的命令队列。' }] });
  }
  if (url.pathname === '/api/anticheat/analyze-player' && request.method === 'POST') {
    requests.playerAudit = await readBody(request);
    return sendJson(response, 202, { ok: true, id: 'a'.repeat(32), status: 'analyzing', message: '只读证据包已构建，AI 正在分析。' });
  }
  if (url.pathname === '/api/anticheat/analyze-player' && request.method === 'GET') return sendJson(response, 200, {
    ok: true, id: 'a'.repeat(32), status: 'completed', serverId: 'mock', steamId: '76561198000000001', username: 'Alice', hours: 168,
    model: 'test-model', evidenceGeneratedAt: new Date().toISOString(), evidenceSummary: { filesScanned: 12, commands: 20, adminHits: 0, itemHits: 0, nativeAntiCheat: 1, blockedOrProtected: 0, economyAvailable: true, economyEvents: 42, balanceDiscontinuities: 0, lifestyleUnmatched: 0 },
    report: { verdict: '需要观察', riskLevel: 'warning', confidence: 78, summary: '存在一条原版速度信号，但经济流水连续且 Lifestyle Add/Remove 已配对，当前不能据此认定作弊。', findings: [{ severity: 'warning', title: '原版速度信号需要复核', evidence: ['Logs/example_DebugLog-server.txt:12'], interpretation: '单一速度信号可能由网络或载具导致。' }, { severity: 'info', title: '经济流水连续', evidence: ['42 条流水，余额断点 0'], interpretation: '未发现无来源余额增长。' }], limitations: ['没有日志命中不等于绝对证明无作弊。'], recommendedActions: ['继续观察并人工核对同一时段连接质量。'] }, error: '',
  });
  if (url.pathname === '/api/command/submission') {
    requests.itemSubmissionQueries += 1;
    const submissionId = url.searchParams.get('id');
    if (requests.itemGrant?.submissionId === submissionId) return sendJson(response, 200, { ok: true, found: true, recovered: true, submissionId, action: 'additem', status: 'success', resultCode: 'completed', resultMessage: '物品发放进度：游戏确认成功 1/1，明确失败 0，待确认 0，排队 0。', requestId: 'item-request-1', requestIds: ['item-request-1'], itemRequestIds: ['item-request-1'], notificationRequestIds: ['broadcast-request-1'], noticeId: 'notice-test', targetCount: 1 });
    return sendJson(response, 200, { ok: true, found: false, submissionId });
  }
  if (url.pathname === '/api/command/results') {
    requests.itemResultQueries += 1;
    return sendJson(response, 503, { ok: false, error: 'Simulated expensive log scan failure.' });
  }
  if (url.pathname === '/api/command/result') return sendJson(response, 200, { ok: true, status: 'delivered', done: true, receipt: { status: 'completed' }, output: [] });
  if (url.pathname === '/api/command' && request.method === 'POST') {
    const body = await readBody(request);
    if (body.action === 'access') requests.access = body;
    if (body.action === 'additem') {
      requests.itemGrant = body;
      await new Promise(resolve => setTimeout(resolve, 5500));
      return sendJson(response, 202, {
        ok: true, message: 'Item grant and notifications queued.', submissionId: body.submissionId, requestId: 'item-request-1',
        requestIds: ['item-request-1'], itemRequestIds: ['item-request-1'], notificationRequestIds: ['broadcast-request-1'],
        allRequestIds: ['item-request-1', 'broadcast-request-1'], noticeId: 'notice-test', notificationChannel: body.notificationChannel,
        notificationWarnings: [], expectedNoticeClients: 2, targetCount: body.usernames.length,
        immediateItemResult: { settled: true, submission: { ok: true, found: true, submissionId: body.submissionId, action: 'additem', status: 'success', resultCode: 'completed', resultMessage: '物品发放进度：游戏确认成功 1/1，明确失败 0，待确认 0，排队 0。', targetCount: body.usernames.length } },
      });
    }
    return sendJson(response, 202, { ok: true, message: 'Command queued.', requestId: 'command-request-1', requestIds: ['command-request-1'] });
  }

  if (url.pathname === '/api/ai/config') return sendJson(response, 200, {
    ok: true, enabled: false, provider: 'openai-responses', authMode: 'bearer', apiUrl: 'https://api.example/v1',
    model: 'test-model', reasoningEffort: 'high', disableResponseStorage: true, temperature: 0.3,
    maxTokens: 700, maxReplyCharacters: 900, requestTimeoutSeconds: 60, maximumAttempts: 3, memoryTurns: 8,
    memoryMinutes: 30, noticeDurationSeconds: 15, apiKeyConfigured: true,
    credentialStorage: 'Windows DPAPI（当前面板运行用户）',
    allServers: [{ id: 'mock', name: '测试服务器', enabled: false }],
  });
  if (url.pathname === '/api/ai/status') return sendJson(response, 200, {
    ok: true, enabled: false, running: false, processing: false, readOnly: true, version: '0.4.0',
    provider: 'openai-responses', model: 'test-model', monitoredServers: [], pendingCount: 0,
    requestProtocol: 'managed-response-queue/1', dispatchProof: 'agent.response',
  });
  if (url.pathname === '/api/ai/log') return sendJson(response, 200, { ok: true, lines: ['INFO\t内置 Bridge 测试日志'], tail: 200, path: 'ai-bridge.log' });
  if (url.pathname === '/api/ai/runtime' && request.method === 'POST') {
    requests.aiRuntime = await readBody(request);
    return sendJson(response, 200, {
      ok: true, message: 'Bridge 运行状态已更新。', enabled: requests.aiRuntime.action !== 'stop',
      running: requests.aiRuntime.action !== 'stop', processing: false, readOnly: true, version: '0.4.0',
      provider: 'openai-responses', model: 'test-model', monitoredServers: [], pendingCount: 0,
      requestProtocol: 'managed-response-queue/1', dispatchProof: 'agent.response',
    });
  }
  if (url.pathname === '/api/ai/requests') return sendJson(response, 200, { ok: true, requests: [] });
  if (url.pathname === '/api/ai/policies' && request.method === 'GET') return sendJson(response, 200, policyPayload());
  if (url.pathname === '/api/ai/policies' && request.method === 'POST') {
    requests.policy = await readBody(request);
    policies = [{ ...requests.policy, id: 'policy-1', createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() }];
    return sendJson(response, 201, policyPayload('AI 玩家授权已保存。当前执行器尚未接入。'));
  }

  if (url.pathname === '/api/broadcast-schedules' && request.method === 'GET') return sendJson(response, 200, schedulePayload());
  if (url.pathname === '/api/broadcast-schedules' && request.method === 'POST') {
    requests.schedule = await readBody(request);
    const now = new Date();
    schedules = [{ ...requests.schedule, id: 'schedule-1', nextRunAt: new Date(now.getTime() + requests.schedule.intervalMinutes * 60000).toISOString(), lastRunAt: null, lastStatus: 'never', lastMessage: '尚未执行。', createdAt: now.toISOString(), updatedAt: now.toISOString() }];
    return sendJson(response, 201, schedulePayload('循环广播任务已保存。'));
  }
  if (url.pathname === '/api/broadcast-schedules/run-now' && request.method === 'POST') {
    requests.runNow = await readBody(request);
    const now = new Date();
    schedules[0] = { ...schedules[0], lastRunAt: now.toISOString(), nextRunAt: new Date(now.getTime() + schedules[0].intervalMinutes * 60000).toISOString(), lastStatus: 'queued', lastMessage: '已提交：原生全服广播 + Mod 弹窗' };
    history.push({ id: 'history-broadcast', serverId: 'mock', category: 'broadcast', action: 'scheduled-broadcast', source: 'scheduled', summary: schedules[0].name, status: 'success', resultCode: 'delivered', message: '原生广播已写入控制台；Mod 弹窗已由服务端发送，客户端确认 2/2。', detail: schedules[0].message, createdAt: now.toISOString(), updatedAt: now.toISOString() });
    return sendJson(response, 202, schedulePayload(schedules[0].lastMessage));
  }

  if (url.pathname === '/api/execution-history') return sendJson(response, 200, { ok: true, serverId: 'mock', records: [...history].reverse() });
  if (url.pathname === '/api/maintenance/schedule') return sendJson(response, 200, { ok: true, serverId: 'mock', enabled: true, intervalHours: 3, nextRunAt: new Date(Date.now() + 10800000).toISOString(), running: false, lastRunAt: history[0].createdAt, lastStatus: 'current', lastResultCode: 'mods-current', lastMessage: history[0].message, updateNotificationPending: false });
  if (url.pathname === '/api/server/operation') return sendJson(response, 200, { ok: true, available: false, operation: null });
  if (url.pathname === '/api/audit') return sendJson(response, 200, { ok: true, lines: [] });
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
    response.writeHead(200, { 'Content-Type': contentTypes[path.extname(filePath)] || 'application/octet-stream' });
    response.end(fs.readFileSync(filePath));
  } catch (error) {
    response.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
    response.end(error.stack || error.message);
  }
});

function collectErrors(page, label, errors) {
  page.on('pageerror', error => errors.push(`${label} pageerror: ${error.message}`));
  page.on('console', message => { if (message.type() === 'error') errors.push(`${label} console: ${message.text()}`); });
}

async function layout(page, selectors) {
  return page.evaluate(selectors => {
    const root = document.documentElement;
    const bounds = Object.fromEntries(selectors.map(selector => {
      const rect = document.querySelector(selector).getBoundingClientRect();
      return [selector, { left: rect.left, right: rect.right, width: rect.width }];
    }));
    const clippedButtons = [...document.querySelectorAll('.view.active button')].filter(button => button.scrollWidth > button.clientWidth + 2).map(button => button.textContent.trim());
    const overflowers = [...document.querySelectorAll('.view.active *')].map(element => {
      const rect = element.getBoundingClientRect();
      return { tag: element.tagName, id: element.id, className: String(element.className || ''), left: rect.left, right: rect.right, width: rect.width, scrollWidth: element.scrollWidth };
    }).filter(item => item.right > root.clientWidth + 1 || item.left < -1 || item.scrollWidth > item.width + 2).sort((a, b) => b.right - a.right).slice(0, 12);
    return { clientWidth: root.clientWidth, scrollWidth: root.scrollWidth, bounds, clippedButtons, overflowers };
  }, selectors);
}

async function clickMobileView(page, view) {
  await page.click('#mobileMenuToggle');
  await page.waitForFunction(() => document.querySelector('#mobileNav').classList.contains('expanded'));
  await page.click(`.mobile-nav [data-view="${view}"]`);
  await page.waitForFunction(view => document.querySelector(`#view-${view}`).classList.contains('active'), view);
}

(async () => {
  await new Promise((resolve, reject) => { testServer.once('error', reject); testServer.listen(0, '127.0.0.1', resolve); });
  const port = testServer.address().port;
  const browser = await chromium.launch({ executablePath: edgePath, headless: true });
  const errors = [];
  try {
    const desktop = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    collectErrors(desktop, 'desktop', errors);
    await desktop.addInitScript(() => { window.confirm = () => true; });
    await desktop.goto(`http://127.0.0.1:${port}/?view=ai&server=mock`, { waitUntil: 'domcontentloaded' });
    await desktop.waitForSelector('#authScreen', { state: 'hidden' });
    try {
      await desktop.waitForFunction(() => document.querySelectorAll('#aiOperationPicker input').length === 3 && document.querySelectorAll('#aiPolicyPlayerOptions option').length === 2, null, { timeout: 10000 });
    } catch (error) {
      const state = await desktop.evaluate(() => ({
        operations: document.querySelectorAll('#aiOperationPicker input').length,
        playerOptions: document.querySelectorAll('#aiPolicyPlayerOptions option').length,
        serverId: document.querySelector('#aiPolicyForm select[name="serverId"]').value,
        policyText: document.querySelector('#aiPolicyList').textContent,
        toast: document.querySelector('#toast').textContent,
      }));
      throw new Error(`AI fixture did not settle: ${JSON.stringify(state)}; browser errors: ${errors.join(' | ')}`);
    }
    await desktop.click('#restartAI');
    await desktop.waitForFunction(() => document.querySelector('#toast').textContent.includes('Bridge'));
    if (!requests.aiRuntime || requests.aiRuntime.action !== 'restart') throw new Error('AI Bridge restart action was not sent.');
    await desktop.fill('#aiPolicyForm input[name="username"]', 'Alice');
    await desktop.locator('#aiPolicyForm input[name="username"]').dispatchEvent('change');
    await desktop.waitForFunction(() => document.querySelector('#aiPolicyForm input[name="steamId"]').value === '76561198000000001');
    await desktop.check('#aiOperationPicker input[value="query_status"]');
    await desktop.check('#aiOperationPicker input[value="give_self_item"]');
    await desktop.click('#aiPolicyForm button[type="submit"]');
    await desktop.waitForFunction(() => document.querySelector('#aiPolicyList').textContent.includes('76561198000000001'));
    const aiLayout = await layout(desktop, ['#view-ai .page-heading', '#view-ai .heading-actions', '.ai-layout', '.ai-bridge-log', '.ai-policy-section', '#aiPolicyForm', '#aiPolicyList']);

    await desktop.click('.nav-item[data-view="anticheat"]');
    await desktop.waitForFunction(() => document.querySelectorAll('.anticheat-player-row').length === 2 && document.querySelector('.ban-state-badge')?.textContent.includes('已封禁'));
    await desktop.waitForFunction(() => document.querySelector('#antiCheatEvents').textContent.includes('权限或数据包模式异常') && document.querySelector('#antiCheatEvents').textContent.includes('健康操作回传'));
    await desktop.check('#antiCheatHideBanned');
    await desktop.waitForFunction(() => document.querySelectorAll('.anticheat-player-row').length === 1);
    await desktop.uncheck('#antiCheatHideBanned');
    await desktop.uncheck('#antiCheatHideSpeedNoise');
    await desktop.waitForFunction(() => document.querySelectorAll('.anticheat-player-row').length === 3);
    await desktop.check('#antiCheatHideSpeedNoise');
    await desktop.click('#openAntiCheatBanSync');
    await desktop.waitForSelector('#antiCheatBanSyncDialog', { state: 'visible' });
    await desktop.click('#antiCheatBanSyncForm button[type="submit"]');
    await desktop.waitForFunction(() => document.querySelector('#antiCheatBanSyncSummary').textContent.includes('共补充 1 条'));
    await desktop.click('#closeAntiCheatBanSync');
    await desktop.locator('.anticheat-player-row').filter({ hasText: 'Alice' }).click();
    await desktop.click('#analyzeAntiCheatPlayer');
    await desktop.waitForFunction(() => document.querySelector('.anticheat-ai-report.completed')?.textContent.includes('需要观察'));
    const antiCheatLayout = await layout(desktop, ['.anticheat-scan-progress', '.anticheat-layout', '.anticheat-player-list', '.anticheat-detail', '.anticheat-ai-report', '.anticheat-events']);
    const antiCheatLocalization = await desktop.evaluate(() => ({
      signalGuideText: document.querySelector('#antiCheatSignalGuide').textContent,
      eventText: document.querySelector('#antiCheatEvents').textContent,
      commandText: document.querySelector('.anticheat-command-summary').textContent,
      actionWhiteSpace: getComputedStyle(document.querySelector('.anticheat-event-action p')).whiteSpace,
      actionOverflow: getComputedStyle(document.querySelector('.anticheat-event-action p')).overflow,
    }));
    await desktop.screenshot({ path: path.join(__dirname, 'pz-panel-player-ai-audit-desktop.png'), fullPage: true });

    await desktop.click('.nav-item[data-view="patches"]');
    await desktop.waitForFunction(() => document.querySelectorAll('#serverPatchComponents tr').length === 2 && document.querySelector('#serverPatchComponents').textContent.includes('多人长读条动作隔离'));
    const patchLayout = await layout(desktop, ['#view-patches .page-heading', '.patch-summary-band', '.server-patch-mount', '.server-patch-table-wrap', '.server-patch-table']);
    const patchLocalization = await desktop.evaluate(() => ({
      componentText: document.querySelector('#serverPatchComponents').textContent,
      summaryText: document.querySelector('.patch-summary-band').textContent,
      inventoryText: document.querySelector('#serverPatchInventory').textContent,
    }));
    await desktop.screenshot({ path: path.join(__dirname, 'pz-panel-java-patches-desktop.png'), fullPage: true });

    await desktop.click('.nav-item[data-view="players"]');
    await desktop.waitForFunction(() => document.querySelectorAll('#grantForm .online-player-select option').length === 3);
    await desktop.fill('#playerAdminLookupForm input[name="steamId"]', '76561198000000001');
    await desktop.click('#playerAdminLookupForm button[type="submit"]');
    await desktop.waitForFunction(() => document.querySelector('#playerAdminResult').hidden === false && document.querySelector('#playerPasswordForm select[name="username"]').value === 'Alice');
    await desktop.fill('#playerPasswordForm input[name="password"]', 'new-test-password');
    await desktop.fill('#playerPasswordForm input[name="passwordConfirm"]', 'new-test-password');
    await desktop.click('#playerPasswordForm button[type="submit"]');
    await desktop.waitForFunction(() => document.querySelector('#toast').textContent.includes('密码修改命令已提交'));
    const passwordFieldsCleared = await desktop.evaluate(() => !document.querySelector('#playerPasswordForm input[name="password"]').value && !document.querySelector('#playerPasswordForm input[name="passwordConfirm"]').value);
    await desktop.fill('#accessForm input[name="username"]', 'Alice');
    await desktop.click('#accessForm button[data-access="user"]');
    await desktop.waitForFunction(() => document.querySelector('#commandResultTitle').textContent.includes('修改访问级别'));
    await desktop.selectOption('#grantForm .online-player-select', 'Alice');
    await desktop.fill('#grantForm input[name="count"]', '2');
    await desktop.selectOption('#grantForm select[name="notificationChannel"]', 'both');
    await desktop.fill('#grantForm textarea[name="notificationMessage"]', '管理员已发放活动物资，请检查背包。');
    await desktop.fill('#grantForm input[name="notificationDuration"]', '25');
    await desktop.click('#grantForm button[type="submit"]');
    try {
      await desktop.waitForFunction(() => document.querySelector('#commandResultTitle').textContent.includes('物品发放已由游戏服务器确认'));
    } catch (error) {
      const itemGrantDebug = await desktop.evaluate(() => ({
        title: document.querySelector('#commandResultTitle').textContent,
        meta: document.querySelector('#commandResultMeta').textContent,
        output: document.querySelector('#commandResultOutput').textContent,
      }));
      throw new Error(`Item grant did not settle: ${JSON.stringify(itemGrantDebug)}; requests=${JSON.stringify(requests)}; browserErrors=${errors.join(' | ')}; ${error.message}`);
    }
    await desktop.waitForFunction(() => document.querySelector('#commandResultOutput').textContent.includes('游戏确认成功 1/1'));
    const itemGrantLayout = await layout(desktop, ['#grantForm', '.item-grant-notification', '#commandResultTray']);

    for (let index = 1; index <= 40; index += 1) players.push({ username: `历史玩家${String(index).padStart(2, '0')}`, steamId: `7656119810000${String(index).padStart(4, '0')}`, online: false, role: 'user', lastConnection: '2026-08-20 12:00' });
    await desktop.evaluate(() => refreshPlayers());
    await desktop.waitForFunction(() => document.querySelectorAll('.player-history .player-table-row').length === 40);
    await desktop.click('.player-history summary');
    await desktop.locator('.player-history .player-table-row').nth(30).scrollIntoViewIfNeeded();
    const playerHistoryBeforeRefresh = await desktop.evaluate(() => ({ open: document.querySelector('.player-history').open, scrollY: window.scrollY }));
    await desktop.evaluate(() => refreshPlayers());
    await desktop.waitForFunction(() => document.querySelector('.player-history')?.open && document.querySelectorAll('.player-history .player-table-row').length === 40);
    const playerHistoryAfterRefresh = await desktop.evaluate(() => ({ open: document.querySelector('.player-history').open, scrollY: window.scrollY }));
    const playerHistoryRefresh = { before: playerHistoryBeforeRefresh, after: playerHistoryAfterRefresh, scrollDelta: Math.abs(playerHistoryAfterRefresh.scrollY - playerHistoryBeforeRefresh.scrollY) };

    await desktop.click('.nav-item[data-view="chat"]');
    await desktop.waitForFunction(() => document.querySelector('#broadcastScheduleList').textContent.includes('没有循环广播'));
    await desktop.fill('#broadcastScheduleForm input[name="name"]', '每小时维护提醒');
    await desktop.selectOption('#broadcastScheduleForm select[name="channel"]', 'both');
    await desktop.fill('#broadcastScheduleForm input[name="intervalMinutes"]', '60');
    await desktop.selectOption('#broadcastScheduleForm select[name="style"]', 'warning');
    await desktop.fill('#broadcastScheduleForm input[name="duration"]', '120');
    await desktop.fill('#broadcastScheduleForm input[name="title"]', '服务器维护提示');
    await desktop.fill('#broadcastScheduleForm textarea[name="message"]', '请及时回到安全区域，留意后续维护通知。');
    await desktop.click('#broadcastScheduleForm button[type="submit"]');
    await desktop.waitForFunction(() => document.querySelector('#broadcastScheduleList').textContent.includes('每小时维护提醒'));
    await desktop.click('#runBroadcastScheduleNow');
    await desktop.waitForFunction(() => document.querySelector('#broadcastScheduleList').textContent.includes('原生全服广播 + Mod 弹窗'));
    const chatLayout = await layout(desktop, ['.broadcast-scheduler', '#broadcastScheduleForm', '#broadcastScheduleList']);

    await desktop.click('.nav-item[data-view="maintenance"]');
    await desktop.waitForFunction(() => document.querySelectorAll('.execution-history-row').length === 2);
    await desktop.locator('.execution-history-row').first().click();
    await desktop.waitForFunction(() => document.querySelector('.execution-history-row[open]')?.textContent.includes('客户端确认 2/2'));
    const historyLayout = await layout(desktop, ['.execution-history', '#executionHistoryList']);
    await desktop.screenshot({ path: path.join(__dirname, 'pz-panel-control-features-desktop.png'), fullPage: true });

    const mobile = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true });
    collectErrors(mobile, 'mobile', errors);
    await mobile.goto(`http://127.0.0.1:${port}/?view=chat&server=mock`, { waitUntil: 'domcontentloaded' });
    await mobile.waitForSelector('#authScreen', { state: 'hidden' });
    await mobile.waitForFunction(() => document.querySelector('#broadcastScheduleList').textContent.includes('每小时维护提醒'));
    const mobileChatLayout = await layout(mobile, ['.broadcast-scheduler', '#broadcastScheduleForm', '#broadcastScheduleList']);
    await mobile.screenshot({ path: path.join(__dirname, 'pz-panel-control-features-mobile.png'), fullPage: true });

    await clickMobileView(mobile, 'players');
    await mobile.waitForFunction(() => document.querySelectorAll('#grantForm .online-player-select option').length === 3);
    await mobile.click('.player-history summary');
    await mobile.locator('.player-history .player-table-row').nth(30).scrollIntoViewIfNeeded();
    const mobilePlayerHistoryBeforeRefresh = await mobile.evaluate(() => ({ open: document.querySelector('.player-history').open, scrollY: window.scrollY }));
    await mobile.evaluate(() => refreshPlayers());
    await mobile.waitForFunction(() => document.querySelector('.player-history')?.open && document.querySelectorAll('.player-history .player-table-row').length === 40);
    const mobilePlayerHistoryAfterRefresh = await mobile.evaluate(() => ({ open: document.querySelector('.player-history').open, scrollY: window.scrollY }));
    const mobilePlayerHistoryRefresh = { before: mobilePlayerHistoryBeforeRefresh, after: mobilePlayerHistoryAfterRefresh, scrollDelta: Math.abs(mobilePlayerHistoryAfterRefresh.scrollY - mobilePlayerHistoryBeforeRefresh.scrollY) };
    await mobile.selectOption('#grantForm select[name="notificationChannel"]', 'both');
    const mobileItemGrantLayout = await layout(mobile, ['#grantForm', '.item-grant-notification']);

    await clickMobileView(mobile, 'anticheat');
    await mobile.waitForFunction(() => document.querySelectorAll('.anticheat-player-row').length === 2);
    await mobile.locator('.anticheat-player-row').filter({ hasText: 'Alice' }).click();
    await mobile.click('#analyzeAntiCheatPlayer');
    await mobile.waitForFunction(() => document.querySelector('.anticheat-ai-report.completed')?.textContent.includes('需要观察'));
    const mobileAntiCheatLayout = await layout(mobile, ['.mobile-nav', '#mobileMenuToggle', '.anticheat-scan-progress', '.anticheat-signal-guide', '.anticheat-layout', '.anticheat-player-list', '.anticheat-detail', '.anticheat-ai-report', '.anticheat-events']);
    await mobile.screenshot({ path: path.join(__dirname, 'pz-panel-player-ai-audit-mobile.png'), fullPage: true });

    await clickMobileView(mobile, 'patches');
    await mobile.waitForFunction(() => document.querySelectorAll('#serverPatchComponents tr').length === 2 && document.querySelector('#serverPatchComponents').textContent.includes('多人长读条动作隔离'));
    const mobilePatchLayout = await layout(mobile, ['.mobile-nav', '#mobileMenuToggle', '#view-patches .page-heading', '.patch-summary-band', '.server-patch-mount', '.server-patch-table-wrap', '.server-patch-table']);
    await mobile.screenshot({ path: path.join(__dirname, 'pz-panel-java-patches-mobile.png'), fullPage: true });

    await clickMobileView(mobile, 'ai');
    await mobile.waitForFunction(() => document.querySelector('#aiPolicyList').textContent.includes('76561198000000001'));
    const mobileAccess = await mobile.evaluate(() => ({
      aiVisible: !document.querySelector('.mobile-nav [data-view="ai"]').hidden,
      antiCheatVisible: !document.querySelector('.mobile-nav [data-view="anticheat"]').hidden,
      pageCount: [...document.querySelectorAll('.mobile-nav [data-view]')].filter(button => !button.hidden).length,
      usersHidden: document.querySelector('.mobile-nav [data-view="users"]').hidden,
      activeView: document.querySelector('.view.active')?.id,
    }));
    const mobileAiLayout = await layout(mobile, ['#view-ai .page-heading', '#view-ai .heading-actions', '.ai-layout', '.ai-bridge-log', '.ai-policy-section', '#aiPolicyForm', '#aiPolicyList']);
    await mobile.screenshot({ path: path.join(__dirname, 'pz-panel-ai-policy-mobile.png'), fullPage: true });

    await clickMobileView(mobile, 'maintenance');
    await mobile.waitForFunction(() => document.querySelectorAll('.execution-history-row').length === 2);
    await mobile.locator('.execution-history-row').first().click();
    const mobileHistoryLayout = await layout(mobile, ['.execution-history', '#executionHistoryList']);
    await mobile.screenshot({ path: path.join(__dirname, 'pz-panel-execution-history-mobile.png'), fullPage: true });

    const result = { requests, policyCount: policies.length, scheduleCount: schedules.length, historyCount: history.length, antiCheatLocalization, patchLocalization, playerHistoryRefresh, mobilePlayerHistoryRefresh, desktop: { ai: aiLayout, anticheat: antiCheatLayout, patches: patchLayout, itemGrant: itemGrantLayout, chat: chatLayout, history: historyLayout }, mobile: { access: mobileAccess, chat: mobileChatLayout, itemGrant: mobileItemGrantLayout, anticheat: mobileAntiCheatLayout, patches: mobilePatchLayout, ai: mobileAiLayout, history: mobileHistoryLayout }, browserErrors: errors };
    console.log(JSON.stringify(result, null, 2));
    if (errors.length) process.exitCode = 2;
    if (!requests.policy || requests.policy.serverId !== 'mock' || requests.policy.username !== 'Alice' || requests.policy.steamId !== '76561198000000001' || requests.policy.trustedAll || requests.policy.allowedOperations.length !== 2) process.exitCode = 3;
    if (!requests.schedule || requests.schedule.channel !== 'both' || requests.schedule.intervalMinutes !== 60 || requests.schedule.duration !== 120) process.exitCode = 4;
    if (!requests.access || requests.access.action !== 'access' || requests.access.username !== 'Alice' || requests.access.level !== 'user') process.exitCode = 13;
    if (!requests.playerPassword || requests.playerPassword.serverId !== 'mock' || requests.playerPassword.steamId !== '76561198000000001' || requests.playerPassword.username !== 'Alice' || requests.playerPassword.password !== 'new-test-password' || !passwordFieldsCleared) process.exitCode = 14;
    if (!requests.runNow || requests.runNow.id !== 'schedule-1' || history.length !== 2) process.exitCode = 5;
    if (!requests.itemGrant || requests.itemGrant.notificationChannel !== 'both' || requests.itemGrant.notificationDuration !== 25 || requests.itemGrant.usernames[0] !== 'Alice' || requests.itemGrant.count !== 2 || !/^[a-f0-9]{32}$/.test(requests.itemGrant.submissionId)) process.exitCode = 7;
    if (requests.itemResultQueries !== 0 || requests.itemSubmissionQueries !== 0) process.exitCode = 10;
    if (!mobileAccess.aiVisible || !mobileAccess.antiCheatVisible || mobileAccess.pageCount !== 16 || !mobileAccess.usersHidden || mobileAccess.activeView !== 'view-ai') process.exitCode = 8;
    if (!requests.aiRuntime || requests.aiRuntime.action !== 'restart') process.exitCode = 9;
    if (!requests.playerAudit || requests.playerAudit.serverId !== 'mock' || requests.playerAudit.steamId !== '76561198000000001' || requests.playerAudit.username !== 'Alice' || requests.playerAudit.hours !== 168) process.exitCode = 15;
    if (!requests.banSync || requests.banSync.sourceServerId !== 'mock' || requests.banSync.targetServerIds[0] !== 'server2' || requests.banSync.confirm !== 'SYNC_BANNED_STEAM_IDS') process.exitCode = 16;
    if (!antiCheatLocalization.signalGuideText.includes('权限或数据包模式异常') || !antiCheatLocalization.signalGuideText.includes('移动速度信号') || !antiCheatLocalization.signalGuideText.includes('Lua / 脚本完整性不一致') || !antiCheatLocalization.eventText.includes('命令鉴权') || !antiCheatLocalization.eventText.includes('原版只记录日志，未自动处罚') || !antiCheatLocalization.commandText.includes('查询奔跑者僵尸状态') || !antiCheatLocalization.commandText.includes('常规确认回执') || !antiCheatLocalization.commandText.includes('同步多人睡眠状态') || !antiCheatLocalization.commandText.includes('已配对记录不计风险') || antiCheatLocalization.actionWhiteSpace !== 'normal' || antiCheatLocalization.actionOverflow === 'hidden') process.exitCode = 17;
    if (!patchLocalization.componentText.includes('多人长读条动作隔离') || !patchLocalization.componentText.includes('独立构建') || !patchLocalization.componentText.includes('目标：ActionManager.stop(Action)') || !patchLocalization.componentText.includes('边界：不能与长读条诊断探针同时加载') || !patchLocalization.componentText.includes('进程已确认挂载') || !patchLocalization.componentText.includes('server-console 不会收录') || !patchLocalization.summaryText.includes('运行已验证') || !patchLocalization.inventoryText.includes('OrangeAntiCheat-agent.jar')) process.exitCode = 20;
    if (!playerHistoryRefresh.before.open || !playerHistoryRefresh.after.open || playerHistoryRefresh.before.scrollY < 300 || playerHistoryRefresh.scrollDelta > 2) process.exitCode = 18;
    if (!mobilePlayerHistoryRefresh.before.open || !mobilePlayerHistoryRefresh.after.open || mobilePlayerHistoryRefresh.before.scrollY < 300 || mobilePlayerHistoryRefresh.scrollDelta > 2) process.exitCode = 19;
    for (const state of [aiLayout, antiCheatLayout, patchLayout, itemGrantLayout, chatLayout, historyLayout, mobileChatLayout, mobileItemGrantLayout, mobileAntiCheatLayout, mobilePatchLayout, mobileAiLayout, mobileHistoryLayout]) {
      if (state.scrollWidth > state.clientWidth || state.clippedButtons.length || Object.values(state.bounds).some(rect => rect.left < -1 || rect.right > state.clientWidth + 1)) process.exitCode = 6;
    }
  } finally {
    await browser.close();
    await new Promise(resolve => testServer.close(resolve));
  }
})().catch(error => { console.error(error.stack || error.message); testServer.close(); process.exit(1); });
