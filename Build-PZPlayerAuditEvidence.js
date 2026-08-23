'use strict';

const fs = require('fs');
const path = require('path');

const dataRoot = path.resolve(process.argv[2] || '');
const runtimeRoot = path.resolve(process.argv[3] || '');
const serverName = String(process.argv[4] || '').trim();
const hours = Math.min(720, Math.max(1, Number(process.argv[5] || 168)));
const requestedSteamId = String(process.argv[6] || '').trim();
const requestedUsername = String(process.argv[7] || '').trim();
const cutoff = Date.now() - hours * 3600000;
const logsRoot = path.join(dataRoot, 'Logs');
const consoleLogPath = path.join(dataRoot, 'server-console.txt');
const modDataPath = path.join(dataRoot, 'Saves', 'Multiplayer', serverName, 'global_mod_data.bin');

if (!dataRoot || !runtimeRoot || !serverName) throw new Error('Missing server path arguments.');
if (!/^7656119\d{10}$/.test(requestedSteamId) && !requestedUsername) throw new Error('SteamID or username is required.');

function walk(root, result = []) {
  if (!fs.existsSync(root)) return result;
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const full = path.join(root, entry.name);
    if (entry.isDirectory()) walk(full, result);
    else if (entry.isFile()) result.push(full);
  }
  return result;
}

function parsePzTime(text) {
  const match = /^(\d{2})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3})$/.exec(text || '');
  if (!match) return null;
  return new Date(2000 + Number(match[3]), Number(match[2]) - 1, Number(match[1]), Number(match[4]), Number(match[5]), Number(match[6]), Number(match[7]));
}

function lineTime(line) {
  const match = /^\[([^\]]+)\]/.exec(line);
  const date = match ? parsePzTime(match[1]) : null;
  return { raw: match ? match[1] : '', iso: date && !Number.isNaN(date.getTime()) ? date.toISOString() : '', date };
}

function source(file, lineNumber) {
  return `${path.relative(dataRoot, file).replace(/\\/g, '/')}:${lineNumber}`;
}

function maskIp(value) {
  const ip = String(value || '').replace(/^\//, '').split(':')[0];
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(ip)) return ip.replace(/\.\d+$/, '.x');
  return ip ? '[masked]' : '';
}

function compactLine(line, maximum = 420) {
  return String(line || '').replace(/ip="[^"]+"/gi, 'ip="[masked]"').replace(/\s+/g, ' ').trim().slice(0, maximum);
}

function isPrivilegedRole(role) {
  return ['admin', 'moderator', 'overseer', 'gm'].includes(String(role || '').toLowerCase());
}

function readLogLines(file) {
  if (path.basename(file).toLowerCase() !== 'server-console.txt') {
    return fs.readFileSync(file, 'utf8').split(/\r?\n/);
  }
  const maximum = 16 * 1024 * 1024;
  const stat = fs.statSync(file);
  const start = Math.max(0, stat.size - maximum);
  const descriptor = fs.openSync(file, 'r');
  try {
    const buffer = Buffer.alloc(stat.size - start);
    fs.readSync(descriptor, buffer, 0, buffer.length, start);
    return buffer.toString('utf8').split(/\r?\n/);
  } finally { fs.closeSync(descriptor); }
}

function matchesIdentity(line, names, steamId) {
  if (steamId && line.includes(steamId)) return true;
  const lower = line.toLowerCase();
  return [...names].some(name => name && lower.includes(name.toLowerCase()));
}

