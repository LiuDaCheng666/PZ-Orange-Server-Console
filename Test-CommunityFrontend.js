"use strict";

const fs = require("fs");
const path = require("path");
const root = __dirname;
const html = fs.readFileSync(path.join(root, "web", "index.html"), "utf8");
const js = fs.readFileSync(path.join(root, "web", "app.js"), "utf8");
const css = fs.readFileSync(path.join(root, "web", "app.css"), "utf8");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]);
assert(new Set(ids).size === ids.length, "index.html contains duplicate ids");
for (const id of [
  "view-community", "communityBridgeStatus", "communityOfficeList", "communityLawSummary",
  "communityLawForm", "communityElectionForm", "communityTreasuryMeta", "communityTreasuryBalanceForm",
  "communityTreasuryPolicyForm", "communityLedgerList", "communityCrisisSummary", "communityCrisisForm",
  "communityBridgeBattleForm", "communityCommandList", "communityMaterialList", "communityMaterialSearch",
  "communityProjectList", "communityProjectLedger", "communityChamber", "communityElectionRole",
  "communityBallotSummary", "communityHonorList", "communityBridgeBattleSummary",
]) assert(ids.includes(id), `missing community element #${id}`);

for (const tab of ["overview","auction","election","law","profession","projects","treasury","crisis","honors","audit"]) {
  assert(html.includes(`data-community-target="${tab}"`), `missing community submenu target ${tab}`);
  assert(html.includes(`data-community-panel="${tab}"`), `missing community content panel ${tab}`);
}
assert((html.match(/data-orange-community-menu/g) || []).length === 2,
  "desktop and mobile must each expose one Orange Community feature menu");
for (const view of ["economy", "disasters"]) {
  assert(html.includes(`class="nav-subitem" type="button" data-view="${view}"`),
    `${view} must be nested under the desktop Orange Community menu`);
}
assert(!html.includes('class="nav-item" data-view="economy"')
  && !html.includes('class="nav-item" data-view="community"')
  && !html.includes('class="nav-item" data-view="disasters"'),
  "Orange Community pages must not remain separate desktop top-level entries");

for (const endpoint of [
  "/api/community?serverId=", "/api/community/treasury-ledger?", "/api/community/command",
  "/api/community/receipt?serverId=",
]) assert(js.includes(endpoint), `missing community frontend endpoint ${endpoint}`);

for (const operation of [
  "admin_override_law", "admin_start_election", "admin_close_election", "admin_vacate_office",
  "admin_set_treasury_balance", "admin_set_treasury_policy", "admin_update_crisis",
  "admin_create_auction", "admin_start_bridge_battle",
]) assert(js.includes(operation), `missing community operation ${operation}`);

assert(js.includes("COMMUNITY_ADMIN_COMMAND"), "community mutation confirmation is missing");
assert(js.includes("expectedRevision:communityRevision(operation)"), "community domain revision concurrency guard is missing");
assert(js.includes("reason.length<4||reason.length>180"), "community admin reasons are not validated consistently");
assert(js.includes(`input[name="reason"]').forEach(field=>field.maxLength=180)`), "community reason input limits are not normalized");
assert(js.includes("communityTerminalStatuses"), "Mod ACK terminal-state handling is missing");
assert(js.includes("renderCommunityChamber"), "semicircular election chamber is missing");
assert(js.includes("renderCommunityMaterials"), "treasury material inventory is missing");
assert(js.includes("item.progress??item.delivered??item.current"), "material project progress does not use the Mod progress field");
assert(js.includes("communityProjectStatusLabels"), "project status localization is missing");
assert(js.includes("communityProjectTemplateLabels"), "official project title localization is missing");
assert(js.includes("communityProjectEffectLabels"), "project effect localization is missing");
assert(js.includes("communityBattleLabels"), "bridge state localization is missing");
assert(js.includes("pageSize:'25'"), "treasury ledger is not requested as a bounded page");
assert(js.includes("if(activeView==='community')refreshCommunity(false)"), "cross-server community refresh is missing");
assert(js.includes("if(activeView==='community'&&!communitySnapshot)refreshCommunity(true)"), "first-load community refresh is missing");
assert(css.includes(".nav-submenu") && css.includes(".mobile-community-submenu"),
  "Orange Community desktop/mobile submenu styles are missing");
assert(js.includes("function openCommunitySection(") && js.includes("syncOrangeCommunityNavigation()"),
  "Orange Community submenu routing is missing");
assert(css.includes(".community-seat-field"), "community chamber layout is missing");
assert(css.includes(".community-material-list"), "community material list layout is missing");
for (const icon of ["overview", "election", "law", "profession", "projects", "treasury", "crisis", "honors", "audit"]) {
  assert(html.includes(`/community-icons/community_${icon}.png`), `missing Image2 community icon ${icon}`);
  assert(fs.existsSync(path.join(root, "web", "community-icons", `community_${icon}.png`)), `missing community icon asset ${icon}`);
}
assert(css.includes("@media(max-width:780px)"), "community tablet layout is missing");
assert(css.includes("@media(max-width:480px)"), "community phone layout is missing");
assert(css.includes("overflow-wrap:anywhere"), "community overflow protection is missing");

console.log("Test-CommunityFrontend: PASS");
