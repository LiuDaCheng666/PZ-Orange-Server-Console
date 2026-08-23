'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const dataRoot = path.resolve(process.argv[2] || '');
const runtimeRoot = path.resolve(process.argv[3] || '');
const hours = Math.min(720, Math.max(1, Number(process.argv[4] || 168)));
const reviewStatePath = process.argv[5] ? path.resolve(process.argv[5]) : '';
const serverId = String(process.argv[6] || '');
const cutoff = Date.now() - hours * 3600000;
const logsRoot = path.join(dataRoot, 'Logs');
const consoleLogPath = path.join(dataRoot, 'server-console.txt');

const protectedCommands = new Map([
  ['object.addFireOnSquare', 'debug-fire'],
  ['object.addSmokeOnSquare', 'debug-smoke'],
  ['object.addExplosionOnSquare', 'debug-explosion'],
  ['object.addFluidDebug', 'debug-fluid'],
  ['object.clearContainerExplore', 'container-refill'],
  ['object.addWaterContainer', 'debug-fluid-component'],
  ['object.removeFluidContainer', 'debug-fluid-component'],
  ['player.onHealthCheatCurrentPlayer', 'health-cheat'],
  ['player.setWeight', 'weight-cheat'],
  ['erosion.disableForSquare', 'erosion-cheat'],
  ['event.thunder', 'debug-thunder'],
]);
const selfOnlyCommands = ['player.onVehicleSleep', 'player.onDropHeavyItem'];

const identities = new Map();
const roleHistoryByUsername = new Map();
const roleHistoryBySteamId = new Map();
const bannedSteamIds = new Set();
const playerMap = new Map();
const events = [];
const eventKeys = new Set();
const globalSignals = [];
const pendingAdminHealthActions = [];
const reviewedThrough = new Map();
let reviewedNoiseEvents = 0;
let filesScanned = 0;
let bytesScanned = 0;
let linesScanned = 0;

function loadReviewState() {
  if (!reviewStatePath || !serverId || !fs.existsSync(reviewStatePath)) return;
  let state;
  try { state = JSON.parse(fs.readFileSync(reviewStatePath, 'utf8')); } catch { return; }
  for (const record of Array.isArray(state?.records) ? state.records : []) {
    if (String(record.serverId || '') !== serverId || !/^[a-f0-9]{64}$/i.test(String(record.reviewKey || ''))) continue;
    const time = Date.parse(String(record.dismissedThrough || ''));
    if (!Number.isFinite(time)) continue;
    const key = String(record.reviewKey).toLowerCase();
    reviewedThrough.set(key, Math.max(reviewedThrough.get(key) || 0, time));
  }
}

function eventReviewKey(event) {
  const subject = /^7656119\d{10}$/.test(String(event.steamId || ''))
    ? String(event.steamId) : `user:${String(event.username || 'unknown').toLowerCase()}`;
  const signature = [
    subject, event.type || '', event.code || '', event.command || '', event.reason || '',
    event.sourceType || '', event.targetType || '', event.packet || '',
  ].map(value => String(value).trim().toLowerCase()).join('|');
  return crypto.createHash('sha256').update(signature, 'utf8').digest('hex');
}

loadReviewState();

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

function isoTime(text) {
  const date = parsePzTime(text);
  return date && !Number.isNaN(date.getTime()) ? date.toISOString() : '';
}

function lineTime(line) {
  const match = /^\[([^\]]+)\]/.exec(line);
  return match ? { raw: match[1], date: parsePzTime(match[1]) } : { raw: '', date: null };
}

function inWindow(line) {
  const parsed = lineTime(line);
  return !parsed.date || parsed.date.getTime() >= cutoff;
}

function identityFor(username) {
  return identities.get(String(username || '').toLowerCase()) || {};
}

function isPrivilegedRole(role) {
  return ['admin', 'moderator', 'overseer', 'gm'].includes(String(role || '').toLowerCase());
}

function rememberRole(history, key, entry) {
  if (!key || !entry.role) return;
  const normalized = String(key).toLowerCase();
  if (!history.has(normalized)) history.set(normalized, []);
  const rows = history.get(normalized);
  const previous = rows[rows.length - 1];
  if (!previous || previous.timeMs !== entry.timeMs || previous.role !== entry.role || previous.adminPower !== entry.adminPower) {
    rows.push(entry);
  }
}

function rememberIdentity(username, steamId, ip, role = '', timeMs = 0, adminPower = null) {
  if (!username) return;
  const key = String(username).toLowerCase();
  const current = identities.get(key) || {};
  if (/^7656119\d{10}$/.test(String(steamId || ''))) current.steamId = String(steamId);
  if (ip) current.ip = String(ip);
  if (role) {
    current.role = String(role).toLowerCase();
    current.adminPower = adminPower === null ? isPrivilegedRole(role) : Boolean(adminPower);
    const entry = { timeMs: Number(timeMs || 0), role: current.role, adminPower: current.adminPower };
    rememberRole(roleHistoryByUsername, key, entry);
    if (/^7656119\d{10}$/.test(String(steamId || ''))) rememberRole(roleHistoryBySteamId, String(steamId), entry);
  }
  current.username = String(username);
  identities.set(key, current);
}

