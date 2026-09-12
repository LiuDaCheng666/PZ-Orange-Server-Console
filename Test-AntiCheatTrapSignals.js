'use strict';

const childProcess = require('child_process');
const path = require('path');

const root = __dirname;
const fixture = path.join(root, 'tests', 'fixtures', 'anti-trap');
const output = childProcess.execFileSync(process.execPath, [
  path.join(root, 'Read-PZAntiCheatEvents.js'), fixture, root, '720', '', 'fixture-trap',
], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
const report = JSON.parse(output);
const byId = new Map(report.players.map(player => [player.steamId, player]));
const repeatedHammer = byId.get('76561198000000010');
const legitimateExplosives = byId.get('76561198000000011');
const oldKffc = byId.get('76561198000000012');
const newKffc = byId.get('76561198000000013');

if (!repeatedHammer || !legitimateExplosives || !oldKffc || !newKffc) throw new Error('Expected all trap fixture identities.');
if (repeatedHammer.explosiveTrapAdds !== 4 || repeatedHammer.explosiveTrapBurst !== 4) {
  throw new Error('Repeated hammer trap packets were not aggregated correctly.');
}
if (repeatedHammer.severity !== 'critical' || repeatedHammer.score < 90) {
  throw new Error('Repeated non-explosive trap payload must be a visible critical finding.');
}
if (!repeatedHammer.evidenceEvents.some(event => event.type === 'explosive-trap-add'
    && event.itemType === 'Base.Hammer' && event.severity === 'critical')) {
  throw new Error('Critical trap evidence is missing its item type or severity.');
}
if (legitimateExplosives.explosiveTrapAdds !== 4 || legitimateExplosives.score !== 0
    || legitimateExplosives.severity !== 'low') {
  throw new Error('Repeated legitimate explosive placements must remain zero-risk audit records.');
}
if (!legitimateExplosives.evidenceEvents.filter(event => event.type === 'explosive-trap-add')
    .every(event => event.plausibleExplosive === true && event.severity === 'info')) {
  throw new Error('Legitimate explosive evidence was not classified as informational.');
}
if (oldKffc.explosiveTrapAdds !== 3 || newKffc.explosiveTrapAdds !== 2) {
  throw new Error('Same-name trap evidence was not separated by authoritative Steam identity.');
}
if (report.players.some(player => !player.steamId && player.usernames.includes('KFFC'))) {
  throw new Error('An unresolved duplicate-name KFFC player leaked into the report.');
}
if (oldKffc.evidenceEvents.some(event => event.steamId !== oldKffc.steamId)
    || newKffc.evidenceEvents.some(event => event.steamId !== newKffc.steamId)) {
  throw new Error('Same-name trap evidence crossed Steam identity boundaries.');
}
if (!oldKffc.evidenceEvents.every(event => event.identitySource === 'map-log')) {
  throw new Error('Legacy trap evidence was not resolved through the map audit log.');
}
if (report.summary.explosiveTrapAdds !== 13) throw new Error('Trap packet summary count is incorrect.');

console.log('anti-cheat explosive trap signal tests passed');
