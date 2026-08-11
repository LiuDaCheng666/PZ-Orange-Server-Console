const fs = require('node:fs');
const { DatabaseSync } = require('node:sqlite');

const [mode, accountDatabasePath, playerDatabasePath, steamId] = process.argv.slice(2);
if (!['inspect', 'delete'].includes(mode)) throw new Error('Mode must be inspect or delete.');
if (!/^7656119\d{10}$/.test(steamId || '')) throw new Error('SteamID64 is invalid.');

function readState() {
  const accounts = [];
  const characters = [];
  let allowed = false;
  let banned = false;

  if (fs.existsSync(accountDatabasePath)) {
    const db = new DatabaseSync(accountDatabasePath, { readOnly: true });
    try {
      accounts.push(...db.prepare(`
        SELECT whitelist.username, whitelist.displayName, whitelist.lastConnection,
               CAST(whitelist.steamid AS TEXT) AS steamId,
               CAST(whitelist.ownerid AS TEXT) AS ownerId,
               whitelist.authType, COALESCE(role.name, 'user') AS role
        FROM whitelist
        LEFT JOIN role ON role.id = whitelist.role
        WHERE CAST(whitelist.steamid AS TEXT) = ? OR CAST(whitelist.ownerid AS TEXT) = ?
        ORDER BY whitelist.username COLLATE NOCASE
      `).all(steamId, steamId));
      allowed = Boolean(db.prepare('SELECT 1 AS found FROM allowedsteamid WHERE CAST(steamid AS TEXT) = ? LIMIT 1').get(steamId));
      banned = Boolean(db.prepare('SELECT 1 AS found FROM bannedid WHERE CAST(steamid AS TEXT) = ? LIMIT 1').get(steamId));
    } finally {
      db.close();
    }
  }

  if (fs.existsSync(playerDatabasePath)) {
    const db = new DatabaseSync(playerDatabasePath, { readOnly: true });
    try {
      characters.push(...db.prepare(`
        SELECT id, world, username, playerIndex, name, CAST(steamid AS TEXT) AS steamId,
               x, y, z, isDead
        FROM networkPlayers
        WHERE CAST(steamid AS TEXT) = ?
        ORDER BY username COLLATE NOCASE, playerIndex, id
      `).all(steamId).map(row => ({ ...row, isDead: Boolean(row.isDead) })));
    } finally {
      db.close();
    }
  }

  return { steamId, accounts, characters, allowed, banned };
}

if (mode === 'inspect') {
  process.stdout.write(JSON.stringify(readState()));
  process.exit(0);
}

if (!fs.existsSync(accountDatabasePath)) throw new Error('Account database does not exist.');
const before = readState();
const db = new DatabaseSync(accountDatabasePath);
let attached = false;
try {
  db.exec('PRAGMA busy_timeout = 5000');
  if (fs.existsSync(playerDatabasePath)) {
    const quotedPlayerPath = playerDatabasePath.replaceAll("'", "''");
    db.exec(`ATTACH DATABASE '${quotedPlayerPath}' AS playerdb`);
    attached = true;
  }
  db.exec('BEGIN IMMEDIATE');
  try {
    const deletedAccounts = Number(db.prepare('DELETE FROM main.whitelist WHERE CAST(steamid AS TEXT) = ? OR CAST(ownerid AS TEXT) = ?').run(steamId, steamId).changes);
    const deletedAllowedEntries = Number(db.prepare('DELETE FROM main.allowedsteamid WHERE CAST(steamid AS TEXT) = ?').run(steamId).changes);
    const deletedCharacters = attached
      ? Number(db.prepare('DELETE FROM playerdb.networkPlayers WHERE CAST(steamid AS TEXT) = ?').run(steamId).changes)
      : 0;
    db.exec('COMMIT');
    const after = readState();
    process.stdout.write(JSON.stringify({
      steamId,
      before,
      after,
      deletedAccounts,
      deletedAllowedEntries,
      deletedCharacters,
      banPreserved: before.banned && after.banned,
    }));
  } catch (error) {
    try { db.exec('ROLLBACK'); } catch {}
    throw error;
  }
} finally {
  if (attached) {
    try { db.exec('DETACH DATABASE playerdb'); } catch {}
  }
  db.close();
}
