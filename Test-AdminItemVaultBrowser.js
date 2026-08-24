"use strict";

const fs = require("fs");
const http = require("http");
const path = require("path");
const { chromium } = require("playwright");

const webRoot = path.join(__dirname, "web");
const edgePath = "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";
const port = 18792;
const now = Date.now();
let grantBody = null;
let receiptReads = 0;

const profiles = [
  { id: "production", name: "正式服", serverName: "servertest" },
  { id: "server2", name: "2服", serverName: "server2" },
];
const servers = profiles.map((profile, index) => ({
  ...profile, kind: index ? "test" : "production", alive: true, status: "running", writable: true,
  commandChannel: "queue", onlineCount: 1, onlineKnown: true, canStart: false, canStop: true, canRestart: true,
}));
const template = {
  schema: 1,
  templateId: "vault-template-0123456789abcdef",
  createdMs: now - 60000,
  sourceProfileId: "production",
  sourceProfileName: "正式服",
  sourceServer: "servertest",
  sourceUsername: "admin",
  sourceSteamId: "76561198000000001",
  snapshotHash: "fedcba9876543210",
  summary: {
    item: "MarzGuns.AA12", customName: "满改 AA-12 自动霰弹枪", condition: 9, conditionMax: 10,
    ammo: 23, favorite: true, attachments: ["MarzGuns.AA12Drum", "MarzGuns.RedDot", "Gunworks.TacticalLight"],
  },
  snapshot: { item: "MarzGuns.AA12", modData: { fireSelector: "auto" }, weaponParts: [] },
};
const containerTemplate = {
  schema: 1,
  hashVersion: 2,
  templateId: "vault-template-fedcba9876543210",
  createdMs: now,
  sourceProfileId: "production",
  sourceProfileName: "正式服",
  sourceServer: "servertest",
  sourceUsername: "admin",
  sourceSteamId: "76561198000000001",
  snapshotHash: "0123456789abcdef",
  summary: {
    item: "Base.Bag_ALICEpack", customName: "管理员整备背包", kind: "container",
    condition: 10, conditionMax: 10, favorite: true, containedItemCount: 3,
    contentTypes: ["MarzGuns.AA12", "Base.Belt2", "Base.Cabbage"], attachments: [],
  },
  snapshot: {
    item: "Base.Bag_ALICEpack", modData: { owner: "admin" }, weaponParts: [],
    containerContents: [{ item: "MarzGuns.AA12" }, { item: "Base.Belt2", containerContents: [{ item: "Base.Cabbage" }] }],
  },
};
const queuedGrant = {
  requestId: "vault-grant-browser-test", templateId: containerTemplate.templateId, serverId: "server2", serverName: "2服",
  targetUsername: "TargetPlayer", targetSteamId: "76561198000000002", count: 2,
  status: "queued", detail: "waiting_for_server", delivered: 0, createdMs: now, updatedMs: now, requestedBy: "admin",
};

function json(response, body, status = 200) {
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
  response.end(JSON.stringify(body));
}
function body(request) {
  return new Promise((resolve, reject) => {
    let value = "";
    request.setEncoding("utf8");
    request.on("data", chunk => { value += chunk; });
    request.on("end", () => { try { resolve(value ? JSON.parse(value) : {}); } catch (error) { reject(error); } });
    request.on("error", reject);
  });
}
async function api(request, response, url) {
  if (url.pathname === "/api/auth/session") return json(response, { ok: true, authenticated: true, local: true, csrf: "test", user: { username: "admin", displayName: "管理员", canManagePlayerData: true } });
  if (url.pathname === "/api/status") return json(response, { ok: true, defaultServer: "production", serverTime: new Date().toISOString(), servers });
  if (url.pathname === "/api/log") return json(response, { ok: true, serverId: url.searchParams.get("serverId"), cursor: 0, reset: false, text: "" });
  if (url.pathname === "/api/chat") return json(response, { ok: true, serverId: url.searchParams.get("serverId"), cursor: 0, file: "", messages: [] });
  if (url.pathname === "/api/items/status") return json(response, { ok: true, serverId: url.searchParams.get("serverId"), ready: false, cacheAvailable: false, building: false });
  if (url.pathname === "/api/notices/status") return json(response, { ok: true, serverId: url.searchParams.get("serverId"), channel: { usable: false } });
  if (url.pathname === "/api/players") return json(response, { ok: true, serverId: url.searchParams.get("serverId"), onlineKnown: true, online: ["TargetPlayer"], players: [{ username: "TargetPlayer", steamId: "76561198000000002", online: true, role: "user" }, { username: "HistoryPlayer", steamId: "76561198000000003", online: false, role: "user" }] });
  if (url.pathname === "/api/admin-item-vault" && request.method === "GET") return json(response, { ok: true, templates: [containerTemplate, template], grants: [], imported: 2, invalid: 0, profiles, updatedAt: new Date().toISOString() });
  if (url.pathname === "/api/admin-item-vault/sync" && request.method === "POST") return json(response, { ok: true, templates: [containerTemplate, template], grants: [], imported: 2, invalid: 0, profiles, updatedAt: new Date().toISOString(), sync: { requested: 2, synced: 2, failed: 0, servers: profiles.map(profile => ({ id: profile.id, name: profile.name, status: "synced", detail: "completed=1" })) } });
  if (url.pathname === "/api/admin-item-vault/grant" && request.method === "POST") {
    grantBody = await body(request);
    return json(response, { ok: true, message: "发放请求已写入 2服 队列。", grant: queuedGrant }, 202);
  }
  if (url.pathname === "/api/admin-item-vault/receipt") {
    receiptReads += 1;
    return json(response, { ok: true, grant: { ...queuedGrant, status: "delivered", detail: "ok", delivered: 2, updatedMs: now + 2000 } });
  }
  return json(response, { ok: true });
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, `http://127.0.0.1:${port}`);
  if (url.pathname.startsWith("/api/")) {
    try { await api(request, response, url); } catch (error) { json(response, { ok: false, error: error.message }, 500); }
    return;
  }
  const fileName = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
  const filePath = path.join(webRoot, fileName);
  if (!filePath.startsWith(webRoot) || !fs.existsSync(filePath)) { response.writeHead(404); response.end(); return; }
  const type = fileName.endsWith(".css") ? "text/css" : fileName.endsWith(".js") ? "application/javascript" : "text/html";
  response.writeHead(200, { "Content-Type": `${type}; charset=utf-8` });
  fs.createReadStream(filePath).pipe(response);
});