function roleAt(username, steamId, timeMs = 0) {
  const histories = [];
  if (/^7656119\d{10}$/.test(String(steamId || ''))) histories.push(roleHistoryBySteamId.get(String(steamId)) || []);
  if (username) histories.push(roleHistoryByUsername.get(String(username).toLowerCase()) || []);
  let resolved = null;
  let hasHistory = false;
  for (const rows of histories) {
    if (rows.length) hasHistory = true;
    for (const row of rows) {
      if (timeMs > 0 && row.timeMs > 0 && row.timeMs > timeMs) continue;
      if (!resolved || row.timeMs >= resolved.timeMs) resolved = row;
    }
  }
  if (resolved) return resolved;
  if (timeMs > 0 && hasHistory) return null;
  const current = identityFor(username);
  return current.role ? { timeMs: 0, role: current.role, adminPower: Boolean(current.adminPower) } : null;
}

function ensurePlayer(steamId, username) {
  const resolved = /^7656119\d{10}$/.test(String(steamId || '')) ? String(steamId) : '';
  const key = resolved || `user:${String(username || 'unknown').toLowerCase()}`;
  if (!playerMap.has(key)) {
    playerMap.set(key, {
      steamId: resolved,
      usernames: new Set(), ips: new Set(), score: 0,
      protectedCalls: 0, blockedCalls: 0, blockedCommandCalls: 0,
      blockedItemTransforms: 0, blockedHealthOverwrites: 0, observedHealthSyncs: 0,
      nativeSignals: 0, checksumSignals: 0,
      speedSignals: 0, speedNoiseSignals: 0, speedReviewSignals: 0,
      actionableNativeSignals: 0, otherNativeSignals: 0, nativeWeight: 0,
      serverSnapshots: 0, clientSnapshots: 0, authorizedAdminActions: 0, adminCommandCalls: 0,
      roles: new Set(), adminPower: false,
      permissionSignals: 0, firstSeen: '', lastSeen: '', commandCounts: new Map(),
      minuteCounts: new Map(), peakCommandsPerMinute: 0, reasons: [],
    });
  }
  const player = playerMap.get(key);
  if (username) player.usernames.add(String(username));
  const known = identityFor(username);
  if (!player.steamId && known.steamId) player.steamId = known.steamId;
  if (known.ip) player.ips.add(known.ip);
  if (known.role) player.roles.add(known.role);
  if (known.adminPower) player.adminPower = true;
  return player;
}

function updateSeen(player, time) {
  if (!time) return;
  if (!player.firstSeen || time < player.firstSeen) player.firstSeen = time;
  if (!player.lastSeen || time > player.lastSeen) player.lastSeen = time;
}

function addEvent(event) {
  event.reviewKey = eventReviewKey(event);
  const eventTime = Date.parse(String(event.time || ''));
  const dismissedThrough = reviewedThrough.get(event.reviewKey);
  if (dismissedThrough && Number.isFinite(eventTime) && eventTime <= dismissedThrough) {
    reviewedNoiseEvents += 1;
    return false;
  }
  const key = event.dedupe || [event.time, event.type, event.steamId, event.username, event.command, event.detail].join('|');
  if (eventKeys.has(key)) return false;
  eventKeys.add(key);
  delete event.dedupe;
  events.push(event);
  return true;
}

function parseKeyValues(text) {
  const result = {};
  for (const match of text.matchAll(/([A-Za-z][A-Za-z0-9]*)=([^\s]+)/g)) result[match[1]] = match[2];
  return result;
}

function forEachLine(file, callback) {
  const text = path.basename(file).toLowerCase() === 'server-console.txt'
    ? readTail(file, 16 * 1024 * 1024)
    : fs.readFileSync(file, 'utf8');
  const lines = text.split(/\r?\n/);
  linesScanned += lines.length;
  for (let index = 0; index < lines.length; index += 1) callback(lines[index], index + 1);
}

function eventSource(file, lineNumber) {
  return { sourceFile: path.relative(dataRoot, file).replace(/\\/g, '/'), lineNumber };
}

