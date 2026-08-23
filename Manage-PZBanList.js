'use strict';

const fs = require('node:fs');
const { DatabaseSync } = require('node:sqlite');

const [mode, databasePath, inputPath] = process.argv.slice(2);
if (!['list', 'import'].includes(mode)) throw new Error('Mode must be list or import.');
if (!databasePath || !fs.existsSync(databasePath)) throw new Error('Account database does not exist.');

function normalizeSteamId(value) {
  const steamId = String(value || '').trim();
  if (!/^7656119\d{10}$/.test(steamId)) throw new Error(`Invalid SteamID64: ${steamId}`);
  return steamId;
}

function readList(db) {
  const rows = db.prepare(`
    SELECT CAST(b.steamid AS TEXT) AS steamId, COALESCE(b.reason, '') AS reason,
           GROUP_CONCAT(DISTINCT w.username) AS usernames
    FROM bannedid b
    LEFT JOIN whitelist w ON CAST(w.steamid AS TEXT) = CAST(b.steamid AS TEXT)
                         OR CAST(w.ownerid AS TEXT) = CAST(b.steamid AS TEXT)
    GROUP BY CAST(b.steamid AS TEXT), b.reason
    ORDER BY CAST(b.steamid AS TEXT)
  `).all();
  return rows.map(row => ({
    steamId: normalizeSteamId(row.steamId),
    reason: String(row.reason || '').slice(0, 500),
    usernames: String(row.usernames || '').split(',').map(value => value.trim()).filter(Boolean).slice(0, 20),
  }));
}

if (mode === 'list') {
  const db = new DatabaseSync(databasePath, { readOnly: true });
  try { process.stdout.write(JSON.stringify({ bans: readList(db) })); }
  finally { db.close(); }
  process.exit(0);
}

if (!inputPath || !fs.existsSync(inputPath)) throw new Error('Import JSON does not exist.');
const input = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
const entries = Array.isArray(input) ? input : input.bans;
if (!Array.isArray(entries) || entries.length > 10000) throw new Error('Import list is invalid or too large.');
const normalized = new Map();
for (const entry of entries) {
  const steamId = normalizeSteamId(typeof entry === 'string' ? entry : entry.steamId);
  const reason = String(typeof entry === 'string' ? '' : entry.reason || '').replace(/[\r\n\t]/g, ' ').trim().slice(0, 500);
  normalized.set(steamId, reason);
}

const db = new DatabaseSync(databasePath);
let inserted = 0;
try {
  db.exec('PRAGMA busy_timeout = 5000');
  db.exec('BEGIN IMMEDIATE');
  try {
    const insert = db.prepare('INSERT INTO bannedid (steamid, reason) SELECT ?, ? WHERE NOT EXISTS (SELECT 1 FROM bannedid WHERE CAST(steamid AS TEXT) = ?)');
    for (const [steamId, reason] of normalized) inserted += Number(insert.run(steamId, reason, steamId).changes);
    db.exec('COMMIT');
  } catch (error) {
    try { db.exec('ROLLBACK'); } catch {}
    throw error;
  }
  process.stdout.write(JSON.stringify({ requested: normalized.size, inserted, total: readList(db).length }));
} finally { db.close(); }