function readLogEvidence() {
  const allowed = /(_cmd|_user|_admin|_connections|_item|_pvp|_map|_DebugLog-server)\.txt$/i;
  const files = walk(logsRoot).filter(file => allowed.test(path.basename(file)) && fs.statSync(file).mtimeMs >= cutoff - 3600000);
  if (fs.existsSync(consoleLogPath) && fs.statSync(consoleLogPath).mtimeMs >= cutoff - 3600000) files.push(consoleLogPath);
  const names = new Set(requestedUsername ? [requestedUsername] : []);
  const steamIds = new Set(requestedSteamId ? [requestedSteamId] : []);
  const ips = new Set();
  const roles = new Set();
  const banned = new Set();

  for (const file of files) {
    if (!/(connections|admin)\.txt$/i.test(path.basename(file))) continue;
    const lines = readLogLines(file);
    for (const line of lines) {
      const parsed = lineTime(line);
      if (parsed.date && parsed.date.getTime() < cutoff) continue;
      const connection = /steam-id="(\d{17})"[^\n]*role="([^"]+)" username="([^"]+)"/i.exec(line);
      if (connection && (steamIds.has(connection[1]) || [...names].some(name => name.toLowerCase() === connection[3].toLowerCase()))) {
        steamIds.add(connection[1]); names.add(connection[3]); roles.add(connection[2]);
        const ip = /ip="([^"]+)"/i.exec(line); if (ip) ips.add(maskIp(ip[1]));
      }
      const ban = /banned SteamID (7656119\d{10})\(([^,)]*)/i.exec(line);
      if (ban && (steamIds.has(ban[1]) || [...names].some(name => name.toLowerCase() === ban[2].toLowerCase()))) {
        steamIds.add(ban[1]); names.add(ban[2]); banned.add(ban[1]);
      }
    }
  }

  const categoryCounts = { connections: 0, admin: 0, item: 0, pvp: 0, map: 0, command: 0, debug: 0, agent: 0, user: 0 };
  const commandCounts = new Map();
  const nativeAntiCheat = [];
  const speedNoiseSamples = [];
  const nativeAntiCheatCounts = { total: 0, speedNoise: 0, speedReview: 0, other: 0 };
  const protectedOrBlocked = [];
  const authorizedAdminActions = [];
  const protectedEvidenceKeys = new Set();
  const adminHits = [];
  const itemHits = [];
  const pvpHits = [];
  const mapHits = [];
  const lifestyle = [];
  const connectionHits = [];
  const relevantDebug = [];
  let firstSeen = '';
  let lastSeen = '';

  const isPrivilegedIdentity = () => [...roles].some(isPrivilegedRole);

  function keep(target, row, maximum = 80) { if (target.length < maximum) target.push(row); }
  function keepProtected(row) {
    const sequence = /\bf:(\d+)\s+st:([0-9,]+)>/.exec(row.text);
    const steamId = /\bsteamId=([^\s]+)/.exec(row.text)?.[1] || '';
    const moduleName = /\bmodule=([^\s]+)/.exec(row.text)?.[1] || '';
    const commandName = /\bcommand=([^\s]+)/.exec(row.text)?.[1] || '';
    const reason = /\breason=([^\s]+)/.exec(row.text)?.[1] || '';
    const key = sequence
      ? ['orange-guard', sequence[1], sequence[2], steamId, moduleName, commandName, reason].join('|')
      : row.text;
    if (protectedEvidenceKeys.has(key)) return;
    protectedEvidenceKeys.add(key);
    keep(protectedOrBlocked, row);
  }
  for (const file of files) {
    const name = path.basename(file);
    const lines = readLogLines(file);
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index];
      const parsed = lineTime(line);
      if (parsed.date && parsed.date.getTime() < cutoff) continue;
      if (!matchesIdentity(line, names, [...steamIds][0] || requestedSteamId)) continue;
      if (parsed.iso) {
        if (!firstSeen || parsed.iso < firstSeen) firstSeen = parsed.iso;
        if (!lastSeen || parsed.iso > lastSeen) lastSeen = parsed.iso;
      }
      const row = { time: parsed.iso, source: source(file, index + 1), text: compactLine(line) };
      if (/_connections\.txt$/i.test(name)) { categoryCounts.connections += 1; keep(connectionHits, row, 30); }
      else if (/_admin\.txt$/i.test(name)) { categoryCounts.admin += 1; keep(adminHits, row); }
      else if (/_item\.txt$/i.test(name)) { categoryCounts.item += 1; keep(itemHits, row); }
      else if (/_pvp\.txt$/i.test(name)) { categoryCounts.pvp += 1; keep(pvpHits, row); }
      else if (/_map\.txt$/i.test(name)) { categoryCounts.map += 1; keep(mapHits, row); }
      else if (/_cmd\.txt$/i.test(name)) {
        categoryCounts.command += 1;
        const command = /"[^"]+"\s+([A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+)\s+@/.exec(line);
        if (command) commandCounts.set(command[1], (commandCounts.get(command[1]) || 0) + 1);
        if (/OrangeAntiCheat|blocked_client_command/i.test(line)) keepProtected(row);
        else if (/addFireOnSquare|addSmokeOnSquare|addExplosionOnSquare|addFluidDebug|clearContainerExplore|addWaterContainer|removeFluidContainer|onHealthCheat|setWeight|disableForSquare|event\.thunder/i.test(line)) {
          if (isPrivilegedIdentity()) keep(authorizedAdminActions, { ...row, classification: 'authorized-admin-action', riskPoints: 0 });
          else keepProtected(row);
        }
        if (/LS\.(AddItemToPlayer|RemoveItemFromPlayer)/i.test(line)) keep(lifestyle, { ...row, command: command ? command[1] : '' }, 160);
      } else if (/_DebugLog-server\.txt$/i.test(name)) {
        categoryCounts.debug += 1;
        if (/Anti-cheat=|Lua\/script checksums|OrangeAntiCheat|dupe|duplicate|exploit/i.test(line)) {
          if (/Anti-cheat=|Lua\/script checksums/i.test(line)) {
            const native = /Anti-cheat="([^"]+)"[^\n]*reason="([^"]*)"/i.exec(line);
            const isSpeed = Boolean(native && native[1] === 'Speed');
            const speedMatch = isSpeed ? /speed=([0-9.]+)/i.exec(native[2]) : null;
            const speed = speedMatch ? Number(speedMatch[1]) : null;
            const cooldown = isSpeed && /\bcooldown\b/i.test(native[2] || '');
            const likelyNetworkNoise = isSpeed && (cooldown || speed === null || speed < 35);
            const evidenceWeight = likelyNetworkNoise ? 'noise' : isSpeed ? 'weak' : 'supporting';
            const enriched = { ...row, signalType: native ? native[1] : 'checksum', speed, cooldown, likelyNetworkNoise, evidenceWeight };
            nativeAntiCheatCounts.total += 1;
            if (likelyNetworkNoise) {
              nativeAntiCheatCounts.speedNoise += 1;
              keep(speedNoiseSamples, enriched, 8);
            } else {
              if (isSpeed) nativeAntiCheatCounts.speedReview += 1;
              else nativeAntiCheatCounts.other += 1;
              keep(nativeAntiCheat, enriched);
            }
          }
          else keep(relevantDebug, row);
        }
      } else if (/^server-console\.txt$/i.test(name)) {
        categoryCounts.agent += 1;
        if (/\[OrangeAntiCheat\][^\r\n]*event=blocked_client_command/i.test(line)) keepProtected(row);
      } else categoryCounts.user += 1;
    }
  }

  const lifestylePairs = [];
  const unmatchedLifestyle = [];
  const byMoment = new Map();
  for (const row of lifestyle) {
    const key = `${row.time}|${String(row.text).match(/@\s+(-?\d+,-?\d+,-?\d+)/)?.[1] || ''}`;
    if (!byMoment.has(key)) byMoment.set(key, []);
    byMoment.get(key).push(row);
  }
  for (const rows of byMoment.values()) {
    const adds = rows.filter(row => /LS\.AddItemToPlayer/i.test(row.text));
    const removes = rows.filter(row => /LS\.RemoveItemFromPlayer/i.test(row.text));
    if (adds.length && removes.length) lifestylePairs.push({ time: rows[0].time, adds: adds.length, removes: removes.length, sources: rows.map(row => row.source) });
    else unmatchedLifestyle.push(...rows);
  }

  return {
    identity: { steamIds: [...steamIds], usernames: [...names], maskedIps: [...ips], roles: [...roles], adminPower: isPrivilegedIdentity(), banned: banned.size > 0, firstSeen, lastSeen },
    logSummary: { filesScanned: files.length, categoryCounts },
    commandSummary: [...commandCounts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 20).map(([command, count]) => ({ command, count })),
    nativeAntiCheat, nativeAntiCheatSummary: nativeAntiCheatCounts,
    speedNoise: { count: nativeAntiCheatCounts.speedNoise, samples: speedNoiseSamples },
    protectedOrBlocked, authorizedAdminActions, adminHits, itemHits, pvpHits, mapHits,
    lifestyle: { total: lifestyle.length, pairedGroups: lifestylePairs.slice(0, 40), unmatched: unmatchedLifestyle.slice(0, 40) },
    connections: connectionHits, relevantDebug,
  };
}