async function scanIdentities(files) {
  for (const file of files) {
    const name = path.basename(file);
    if (!/(connections|admin)\.txt$/i.test(name)) continue;
    forEachLine(file, (line) => {
      // Keep pre-window role state: an administrator may have logged in before
      // the report window and issued an audited command after it began.
      const insideWindow = inWindow(line);
      const connection = /steam-id="(\d{17})"[^\n]*role="([^"]+)" username="([^"]+)"/.exec(line);
      if (connection) {
        const ip = /ip="([^"]+)"/.exec(line);
        const parsed = lineTime(line);
        rememberIdentity(connection[3], connection[1], ip ? ip[1] : '', connection[2], parsed.date?.getTime() || 0);
        if (insideWindow) {
          const player = ensurePlayer(connection[1], connection[3]);
          updateSeen(player, isoTime(lineTime(line).raw));
        }
      }
      if (!insideWindow) return;
      const ban = /banned SteamID (7656119\d{10})\(([^,)]*)/.exec(line);
      if (ban) {
        bannedSteamIds.add(ban[1]);
        rememberIdentity(ban[2], ban[1], '');
        ensurePlayer(ban[1], ban[2]);
      }
    });
  }
}

function parseCommandLine(file, line, lineNumber) {
  const match = /^\[([^\]]+)\]\s+(7656119\d{10})\s+"([^"]+)"\s+([A-Za-z0-9_-]+)\.([A-Za-z0-9_.-]+)\s+@\s+(-?\d+),(-?\d+),(-?\d+)\./.exec(line);
  if (!match) return;
  const [, rawTime, steamId, username, moduleName, commandName, x, y, z] = match;
  const time = isoTime(rawTime);
  const fullCommand = `${moduleName}.${commandName}`;
  rememberIdentity(username, steamId, '');
  const player = ensurePlayer(steamId, username);
  updateSeen(player, time);
  player.commandCounts.set(fullCommand, (player.commandCounts.get(fullCommand) || 0) + 1);
  const minute = time ? time.slice(0, 16) : rawTime.slice(0, 14);
  const minuteCount = (player.minuteCounts.get(minute) || 0) + 1;
  player.minuteCounts.set(minute, minuteCount);
  player.peakCommandsPerMinute = Math.max(player.peakCommandsPerMinute, minuteCount);

  const timeMs = parsePzTime(rawTime)?.getTime() || 0;
  const commandRole = roleAt(username, steamId, timeMs);
  if (commandRole?.role) player.roles.add(commandRole.role);
  if (commandRole?.adminPower) player.adminPower = true;
  if (fullCommand === 'player.onHealthCheat') {
    if (commandRole?.adminPower) {
      pendingAdminHealthActions.push({ file, timeMs, steamId, username, x: Number(x), y: Number(y), z: Number(z) });
      while (pendingAdminHealthActions.length > 128) pendingAdminHealthActions.shift();
    }
    return;
  }
  if (fullCommand === 'player.onHealthCheatCurrentPlayer') {
    const matchIndex = pendingAdminHealthActions.findLastIndex(item => item.file === file && timeMs >= item.timeMs && timeMs - item.timeMs <= 3000 &&
      Math.abs(Number(x) - item.x) <= 3 && Math.abs(Number(y) - item.y) <= 3 && Number(z) === item.z);
    if (matchIndex >= 0) {
      const authorized = pendingAdminHealthActions.splice(matchIndex, 1)[0];
      player.authorizedAdminActions += 1;
      addEvent({
        time, displayTime: rawTime, severity: 'info', type: 'authorized-admin-action', code: 'health-relay',
        steamId, username, command: fullCommand, coordinate: `${x},${y},${z}`,
        detail: `管理员 ${authorized.username} 已通过原版权限检查发起健康操作；目标客户端正常回传。`,
        authorizedBy: authorized.username, authorizedSteamId: authorized.steamId,
        ...eventSource(file, lineNumber),
      });
      return;
    }
  }

  const code = protectedCommands.get(fullCommand);
  if (!code) return;
  if (commandRole?.adminPower) {
    player.authorizedAdminActions += 1;
    player.adminCommandCalls += 1;
    addEvent({
      time, displayTime: rawTime, severity: 'info', type: 'authorized-admin-action', code: 'admin-command',
      steamId, username, command: fullCommand, coordinate: `${x},${y},${z}`,
      detail: `服务端连接日志确认该会话具有 ${commandRole.role} 权限；操作保留审计但不计作弊风险。`,
      accessRole: commandRole.role, ...eventSource(file, lineNumber),
    });
    return;
  }
  const added = addEvent({
    time, displayTime: rawTime, severity: 'critical', type: 'protected-command', code,
    steamId, username, command: fullCommand, coordinate: `${x},${y},${z}`,
    detail: '客户端调用了仅应由管理员或调试权限使用的原版命令。',
    ...eventSource(file, lineNumber),
  });
  if (added) player.protectedCalls += 1;
}

