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
  "communityBridgeBattleForm", "communityCommandList",
]) assert(ids.includes(id), `missing community element #${id}`);

for (const endpoint of [
  "/api/community?serverId=", "/api/community/treasury-ledger?", "/api/community/command",
  "/api/community/receipt?serverId=",
]) assert(js.includes(endpoint), `missing community frontend endpoint ${endpoint}`);

for (const operation of [
  "admin_override_law", "admin_start_election", "admin_close_election", "admin_vacate_office",
  "admin_set_treasury_balance", "admin_set_treasury_policy", "admin_update_crisis",
  "admin_start_bridge_battle",
]) assert(js.includes(operation), `missing community operation ${operation}`);

assert(js.includes("COMMUNITY_ADMIN_COMMAND"), "community mutation confirmation is missing");
assert(js.includes("expectedRevision:communityRevision()"), "community optimistic concurrency revision is missing");
assert(js.includes("communityTerminalStatuses"), "Mod ACK terminal-state handling is missing");
assert(js.includes("pageSize:'25'"), "treasury ledger is not requested as a bounded page");
assert(js.includes("if(activeView==='community')refreshCommunity(false)"), "cross-server community refresh is missing");
assert(js.includes("if(activeView==='community'&&!communitySnapshot)refreshCommunity(true)"), "first-load community refresh is missing");
assert(css.includes(".community-dashboard-grid"), "community desktop layout is missing");
assert(css.includes("@media(max-width:780px)"), "community tablet layout is missing");
assert(css.includes("@media(max-width:480px)"), "community phone layout is missing");
assert(css.includes("overflow-wrap:anywhere"), "community overflow protection is missing");

console.log("Test-CommunityFrontend: PASS");
