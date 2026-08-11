const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { DatabaseSync } = require('node:sqlite');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'pz-player-manager-'));
const accountPath = path.join(root, 'server.db');
const playerPath = path.join(root, 'players.db');
const managerPath = path.join(__dirname, 'Manage-PZPlayerData.js');
const steamId = '76561198000000000';

function invoke(mode) {
  const result = spawnSync(process.execPath, ['--no-warnings', managerPath, mode, accountPath, playerPath, steamId], { encoding: 'utf8' });
  if (result.status !== 0) throw new Error(result.stderr || result.stdout || `${mode} failed`);
  return JSON.parse(result.stdout);
}

try {
  const account = new DatabaseSync(accountPath);
  account.exec(`
    CREATE TABLE role (id INTEGER PRIMARY KEY, name TEXT);
    CREATE TABLE whitelist (id INTEGER PRIMARY KEY, username TEXT, displayName TEXT, password TEXT, lastConnection TEXT, role INTEGER, authType INTEGER, steamid TEXT, ownerid TEXT);
    CREATE TABLE allowedsteamid (steamid TEXT);
    CREATE TABLE bannedid (steamid TEXT, reason TEXT);
    INSERT INTO role VALUES (1, 'user');
    INSERT INTO whitelist VALUES (1, 'ExampleUser', 'Example', 'secret-hash', '2026-01-01', 1, 0, '${steamId}', '');
    INSERT INTO allowedsteamid VALUES ('${steamId}');
    INSERT INTO bannedid VALUES ('${steamId}', 'preserve');
  `);
  account.close();

  const players = new DatabaseSync(playerPath);
  players.exec(`
    CREATE TABLE networkPlayers (id INTEGER PRIMARY KEY, world TEXT, username TEXT, playerIndex INTEGER, name TEXT, steamid INTEGER, x FLOAT, y FLOAT, z FLOAT, data BLOB, isDead BOOLEAN);
    INSERT INTO networkPlayers VALUES (1, 'world', 'ExampleUser', 0, 'Example Character', ${steamId}, 10, 20, 0, X'00', 0);
  `);
  players.close();

  const inspected = invoke('inspect');
  if (inspected.accounts.length !== 1 || inspected.characters.length !== 1 || 'password' in inspected.accounts[0]) throw new Error('Inspection result is invalid or exposes a password.');
  const deleted = invoke('delete');
  if (deleted.deletedAccounts !== 1 || deleted.deletedCharacters !== 1 || deleted.deletedAllowedEntries !== 1) throw new Error('Delete counts are invalid.');
  if (deleted.after.accounts.length || deleted.after.characters.length || deleted.after.allowed || !deleted.after.banned || !deleted.banPreserved) throw new Error('Post-delete state is invalid.');
  process.stdout.write(JSON.stringify({ ok: true, deletedAccounts: 1, deletedCharacters: 1, banPreserved: true }));
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