function parseStructuredGuard(file, line, lineNumber) {
  if (!line.includes('[OrangeAntiCheat]')) return false;
  const blockedCommand = line.includes('event=blocked_client_command');
  const blockedItemTransform = line.includes('event=blocked_item_transform');
  const blockedHealthOverwrite = line.includes('event=blocked_health_overwrite');
  const observedHealthSync = line.includes('event=observed_health_sync');
  if (!blockedCommand && !blockedItemTransform && !blockedHealthOverwrite && !observedHealthSync) return false;
  const values = parseKeyValues(line);
  const parsed = lineTime(line);
  const username = String(values.username || 'unknown').replace(/_/g, ' ');
  const steamId = /^7656119\d{10}$/.test(values.steamId || '') ? values.steamId : (identityFor(username).steamId || '');
  const player = ensurePlayer(steamId, username);
  const time = isoTime(parsed.raw);
  updateSeen(player, time);
  const sequence = /\bf:(\d+)\s+st:([0-9,]+)>/.exec(line);
  const guardDedupe = sequence
    ? ['orange-guard', sequence[1], sequence[2], player.steamId, values.module, values.command,
      values.sourceType, values.targetType, values.itemId, values.packet, values.restoredParts,
      values.increasedParts, values.action,
      values.reason, values.targetId].join('|')
    : '';
  if (observedHealthSync) {
    const reason = values.reason || '';
    const added = addEvent({
      time, displayTime: parsed.raw, severity: 'warning', type: 'observed-health-sync', code: 'health-sync-observed',
      steamId: player.steamId, username, command: values.packet || 'PlayerHealthSync',
      coordinate: [values.x, values.y, values.z].join(','),
      packet: values.packet || '', increasedParts: Number(values.increasedParts || 0),
      maxIncrease: values.maxIncrease || '', reason, action: values.action || 'observed_not_blocked',
      detail: reason === 'target_not_owned_by_connection'
        ? '观察到连接提交了不属于自身玩家的健康同步；Agent 仅记录，未拦截。'
        : reason === 'non_finite_health'
          ? '观察到客户端健康同步包含 NaN 或 Infinity；Agent 仅记录，未拦截。'
          : `观察到客户端同步的身体部位生命增加：数据包 ${values.packet || 'unknown'}，身体部位 ${values.increasedParts || 'unknown'} 个，最大增加 ${values.maxIncrease || 'unknown'}。自然恢复或治疗也可能产生记录，Agent 未拦截。`,
      dedupe: guardDedupe,
      ...eventSource(file, lineNumber),
    });
    if (added) player.observedHealthSyncs += 1;
    return true;
  }
  if (blockedHealthOverwrite) {
    const added = addEvent({
      time, displayTime: parsed.raw, severity: 'critical', type: 'blocked-health-overwrite', code: 'health-overwrite-blocked',
      steamId: player.steamId, username, command: values.packet || 'PlayerHealthSync',
      coordinate: [values.x, values.y, values.z].join(','),
      packet: values.packet || '', restoredParts: Number(values.restoredParts || 0),
      maxIncrease: values.maxIncrease || '', reason: values.reason || '',
      detail: values.reason === 'target_not_owned_by_connection'
        ? '服务端已拒绝该连接修改不属于自己的玩家健康数据。'
        : `服务端已回滚客户端擅自增加的生命值：数据包 ${values.packet || 'unknown'}，身体部位 ${values.restoredParts || 'unknown'} 个，最大增加 ${values.maxIncrease || 'unknown'}。`,
      dedupe: guardDedupe,
      ...eventSource(file, lineNumber),
    });
    if (added) {
      player.blockedCalls += 1;
      player.blockedHealthOverwrites += 1;
    }
    return true;
  }
  if (blockedItemTransform) {
    const sourceType = values.sourceType || 'unknown';
    const targetType = values.targetType || 'unknown';
    const added = addEvent({
      time, displayTime: parsed.raw, severity: 'critical', type: 'blocked-item-transform', code: 'item-transform-blocked',
      steamId: player.steamId, username, command: `${sourceType} -> ${targetType}`,
      coordinate: [values.x, values.y, values.z].join(','),
      sourceType, targetType, itemId: values.itemId || '',
      detail: `服务端已拒绝非法物品替换：载体 ${sourceType}，请求目标 ${targetType}，物品 ID ${values.itemId || 'unknown'}。`,
      dedupe: guardDedupe,
      ...eventSource(file, lineNumber),
    });
    if (added) {
      player.blockedCalls += 1;
      player.blockedItemTransforms += 1;
    }
    return true;
  }
  const added = addEvent({
    time, displayTime: parsed.raw, severity: 'critical', type: 'blocked-command', code: 'server-blocked',
    steamId: player.steamId, username, command: `${values.module || '?'}.${values.command || '?'}`,
    coordinate: [values.x, values.y, values.z].join(','),
    detail: values.capability === 'OwnPlayerOnly'
      ? `服务端已拒绝冒用其他玩家目标，targetId=${values.targetId || 'unknown'}。`
      : `服务端已拒绝，缺少 ${values.capability || 'required capability'}。`,
    dedupe: guardDedupe,
    ...eventSource(file, lineNumber),
  });
  if (added) {
    player.blockedCalls += 1;
    player.blockedCommandCalls += 1;
  }
  return true;
}