function readPzaiEvidence(identity) {
  const luaRoot = path.join(dataRoot, 'Lua');
  const files = fs.existsSync(luaRoot)
    ? walk(luaRoot).filter(file => /^PZAI-session-\d+-events\.log$/i.test(path.basename(file)) && fs.statSync(file).mtimeMs >= cutoff - 3600000)
    : [];
  const steamIds = new Set([requestedSteamId, ...(identity.steamIds || [])].filter(Boolean));
  const names = new Set([requestedUsername, ...(identity.usernames || [])].filter(Boolean).map(value => value.toLowerCase()));
  const serverSnapshots = [];
  const clientDeclarations = [];
  for (const file of files) {
    const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
    for (let index = 0; index < lines.length; index += 1) {
      let event;
      try { event = JSON.parse(lines[index]); } catch { continue; }
      const actorSteamId = String(event?.actor?.steamId || event?.data?.player?.steamId || '');
      const actorName = String(event?.actor?.username || event?.data?.player?.username || '').toLowerCase();
      if (!steamIds.has(actorSteamId) && !names.has(actorName)) continue;
      const timestampMs = Number(event.timestampMs || 0);
      if (timestampMs > 0 && timestampMs < cutoff) continue;
      const base = {
        time: timestampMs > 0 ? new Date(timestampMs).toISOString() : '',
        source: source(file, index + 1),
        requestId: String(event.data?.requestId || ''),
      };
      if (event.type === 'security.snapshot') {
        serverSnapshots.push({
          ...base, evidenceClass: 'authoritative', trigger: String(event.data?.trigger || ''),
          command: String(event.data?.command || ''), player: event.data?.player || {},
        });
      } else if (event.type === 'diagnostic.snapshot' && event.data?.source === 'client' && /^[a-f0-9]{32}$/.test(base.requestId)) {
        clientDeclarations.push({
          ...base, evidenceClass: 'client-declared', category: String(event.data?.category || ''),
          providers: event.data?.providers || {},
        });
      }
    }
  }
  return {
    filesScanned: files.length,
    serverSnapshots: serverSnapshots.slice(-40),
    clientDeclarations: clientDeclarations.slice(-40),
    authorityNote: 'serverSnapshots 为服务端可信证据；clientDeclarations 可被客户端影响，只能辅助复核。',
  };
}

