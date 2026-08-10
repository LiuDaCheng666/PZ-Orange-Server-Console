'use strict';

const fs = require('fs');
const path = require('path');

const configPath = process.argv[2];
if (!configPath) throw new Error('Missing item index request path.');

const readText = file => fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '');
const exists = file => {
  try { return fs.statSync(file); } catch { return null; }
};
const writeJsonAtomic = (file, value) => {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(value), 'utf8');
  fs.renameSync(temporary, file);
};
const normalizeId = key => String(key || '').replace(/^ItemName_/, '').trim();
const versionParts = value => String(value).split('.').map(part => Number(part) || 0);
const compareVersions = (left, right) => {
  const a = versionParts(left), b = versionParts(right);
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    const difference = (a[index] || 0) - (b[index] || 0);
    if (difference) return difference;
  }
  return 0;
};

function readIni(file) {
  const values = {};
  if (!exists(file)) return values;
  for (const line of readText(file).split(/\r?\n/)) {
    const match = line.match(/^([^#;=]+)=(.*)$/);
    if (match) values[match[1].trim()] = match[2].trim();
  }
  return values;
}

function walkFiles(root, accept) {
  if (!exists(root)?.isDirectory()) return [];
  const results = [], pending = [root];
  while (pending.length) {
    const current = pending.pop();
    let entries = [];
    try { entries = fs.readdirSync(current, { withFileTypes: true }); } catch { continue; }
    for (const entry of entries) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) pending.push(fullPath);
      else if (entry.isFile() && accept(fullPath, entry.name)) results.push(fullPath);
    }
  }
  return results;
}

function readBraceBlock(text, openIndex) {
  let depth = 0, quote = '', escaped = false;
  for (let index = openIndex; index < text.length; index += 1) {
    const character = text[index];
    if (quote) {
      if (escaped) escaped = false;
      else if (character === '\\') escaped = true;
      else if (character === quote) quote = '';
      continue;
    }
    if (character === '"' || character === "'") { quote = character; continue; }
    if (character === '{') depth += 1;
    else if (character === '}' && --depth === 0) return text.slice(openIndex + 1, index);
  }
  return text.slice(openIndex + 1);
}

function readTranslationFile(file, target) {
  let text;
  try { text = readText(file); } catch { return; }
  if (path.extname(file).toLowerCase() === '.json') {
    try {
      const document = JSON.parse(text);
      for (const [rawKey, rawValue] of Object.entries(document)) {
        const id = normalizeId(rawKey), value = String(rawValue || '').trim();
        if (/^[A-Za-z0-9_.-]+\.[A-Za-z0-9_.-]+$/.test(id) && value) target.set(id, value);
      }
    } catch { }
    return;
  }
  const expression = /^\s*ItemName_([A-Za-z0-9_.-]+)\s*=\s*"((?:\\.|[^"\\])*)"/gm;
  for (const match of text.matchAll(expression)) {
    const id = normalizeId(match[1]);
    const value = match[2].replace(/\\"/g, '"').replace(/\\n/g, ' ').replace(/\\\\/g, '\\').trim();
    if (/^[A-Za-z0-9_.-]+\.[A-Za-z0-9_.-]+$/.test(id) && value) target.set(id, value);
  }
}

function readTranslations(root, language, target) {
  const directory = path.join(root, 'media', 'lua', 'shared', 'Translate', language);
  const files = walkFiles(directory, (file, name) => /^ItemName.*\.(json|txt)$/i.test(name));
  files.sort((left, right) => left.localeCompare(right, 'en'));
  for (const file of files) readTranslationFile(file, target);
}