function nativeSignalWeight(type, metadata) {
  if (type === 'Speed') return metadata.noiseLikely ? 0 : 1;
  if (/SafeHouse|PlayerUpdate/i.test(type)) return 1;
  return 4;
}

function nativeSignalMetadata(type, reason) {
  const isSpeed = type === 'Speed';
  const speedMatch = isSpeed ? /speed=([0-9.]+)/i.exec(reason || '') : null;
  const speed = speedMatch ? Number(speedMatch[1]) : null;
  const cooldown = isSpeed && /\bcooldown\b/i.test(reason || '');
  const noiseLikely = isSpeed && (cooldown || speed === null || speed < 35);
  return {
    speed, cooldown, noiseLikely,
    evidenceWeight: noiseLikely ? 'noise' : isSpeed ? 'weak' : 'supporting',
    noiseReason: noiseLikely ? (cooldown ? 'cooldown' : speed === null ? 'missing-speed-value' : 'low-speed') : '',
  };
}

function parseNativeSignals(file, line, lineNumber) {
  const parsed = lineTime(line);
  const time = isoTime(parsed.raw);
  const anti = /Anti-cheat="([^"]+)"[^\n]*connection="([^"]+)"[^\n]*reason="([^"]*)"[^\n]*action="([^"]+)"/.exec(line);
  if (anti) {
    const [, antiType, username, reason, action] = anti;
    const counterMatch = /\bcounter="?([^"\s]+)"?/i.exec(line);
    const counter = counterMatch ? counterMatch[1] : '';
    const known = identityFor(username);
    const player = ensurePlayer(known.steamId || '', username);
    const metadata = nativeSignalMetadata(antiType, reason);
    updateSeen(player, time);
    const added = addEvent({
      time, displayTime: parsed.raw, severity: metadata.noiseLikely ? 'low' : (/Kick|Ban/i.test(action) ? 'high' : 'warning'),
      type: 'native-anticheat', code: antiType, steamId: player.steamId, username,
      command: '', coordinate: '', detail: `${reason}；action=${action}`,
      speed: metadata.speed, cooldown: metadata.cooldown, noiseLikely: metadata.noiseLikely,
      evidenceWeight: metadata.evidenceWeight, noiseReason: metadata.noiseReason,
      dedupe: [parsed.raw, 'native', antiType, username, reason, action, counter].join('|'),
      ...eventSource(file, lineNumber),
    });
    if (added) {
      player.nativeSignals += 1;
      if (antiType === 'Speed') {
        player.speedSignals += 1;
        if (!metadata.noiseLikely) player.speedReviewSignals += 1;
      } else if (!metadata.noiseLikely) player.otherNativeSignals += 1;
      if (metadata.noiseLikely) player.speedNoiseSignals += 1;
      else player.actionableNativeSignals += 1;
      if (antiType !== 'Speed') player.nativeWeight += nativeSignalWeight(antiType, metadata);
    }
    return;
  }

  const checksum = /user (.+?) will be kicked[^\n]*because Lua\/script checksums do not match/i.exec(line);
  if (checksum) {
    const username = checksum[1].trim();
    const known = identityFor(username);
    const player = ensurePlayer(known.steamId || '', username);
    updateSeen(player, time);
    const added = addEvent({
      time, displayTime: parsed.raw, severity: 'warning', type: 'checksum', code: 'lua-checksum',
      steamId: player.steamId, username, command: '', coordinate: '',
      detail: '客户端 Lua/脚本校验值与服务器不一致；可能是文件损坏、更新不同步或修改客户端。',
      dedupe: [parsed.raw, 'checksum', username].join('|'), ...eventSource(file, lineNumber),
    });
    if (added) player.checksumSignals += 1;
    return;
  }

  if (/AntiCheatPermission:\s*invalid mode/i.test(line)) {
    globalSignals.push({
      time, displayTime: parsed.raw, severity: 'warning', type: 'permission', code: 'invalid-mode',
      detail: line.slice(Math.max(0, line.indexOf('AntiCheatPermission')), 500), ...eventSource(file, lineNumber),
    });
  }
}

async function scanEvents(files) {
  for (const file of files) {
    const name = path.basename(file);
    if (!/(_cmd|_user|_DebugLog-server|server-console)\.txt$/i.test(name)) continue;
    filesScanned += 1;
    bytesScanned += fs.statSync(file).size;
    forEachLine(file, (line, lineNumber) => {
      if (!inWindow(line)) return;
      if (/_cmd\.txt$/i.test(name)) parseCommandLine(file, line, lineNumber);
      if (!parseStructuredGuard(file, line, lineNumber)) parseNativeSignals(file, line, lineNumber);
    });
  }
}