class Reader {
  constructor(buffer) { this.buffer = buffer; this.offset = 0; }
  ensure(length) { if (this.offset + length > this.buffer.length) throw new Error(`Unexpected EOF at ${this.offset}`); }
  byte() { this.ensure(1); return this.buffer[this.offset++]; }
  int32() { this.ensure(4); const value = this.buffer.readInt32BE(this.offset); this.offset += 4; return value; }
  uint16() { this.ensure(2); const value = this.buffer.readUInt16BE(this.offset); this.offset += 2; return value; }
  double() { this.ensure(8); const value = this.buffer.readDoubleBE(this.offset); this.offset += 8; return value; }
  utf() { const length = this.uint16(); this.ensure(length); const value = this.buffer.toString('utf8', this.offset, this.offset + length); this.offset += length; return value; }
  value(depth = 0) {
    if (depth > 100) throw new Error('Kahlua table nesting is too deep');
    const type = this.byte();
    if (type === 0) return this.utf();
    if (type === 1) return this.double();
    if (type === 2) return this.table(depth + 1);
    if (type === 3) return this.byte() === 1;
    throw new Error(`Unsupported Kahlua value type ${type}`);
  }
  table(depth = 0) {
    const count = this.int32();
    if (count < 0 || count > 2000000) throw new Error(`Invalid table size ${count}`);
    const result = {};
    for (let index = 0; index < count; index += 1) result[String(this.value(depth))] = this.value(depth);
    return result;
  }
}