function readItemDeclarations(root, source, target) {
  const scriptsRoot = path.join(root, 'media', 'scripts');
  const files = walkFiles(scriptsRoot, (file, name) => name.toLowerCase().endsWith('.txt'));
  let count = 0;
  for (const file of files) {
    let text;
    try { text = readText(file); } catch { continue; }
    const modules = [...text.matchAll(/(?:^|\n)\s*module\s+([A-Za-z0-9_.-]+)\s*\{/g)];
    for (let moduleIndex = 0; moduleIndex < modules.length; moduleIndex += 1) {
      const moduleName = modules[moduleIndex][1];
      const start = modules[moduleIndex].index + modules[moduleIndex][0].length;
      const end = moduleIndex + 1 < modules.length ? modules[moduleIndex + 1].index : text.length;
      const segment = text.slice(start, end);
      const itemMatches = [...segment.matchAll(/(?:^|\n)\s*item\s+([A-Za-z0-9_.-]+)\s*\{/g)];
      for (let itemIndex = 0; itemIndex < itemMatches.length; itemIndex += 1) {
        const item = itemMatches[itemIndex];
        const id = `${moduleName}.${item[1]}`;
        const openIndex = item.index + item[0].lastIndexOf('{');
        const body = readBraceBlock(segment, openIndex);
        const property = name => {
          const match = body.match(new RegExp(`^\\s*${name}\\s*=\\s*([^,\\r\\n}]+)`, 'mi'));
          return match ? match[1].trim().replace(/^['"]|['"]$/g, '') : '';
        };
        const declaration = {
          ...source,
          displayCategory: property('DisplayCategory'),
          itemType: property('ItemType') || property('Type'),
        };
        if (!target.has(id) || source.source !== 'vanilla') target.set(id, declaration);
        count += 1;
      }
    }
  }
  return count;
}

function findModDescriptors(workshopRoot, workshopIds) {
  const descriptors = [];
  for (const workshopId of workshopIds) {
    const modsRoot = path.join(workshopRoot, workshopId, 'mods');
    if (!exists(modsRoot)?.isDirectory()) continue;
    let packages = [];
    try { packages = fs.readdirSync(modsRoot, { withFileTypes: true }).filter(entry => entry.isDirectory()); } catch { continue; }
    for (const packageEntry of packages) {
      const packageRoot = path.join(modsRoot, packageEntry.name);
      const candidates = [packageRoot];
      let children = [];
      try { children = fs.readdirSync(packageRoot, { withFileTypes: true }).filter(entry => entry.isDirectory()); } catch { }
      for (const child of children) candidates.push(path.join(packageRoot, child.name));
      for (const contentRoot of candidates) {
        const infoPath = path.join(contentRoot, 'mod.info');
        if (!exists(infoPath)?.isFile()) continue;
        const idLine = readText(infoPath).split(/\r?\n/).find(line => /^id=/.test(line));
        if (!idLine) continue;
        const folderName = path.basename(contentRoot);
        descriptors.push({
          id: idLine.slice(3).trim(),
          workshopId,
          packageRoot,
          contentRoot,
          kind: /^\d+(?:\.\d+)*$/.test(folderName) ? 'version' : folderName.toLowerCase() === 'common' ? 'common' : 'legacy',
          version: /^\d+(?:\.\d+)*$/.test(folderName) ? folderName : null,
        });
      }
    }
  }
  return descriptors;
}

function selectActiveModRoots(descriptors, enabledModIds, gameVersion) {
  const selected = [];
  for (const enabledId of enabledModIds) {
    const matches = descriptors.filter(item => item.id.toLowerCase() === enabledId.toLowerCase());
    const packages = new Map();
    for (const match of matches) {
      if (!packages.has(match.packageRoot)) packages.set(match.packageRoot, []);
      packages.get(match.packageRoot).push(match);
    }
    for (const candidates of packages.values()) {
      const common = candidates.filter(item => item.kind === 'common');
      const compatible = candidates
        .filter(item => item.kind === 'version' && (!gameVersion || compareVersions(item.version, gameVersion) <= 0))
        .sort((left, right) => compareVersions(right.version, left.version));
      const fallbackVersions = candidates.filter(item => item.kind === 'version').sort((left, right) => compareVersions(right.version, left.version));
      const version = compatible[0] || fallbackVersions[fallbackVersions.length - 1];
      const roots = [...common];
      if (version) roots.push(version);
      if (!roots.length) roots.push(...candidates.filter(item => item.kind === 'legacy').slice(0, 1));
      for (const root of roots) selected.push({ ...root, enabledId });
    }
  }
  return selected;
}

function detectGameVersion(consoleLog) {
  const stat = exists(consoleLog);
  if (!stat?.isFile()) return null;
  const length = Math.min(stat.size, 8 * 1024 * 1024);
  const descriptor = fs.openSync(consoleLog, 'r');
  try {
    const buffer = Buffer.alloc(length);
    fs.readSync(descriptor, buffer, 0, length, Math.max(0, stat.size - length));
    const matches = [...buffer.toString('utf8').matchAll(/\bversion=(\d+(?:\.\d+)+)\b/g)];
    return matches.length ? matches[matches.length - 1][1] : null;
  } finally { fs.closeSync(descriptor); }
}

function build(config) {
  const iniPath = path.join(config.dataRoot, 'Server', `${config.serverName}.ini`);
  const ini = readIni(iniPath);
  const enabledModIds = String(ini.Mods || '').split(';').map(value => value.trim()).filter(Boolean);
  const workshopIds = String(ini.WorkshopItems || '').split(';').map(value => value.trim()).filter(value => /^\d+$/.test(value));
  const workshopRoot = path.join(config.runtimeRoot, 'steamapps', 'workshop', 'content', '108600');
  const gameVersion = detectGameVersion(config.consoleLog);
  const namesZh = new Map(), namesEn = new Map(), declarations = new Map();

  updateStatus(config, 'translations', '读取本体中英文名称');
  readTranslations(config.runtimeRoot, 'CN', namesZh);
  readTranslations(config.runtimeRoot, 'EN', namesEn);
  updateStatus(config, 'vanilla', '扫描本体物品');
  const vanillaDeclarations = readItemDeclarations(config.runtimeRoot, { source: 'vanilla', modId: null, workshopId: null }, declarations);
  // Official translation files are also authoritative for generated vanilla items.
  for (const id of new Set([...namesZh.keys(), ...namesEn.keys()])) {
    if (!declarations.has(id)) declarations.set(id, { source: 'vanilla', modId: null, workshopId: null });
  }

  updateStatus(config, 'workshop', '读取 Workshop Mod 描述');
  const descriptors = findModDescriptors(workshopRoot, workshopIds);
  const activeRoots = selectActiveModRoots(descriptors, enabledModIds, gameVersion);
  let modDeclarations = 0;
  for (let index = 0; index < activeRoots.length; index += 1) {
    const mod = activeRoots[index];
    if (index === 0 || index % 10 === 0) {
      updateStatus(config, 'mods', `扫描启用 Mod（${index}/${activeRoots.length}）`, { current: index, total: activeRoots.length });
    }
    readTranslations(mod.contentRoot, 'CN', namesZh);
    readTranslations(mod.contentRoot, 'EN', namesEn);
    modDeclarations += readItemDeclarations(mod.contentRoot, {
      source: 'mod',
      modId: mod.enabledId,
      workshopId: mod.workshopId,
    }, declarations);
  }

  updateStatus(config, 'finalizing', '整理并保存物品缓存');
  const items = [...declarations.entries()].map(([id, source]) => ({
    id,
    nameZh: namesZh.get(id) || '',
    nameEn: namesEn.get(id) || '',
    source: source.source,
    modId: source.modId,
    workshopId: source.workshopId,
    displayCategory: source.displayCategory || '',
    itemType: source.itemType || '',
  })).sort((left, right) => left.id.localeCompare(right.id, 'en'));

  return {
    version: 2,
    serverId: config.serverId,
    generatedAt: new Date().toISOString(),
    gameVersion,
    count: items.length,
    stats: {
      vanillaDeclarations,
      modDeclarations,
      enabledMods: enabledModIds.length,
      matchedMods: new Set(activeRoots.map(item => item.enabledId.toLowerCase())).size,
      workshopItems: workshopIds.length,
      activeContentRoots: activeRoots.length,
      chineseNames: items.filter(item => item.nameZh).length,
    },
    items,
  };
}

function updateStatus(config, phase, phaseLabel, extra = {}) {
  writeJsonAtomic(config.statusPath, {
    state: 'building',
    serverId: config.serverId,
    pid: process.pid,
    startedAt: config.startedAt,
    phase,
    phaseLabel,
    cachedCount: config.previous?.count || 0,
    cachedStats: config.previous?.stats || null,
    cachedAt: config.previous?.completedAt || null,
    ...extra,
  });
}

let config;
try {
  config = JSON.parse(readText(configPath));
  config.startedAt = new Date().toISOString();
  updateStatus(config, 'starting', '准备扫描');
  const document = build(config);
  writeJsonAtomic(config.outputPath, document);
  writeJsonAtomic(config.statusPath, {
    state: 'ready',
    serverId: config.serverId,
    completedAt: new Date().toISOString(),
    count: document.count,
    stats: document.stats,
  });
  process.stdout.write(`Indexed ${document.count} items for ${config.serverId}.\n`);
} catch (error) {
  if (config?.statusPath) {
    writeJsonAtomic(config.statusPath, {
      state: 'error',
      serverId: config.serverId,
      completedAt: new Date().toISOString(),
      cachedCount: config.previous?.count || 0,
      cachedStats: config.previous?.stats || null,
      cachedAt: config.previous?.completedAt || null,
      error: String(error && (error.stack || error.message) || error).slice(0, 2000),
    });
  }
  process.stderr.write(`${error && (error.stack || error.message) || error}\n`);
  process.exitCode = 1;
}