function parsePzaiEvent(file, line, lineNumber) {
  let record;
  try { record = JSON.parse(line); } catch { return; }
  if (!record || typeof record !== 'object') return;
  const isServerSnapshot = record.type === 'security.snapshot';
  const requestId = String(record.data?.requestId || '');
  const isManagedClientSnapshot = record.type === 'diagnostic.snapshot' &&
    record.data?.source === 'client' && /^[a-f0-9]{32}$/.test(requestId);
  if (!isServerSnapshot && !isManagedClientSnapshot) return;
  const username = String(record.actor?.username || record.data?.player?.username || 'unknown');
  const actorSteamId = String(record.actor?.steamId || record.data?.player?.steamId || '');
  const steamId = /^7656119\d{10}$/.test(actorSteamId) ? actorSteamId : (identityFor(username).steamId || '');
  const telemetryRole = record.data?.role || record.data?.player?.role;
  if (telemetryRole?.name) {
    rememberIdentity(username, steamId, '', String(telemetryRole.name), Number(record.timestampMs || 0), telemetryRole.adminPower === true);
  }
  const player = ensurePlayer(steamId, username);
  const timeMs = Number(record.timestampMs || 0);
  const time = timeMs > 0 ? new Date(timeMs).toISOString() : '';
  if (timeMs > 0 && timeMs < cutoff) return;
  updateSeen(player, time);
  if (isServerSnapshot) player.serverSnapshots += 1;
  else player.clientSnapshots += 1;
  const coordinates = record.data?.player?.coordinates;
  const coordinate = coordinates && [coordinates.x, coordinates.y, coordinates.z]
    .every(value => value !== undefined && value !== null)
    ? `${coordinates.x},${coordinates.y},${coordinates.z}` : '';
  const category = String(record.data?.category || record.data?.command || 'player-state');
  addEvent({
    time, displayTime: time, severity: 'info',
    type: isServerSnapshot ? 'pzai-server-snapshot' : 'pzai-client-snapshot',
    code: isServerSnapshot ? 'server-authoritative' : 'client-declared',
    steamId: player.steamId, username, command: category, coordinate,
    evidenceClass: isServerSnapshot ? 'authoritative' : 'client-declared',
    requestId,
    detail: isServerSnapshot
      ? `PZAI 已记录服务端可信快照；触发来源=${record.data?.trigger || 'unknown'}。`
      : `PZAI 已收到一次性客户端诊断；类别=${category}，仅作辅助证据。`,
    ...eventSource(file, lineNumber),
  });
}

async function scanPzaiEvents(files) {
  for (const file of files) {
    filesScanned += 1;
    bytesScanned += fs.statSync(file).size;
    forEachLine(file, (line, lineNumber) => parsePzaiEvent(file, line, lineNumber));
  }
}

async function scanPzaiIdentities(files) {
  for (const file of files) {
    forEachLine(file, (line) => {
      let record;
      try { record = JSON.parse(line); } catch { return; }
      if (!record || !['player.joined', 'player.left'].includes(record.type)) return;
      const username = String(record.actor?.username || record.data?.username || '');
      const telemetryRole = record.data?.role || record.data?.player?.role;
      if (!username || !telemetryRole?.name) return;
      const knownSteamId = String(record.actor?.steamId || record.data?.steamId || identityFor(username).steamId || '');
      rememberIdentity(username, knownSteamId, '', String(telemetryRole.name), Number(record.timestampMs || 0), telemetryRole.adminPower === true);
    });
  }
}

function addReason(player, code, label, count, severity, points = 0) {
  player.reasons.push({ code, label, count, severity, points });
}

