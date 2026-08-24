'use strict';

const childProcess = require('child_process');
const path = require('path');

const root = __dirname;
const fixture = path.join(root, 'tests', 'fixtures', 'anti-identity');
const output = childProcess.execFileSync(process.execPath, [
  path.join(root, 'Read-PZAntiCheatEvents.js'), fixture, root, '168', '', 'fixture',
], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
const report = JSON.parse(output);
const byId = new Map(report.players.map(player => [player.steamId, player]));
const first = byId.get('76561198000000001');
const second = byId.get('76561198000000002');

if (!first || !second) throw new Error('Expected both Steam identities.');
if (report.players.some(player => player.usernames.some(name => /^(null|unknown)$/i.test(name)))) {
  throw new Error('Placeholder username leaked into the player list.');
}
if (!first.usernames.includes('Alice') || !second.usernames.includes('Bob')) {
  throw new Error('A real username was assigned to the wrong Steam identity.');
}
if (first.blockedCalls !== 1 || second.blockedCalls !== 0) {
  throw new Error('Persistent Agent evidence was assigned to the wrong identity.');
}
if (first.evidenceEvents.some(event => event.steamId && event.steamId !== first.steamId)
    || second.evidenceEvents.some(event => event.steamId && event.steamId !== second.steamId)) {
  throw new Error('Evidence crossed Steam identity boundaries.');
}

console.log('anti-cheat identity and persistent evidence tests passed');
