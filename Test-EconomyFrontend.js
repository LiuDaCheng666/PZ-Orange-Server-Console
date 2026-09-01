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
  "view-economy", "economyStatus", "economyRankingList", "economyAccountList",
  "economyAccountDetail", "economyFlowList", "economyFlowPrev", "economyFlowNext",
]) {
  assert(ids.includes(id), `missing economy element #${id}`);
}

for (const endpoint of [
  "/api/economy?serverId=", "/api/economy/flow-query", "/api/economy/receipt",
  "/api/economy/balance-adjust", "/api/economy/donor", "/api/economy/donor-settings",
  "/api/economy/leaderboard",
]) {
  assert(js.includes(endpoint), `missing frontend endpoint ${endpoint}`);
}

for (const confirmation of [
  "ADJUST_ECONOMY_BALANCE", "SET_ECONOMY_DONOR", "SET_ECONOMY_DONOR_SETTINGS",
  "SET_ECONOMY_LEADERBOARD_OVERRIDE", "CLEAR_ECONOMY_LEADERBOARD_OVERRIDE",
]) {
  assert(js.includes(confirmation), `missing confirmation token ${confirmation}`);
}

assert(html.includes('name="canViewEconomy"'), "economy viewer permission is missing");
assert(html.includes('name="canManageEconomy"'), "economy manager permission is missing");
assert(js.includes("const canViewEconomy="), "economy navigation is not permission gated");
assert(js.includes("pageSize:50"), "flow queries must stay paged at 50 rows");
assert(css.includes(".economy-account-layout"), "economy desktop layout is missing");
assert(css.includes("@media(max-width:780px)"), "economy responsive layout is missing");

console.log("Test-EconomyFrontend: PASS");