function finalizePlayers() {
  const players = [];
  for (const player of playerMap.values()) {
    if (player.protectedCalls > 0) {
      const points = 80 + Math.min(20, Math.floor(player.protectedCalls / 5));
      player.score += points;
      addReason(player, 'protected-command', '未授权调试命令', player.protectedCalls, 'critical', points);
    }
    if (player.blockedCalls > 0) {
      const points = Math.max(0, 100 - player.score);
      player.score = Math.max(100, player.score);
      if (player.blockedItemTransforms > 0) {
        addReason(player, 'blocked-item-transform', '非法物品替换已拦截', player.blockedItemTransforms, 'critical', points);
      }
      if (player.blockedHealthOverwrites > 0) {
        addReason(player, 'blocked-health-overwrite', '非法健康回写已拦截', player.blockedHealthOverwrites, 'critical',
          player.blockedItemTransforms > 0 ? 0 : points);
      }
      if (player.blockedCommandCalls > 0) {
        addReason(player, 'server-blocked', '危险命令已拦截', player.blockedCommandCalls, 'critical',
          player.blockedItemTransforms > 0 || player.blockedHealthOverwrites > 0 ? 0 : points);
      }
    }
    if (player.observedHealthSyncs > 0) {
      const points = Math.min(12, 4 + player.observedHealthSyncs * 2);
      player.score += points;
      addReason(player, 'observed-health-sync', '健康同步异常（仅记录）', player.observedHealthSyncs,
        'warning', points);
    }
    if (player.otherNativeSignals > 0) {
      const points = Math.min(30, player.nativeWeight);
      player.score += points;
      addReason(player, 'native-anticheat', '原版反作弊信号', player.otherNativeSignals, 'high', points);
    }
    if (player.speedReviewSignals > 0) {
      const points = Math.min(8, player.speedReviewSignals);
      player.score += points;
      addReason(player, 'speed-review', '速度信号（仅供复核）', player.speedReviewSignals, 'warning', points);
    }
    if (player.speedNoiseSignals > 0) {
      addReason(player, 'speed-network-noise', '速度信号（疑似网络波动）', player.speedNoiseSignals, 'low', 0);
    }
    if (player.checksumSignals > 0) {
      const points = Math.min(15, player.checksumSignals * 2);
      player.score += points;
      addReason(player, 'lua-checksum', 'Lua 校验不一致', player.checksumSignals, 'warning', points);
    }
    if (player.peakCommandsPerMinute >= 1200) {
      player.score += 15;
      addReason(player, 'command-rate', '客户端命令峰值过高', player.peakCommandsPerMinute, 'warning', 15);
    }
    const topCommands = [...player.commandCounts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 8).map(([command, count]) => ({ command, count }));
    const steamId = player.steamId || '';
    players.push({
      steamId, usernames: [...player.usernames], ips: [...player.ips], score: Math.min(100, player.score),
      severity: player.protectedCalls || player.blockedCalls ? 'critical' : player.score >= 40 ? 'high' : player.score >= 15 ? 'warning' : 'low',
      protectedCalls: player.protectedCalls, blockedCalls: player.blockedCalls,
      blockedCommandCalls: player.blockedCommandCalls, blockedItemTransforms: player.blockedItemTransforms,
      blockedHealthOverwrites: player.blockedHealthOverwrites,
      observedHealthSyncs: player.observedHealthSyncs,
      nativeSignals: player.nativeSignals, actionableNativeSignals: player.actionableNativeSignals,
      speedSignals: player.speedSignals, speedNoiseSignals: player.speedNoiseSignals, speedReviewSignals: player.speedReviewSignals,
      speedNoiseOnly: player.nativeSignals > 0 && player.nativeSignals === player.speedNoiseSignals && player.score === 0,
      checksumSignals: player.checksumSignals,
      serverSnapshots: player.serverSnapshots, clientSnapshots: player.clientSnapshots,
      authorizedAdminActions: player.authorizedAdminActions,
      adminCommandCalls: player.adminCommandCalls, roles: [...player.roles], adminPower: player.adminPower,
      peakCommandsPerMinute: player.peakCommandsPerMinute, firstSeen: player.firstSeen, lastSeen: player.lastSeen,
      reasons: player.reasons, topCommands, banned: steamId ? bannedSteamIds.has(steamId) : false,
    });
  }
  return players.sort((a, b) => b.score - a.score || String(b.lastSeen).localeCompare(String(a.lastSeen)));
}

function readTail(file, maxBytes = 4 * 1024 * 1024) {
  if (!fs.existsSync(file)) return '';
  const stat = fs.statSync(file);
  const start = Math.max(0, stat.size - maxBytes);
  const fd = fs.openSync(file, 'r');
  try {
    const buffer = Buffer.alloc(stat.size - start);
    fs.readSync(fd, buffer, 0, buffer.length, start);
    return buffer.toString('utf8');
  } finally { fs.closeSync(fd); }
}

function readAgentRuntimeState(consoleText) {
  const state = { active: false, version: '', disabledReason: '', classSha256: '' };
  for (const line of String(consoleText || '').split(/\r?\n/)) {
    const ready = /\[OrangeAntiCheat\]\s+event=guard_ready\s+version=([^\s]+)[^\r\n]*\bmode=javaagent\b/.exec(line);
    if (ready) {
      state.active = true;
      state.version = ready[1];
      state.disabledReason = '';
      state.classSha256 = '';
      continue;
    }
    const disabled = /\[OrangeAntiCheat\]\s+event=guard_disabled\s+version=([^\s]+)\s+reason=([^\s]+)(?:\s+sha256=([^\s]+))?/.exec(line);
    if (disabled) {
      state.active = false;
      state.version = disabled[1];
      state.disabledReason = disabled[2];
      state.classSha256 = disabled[3] || '';
    }
  }
  return state;
}