function parseModData(filename) {
  const reader = new Reader(fs.readFileSync(filename));
  const worldVersion = reader.int32();
  const tableCount = reader.int32();
  const tables = {};
  for (let index = 0; index < tableCount; index += 1) {
    const blockLength = reader.int32();
    const blockEnd = reader.offset + blockLength;
    const name = reader.utf();
    tables[name] = reader.table();
    reader.offset = blockEnd;
  }
  return { worldVersion, tableCount, tables };
}

function rows(value) {
  if (!value || typeof value !== 'object') return [];
  return Object.entries(value).filter(([key, row]) => /^\d+$/.test(key) && row && typeof row === 'object')
    .sort((a, b) => Number(a[0]) - Number(b[0])).map(([, row]) => row);
}

function round(value) { return Math.round((Number(value) || 0) * 100) / 100; }

function buildEconomy(usernames) {
  if (!fs.existsSync(modDataPath)) return { available: false, reason: 'global_mod_data.bin 不存在。' };
  const parsed = parseModData(modDataPath);
  const candidates = usernames.map(name => `OrangeTradingModPlayer_${name}`);
  const accountKey = candidates.find(key => parsed.tables[key]);
  if (!accountKey) return { available: false, reason: '未找到该用户名对应的 OrangeTradingMod 账户。', snapshotModifiedAt: fs.statSync(modDataPath).mtime.toISOString() };
  const account = parsed.tables[accountKey];
  const events = rows(account.flowEvents).map((event, index) => ({
    index: index + 1, timestamp: Number(event.realTimestamp || 0),
    time: Number(event.realTimestamp || 0) ? new Date(Number(event.realTimestamp) * 1000).toISOString() : '',
    direction: String(event.direction || ''), kind: String(event.kind || ''), item: String(event.item || ''),
    amount: Number(event.amount || 0), coins: round(event.coins),
    balanceAfter: event.balanceAfter == null ? null : round(event.balanceAfter),
    peer: event.peer == null ? '' : String(event.peer), label: event.label == null ? '' : String(event.label),
  }));
  const walletKinds = new Set(['safehouse_water_refill']);
  const byKind = {};
  for (const event of events) {
    const bucket = byKind[event.kind] || { count: 0, income: 0, expense: 0, walletFundedExpense: 0, quantity: 0 };
    bucket.count += 1; bucket.quantity += event.amount;
    if (event.direction === 'in') bucket.income = round(bucket.income + event.coins);
    else if (walletKinds.has(event.kind)) bucket.walletFundedExpense = round(bucket.walletFundedExpense + event.coins);
    else bucket.expense = round(bucket.expense + event.coins);
    byKind[event.kind] = bucket;
  }
  const discontinuities = [];
  for (let index = 0; index + 1 < events.length; index += 1) {
    const newer = events[index]; const older = events[index + 1];
    if (newer.balanceAfter == null || older.balanceAfter == null || walletKinds.has(newer.kind)) continue;
    const expected = newer.direction === 'in' ? newer.coins : -newer.coins;
    const actual = round(newer.balanceAfter - older.balanceAfter);
    if (Math.abs(actual - expected) > 0.011) discontinuities.push({ newerIndex: newer.index, expectedDelta: round(expected), actualDelta: actual, event: newer });
  }
  const transfers = events.filter(event => /transfer/i.test(event.kind) || event.peer).slice(0, 80).map(event => {
    const peerKey = event.peer ? `OrangeTradingModPlayer_${event.peer}` : '';
    const peerAccount = peerKey ? parsed.tables[peerKey] : null;
    const opposite = peerAccount ? rows(peerAccount.flowEvents).find(other => Number(other.realTimestamp || 0) === event.timestamp
      && round(other.coins) === event.coins && String(other.direction || '') !== event.direction) : null;
    return { ...event, peerVerified: Boolean(opposite) };
  });
  const leaderboard = Object.entries(parsed.tables).filter(([key, value]) => key.startsWith('OrangeTradingModPlayer_') && value && typeof value === 'object')
    .map(([key, value]) => {
      const recycle = rows(value.flowEvents).filter(event => String(event.kind || '') === 'recycle');
      const payouts = recycle.map(event => round(event.coins));
      return { player: key.slice('OrangeTradingModPlayer_'.length), count: recycle.length, total: round(payouts.reduce((sum, value) => sum + value, 0)), maximum: payouts.length ? Math.max(...payouts) : 0 };
    }).filter(row => row.count).sort((a, b) => b.maximum - a.maximum || b.total - a.total);
  const currentName = accountKey.slice('OrangeTradingModPlayer_'.length);
  const recycleRank = leaderboard.findIndex(row => row.player.toLowerCase() === currentName.toLowerCase()) + 1;
  const bountyData = parsed.tables.OrangeTradingModBountyOrders || {};
  const orderMap = new Map(rows(bountyData.orders).map(order => [String(order.id), order]));
  const bountyActivity = rows(bountyData.submissions).filter(submission => String(submission.submitterKey || '') === accountKey
    || String((orderMap.get(String(submission.orderId)) || {}).ownerKey || '') === accountKey).slice(-60).map(submission => {
    const order = orderMap.get(String(submission.orderId)) || {};
    return { orderId: Number(submission.orderId || 0), owner: String(order.ownerName || ''), submitter: String(submission.submitterName || ''),
      amount: Number(submission.amount || 0), payout: round(submission.payout), tax: round(submission.tax), status: String(submission.status || ''),
      snapshotItems: rows(submission.snapshots).slice(0, 20).map(snapshot => String(snapshot.item || '')) };
  });
  const highEvents = [...events].sort((a, b) => b.coins - a.coins).slice(0, 30);
  return {
    available: true, snapshotModifiedAt: fs.statSync(modDataPath).mtime.toISOString(), account: currentName,
    currentBalance: round(account.coins), eventCount: events.length, byKind,
    discontinuityCount: discontinuities.length, discontinuities: discontinuities.slice(0, 30),
    walletFundedKinds: [...walletKinds], transfers, recycle: { rankByMaximum: recycleRank || null, population: leaderboard.length, player: leaderboard.find(row => row.player.toLowerCase() === currentName.toLowerCase()) || null },
    bountyActivity, highEvents,
  };
}