(async () => {
  await new Promise(resolve => server.listen(port, "127.0.0.1", resolve));
  const browser = await chromium.launch({ executablePath: edgePath, headless: true, args: ["--disable-gpu"] });
  const errors = [];
  try {
    const desktop = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    desktop.on("pageerror", error => errors.push(`desktop: ${error.message}`));
    desktop.on("dialog", dialog => dialog.accept());
    await desktop.goto(`http://127.0.0.1:${port}/?view=vault&server=production`, { waitUntil: "networkidle" });
    await desktop.waitForSelector("#vaultTemplateList .vault-template-row");
    await desktop.waitForFunction(() => Boolean(document.querySelector("#vaultTargetPlayer option[value='0']")));
    await desktop.waitForFunction(() => document.querySelector("#vaultDetailPane")?.textContent.includes("内含物品"));
    const desktopLayout = await desktop.evaluate(() => {
      const selectors = ["#view-vault", ".vault-layout", ".vault-template-pane", ".vault-detail-pane", "#vaultGrantForm"];
      return selectors.map(selector => { const node = document.querySelector(selector); return { selector, width: node.clientWidth, scrollWidth: node.scrollWidth, height: node.clientHeight, scrollHeight: node.scrollHeight }; });
    });
    await desktop.selectOption("#vaultDestination", "server2");
    await desktop.waitForFunction(() => Boolean(document.querySelector("#vaultTargetPlayer option[value='0']")));
    await desktop.selectOption("#vaultTargetPlayer", "0");
    await desktop.fill("#vaultGrantForm input[name='count']", "2");
    await desktop.click("#vaultGrantForm button[type='submit']");
    await desktop.waitForFunction(() => document.querySelector("#vaultGrantHistory")?.textContent.includes("已送达"), null, { timeout: 7000 });
    await desktop.screenshot({ path: path.join(__dirname, "admin-item-vault-desktop.png"), fullPage: true });

    const mobile = await browser.newPage({ viewport: { width: 390, height: 844 } });
    mobile.on("pageerror", error => errors.push(`mobile: ${error.message}`));
    await mobile.goto(`http://127.0.0.1:${port}/?view=vault&server=production`, { waitUntil: "networkidle" });
    await mobile.waitForSelector("#vaultTemplateList .vault-template-row");
    const mobileOverflow = await mobile.evaluate(() => ({ body: document.body.scrollWidth - document.documentElement.clientWidth, detail: document.querySelector(".vault-detail-pane").scrollWidth - document.querySelector(".vault-detail-pane").clientWidth }));
    await mobile.screenshot({ path: path.join(__dirname, "admin-item-vault-mobile.png"), fullPage: true });

    if (errors.length) throw new Error(errors.join("\n"));
    if (!grantBody || grantBody.targetUsername !== "TargetPlayer" || grantBody.targetSteamId !== "76561198000000002" || grantBody.count !== 2) throw new Error("Grant request did not preserve the selected player identity and count.");
    if (grantBody.templateId !== containerTemplate.templateId) throw new Error("Container template was not selected for grant.");
    if (receiptReads < 1) throw new Error("Receipt polling did not run.");
    if (desktopLayout.some(row => row.scrollWidth > row.width + 1 && row.selector !== "#view-vault")) throw new Error(`Desktop horizontal overflow: ${JSON.stringify(desktopLayout)}`);
    if (mobileOverflow.body > 1 || mobileOverflow.detail > 1) throw new Error(`Mobile horizontal overflow: ${JSON.stringify(mobileOverflow)}`);
    console.log(JSON.stringify({ ok: true, grantBody, receiptReads, desktopLayout, mobileOverflow }, null, 2));
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