async function main() {
  if (!fs.existsSync(logsRoot)) throw new Error(`Logs directory is missing: ${logsRoot}`);
  const allowed = /(_cmd|_user|_admin|_connections|_DebugLog-server)\.txt$/i;
  const files = walk(logsRoot).filter(file => allowed.test(path.basename(file)) && fs.statSync(file).mtimeMs >= cutoff - 3600000);
  if (fs.existsSync(consoleLogPath) && fs.statSync(consoleLogPath).mtimeMs >= cutoff - 3600000) files.push(consoleLogPath);
  const luaRoot = path.join(dataRoot, 'Lua');
  const pzaiFiles = fs.existsSync(luaRoot)
    ? walk(luaRoot).filter(file => /^PZAI-session-\d+-events\.log$/i.test(path.basename(file)) && fs.statSync(file).mtimeMs >= cutoff - 3600000)
    : [];
  await scanIdentities(files);
  await scanPzaiIdentities(pzaiFiles);
  await scanEvents(files);
  await scanPzaiEvents(pzaiFiles);
  const players = finalizePlayers();
  events.push(...globalSignals);
  events.sort((a, b) => String(b.time).localeCompare(String(a.time)));
  const severityRank = { critical: 4, high: 3, warning: 2, low: 1, info: 0 };
  for (const player of players) {
    const names = new Set(player.usernames.map(value => String(value).toLowerCase()));
    player.evidenceEvents = events
      .filter(event => (player.steamId && event.steamId === player.steamId) || names.has(String(event.username || '').toLowerCase()))
      .sort((left, right) => (severityRank[right.severity] || 0) - (severityRank[left.severity] || 0) || String(right.time).localeCompare(String(left.time)))
      .slice(0, 24);
  }

  const agentPath = path.join(runtimeRoot, 'server-patches', 'OrangeAntiCheat-agent.jar');
  const installed = fs.existsSync(agentPath);
  const consoleText = readTail(consoleLogPath, 16 * 1024 * 1024);
  const agentState = readAgentRuntimeState(consoleText);
  const version = agentState.version || (installed ? '2.0.0' : '');
  const criticalPlayers = players.filter(player => player.severity === 'critical' && !player.banned).length;
  const pzaiRoot = path.join(runtimeRoot, 'steamapps', 'workshop', 'content', '108600', '3777330954', 'mods', 'PZAIServerAgent', '42.20');
  const pzaiModInfoPath = path.join(pzaiRoot, 'mod.info');
  const pzaiModInfo = fs.existsSync(pzaiModInfoPath) ? fs.readFileSync(pzaiModInfoPath, 'utf8') : '';
  const pzaiVersionMatch = /^modversion=([^\r\n]+)/m.exec(pzaiModInfo);
  const pzaiVersion = pzaiVersionMatch ? pzaiVersionMatch[1].trim() : '';
  const pzaiIntegrationReady = fs.existsSync(path.join(pzaiRoot, 'media', 'lua', 'server', 'PZAISecurityDiagnostics.lua')) &&
    /^0\.(?:7\.(?:9|[1-9]\d+)|(?:[89]|\d{2,})\.\d+)/.test(pzaiVersion);

  process.stdout.write(JSON.stringify({
    ok: true, generatedAt: new Date().toISOString(), hours,
    patch: {
      installed, active: agentState.active,
      pendingRestart: installed && !agentState.active && !agentState.disabledReason,
      version, disabledReason: agentState.disabledReason, classSha256: agentState.classSha256,
    },
    pzai: { installed: Boolean(pzaiVersion), version: pzaiVersion, integrationReady: pzaiIntegrationReady },
    summary: {
      suspiciousPlayers: players.filter(player => player.score > 0).length, criticalPlayers,
      protectedCalls: players.reduce((sum, player) => sum + player.protectedCalls, 0),
      blockedCalls: players.reduce((sum, player) => sum + player.blockedCalls, 0),
      blockedCommandCalls: players.reduce((sum, player) => sum + player.blockedCommandCalls, 0),
      blockedItemTransforms: players.reduce((sum, player) => sum + player.blockedItemTransforms, 0),
      blockedHealthOverwrites: players.reduce((sum, player) => sum + player.blockedHealthOverwrites, 0),
      observedHealthSyncs: players.reduce((sum, player) => sum + player.observedHealthSyncs, 0),
      reviewedNoiseEvents,
      nativeSignals: players.reduce((sum, player) => sum + player.nativeSignals, 0),
      speedNoiseSignals: players.reduce((sum, player) => sum + player.speedNoiseSignals, 0),
      checksumSignals: players.reduce((sum, player) => sum + player.checksumSignals, 0),
      serverSnapshots: players.reduce((sum, player) => sum + player.serverSnapshots, 0),
      clientSnapshots: players.reduce((sum, player) => sum + player.clientSnapshots, 0),
      bannedPlayers: players.filter(player => player.banned).length,
    },
    players, events: events.slice(0, 1000),
    diagnostics: { filesScanned, bytesScanned, linesScanned },
    rules: [...protectedCommands.keys(), ...selfOnlyCommands],
  }));
}

main().catch(error => {
  process.stderr.write(String(error && error.stack || error));
  process.exit(1);
});