function main() {
  const logs = readLogEvidence();
  const pzai = readPzaiEvidence(logs.identity);
  const economy = buildEconomy(logs.identity.usernames.length ? logs.identity.usernames : [requestedUsername]);
  process.stdout.write(JSON.stringify({
    schemaVersion: 1, generatedAt: new Date().toISOString(), serverName, windowHours: hours,
    requestedIdentity: { steamId: requestedSteamId, username: requestedUsername }, logs, pzai, economy,
    limitations: [
      '没有日志命中不能证明绝对无作弊。',
      '原版反作弊信号只作为线索，不能单独定性；所有 Speed 信号均为弱证据。',
      'Speed 的 cooldown、无速度数值或低于 35 的记录属于网络/协议噪声，证据权重为零。',
      'Mod 请求次数不等于成功次数。',
      '本证据包不解析角色背包历史或已被轮换删除的日志。',
      'AI 只能给出调查建议，不能自动执行封禁或踢出。',
      'PZAI 客户端声明可能被客户端伪造、屏蔽或修改，不能单独作为处罚依据。',
      '具有服务端连接权限证据的管理员操作只保留审计，不计入作弊风险；不得仅凭用户名判断管理员身份。',
    ],
  }));
}

try { main(); } catch (error) { process.stderr.write(String(error && error.stack || error)); process.exit(1); }
