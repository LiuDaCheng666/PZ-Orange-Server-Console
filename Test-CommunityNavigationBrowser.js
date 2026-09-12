const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright-core');

const root = __dirname;
const webRoot = process.env.PZ_WEB_ROOT ? path.resolve(process.env.PZ_WEB_ROOT) : path.join(root, 'web');
const edgePath = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const contentTypes = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
};

function json(response, body) {
  response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(body));
}

function api(response, pathname) {
  if (pathname === '/api/auth/session') return json(response, {
    ok: true,
    authenticated: true,
    local: true,
    csrf: 'test',
    user: {
      username: 'admin',
      displayName: '管理员',
      canViewEconomy: true,
      canManageEconomy: true,
      canManagePlayerData: true,
    },
  });
  if (pathname === '/api/status') return json(response, {
    ok: true,
    defaultServer: 'production',
    serverTime: new Date().toISOString(),
    servers: [{
      id: 'production', name: '正式服', kind: 'production', alive: true, status: 'running', writable: true,
      javaPid: 816, ports: [16261], onlineKnown: true, onlineCount: 8, maxPlayers: 100,
    }],
  });
  if (pathname === '/api/community') return json(response, {
    ok: true,
    bridge: { available: true, writable: true },
    governance: { law: { governmentForm: 'constitutional' }, offices: {}, elections: {} },
    projects: { rows: [], templates: [] },
    treasury: { balance: 25000, materials: {}, materialCatalog: {} },
    crisis: { economic: {}, horde: {}, battle: {}, settings: {} },
    honors: { rows: [] },
    queue: [],
  });
  if (pathname === '/api/log' || pathname === '/api/chat') return json(response, { ok: true, cursor: 0, text: '', messages: [] });
  if (pathname === '/api/items/status') return json(response, { ok: true, ready: false, building: false });
  if (pathname === '/api/notices/status') return json(response, { ok: true, channel: { usable: false } });
  return json(response, { ok: true });
}

const server = http.createServer((request, response) => {
  try {
    const url = new URL(request.url, 'http://127.0.0.1');
    if (url.pathname.startsWith('/api/')) return api(response, url.pathname);
    const relative = url.pathname === '/' ? 'index.html' : url.pathname.replace(/^\/+/, '');
    const filePath = path.resolve(webRoot, relative);
    const resolvedRoot = path.resolve(webRoot);
    if (filePath !== path.join(resolvedRoot, 'index.html') && !filePath.startsWith(`${resolvedRoot}${path.sep}`)) {
      response.writeHead(403);
      return response.end();
    }
    response.writeHead(200, { 'Content-Type': contentTypes[path.extname(filePath)] || 'application/octet-stream' });
    response.end(fs.readFileSync(filePath));
  } catch (error) {
    response.writeHead(500);
    response.end(error.stack || error.message);
  }
});

async function inspect(page, mobile) {
  const menu = mobile ? '.mobile-menu-group[data-orange-community-menu]' : '.nav-group[data-orange-community-menu]';
  const toggle = `${menu} > [data-community-menu-toggle]`;
  const submenu = mobile ? `${menu} .mobile-community-submenu` : `${menu} .nav-submenu`;
  const target = section => `${submenu} [data-community-target="${section}"]`;

  if (mobile) await page.click('#mobileMenuToggle');
  const expanded = await page.locator(menu).evaluate(element => element.classList.contains('expanded'));
  if (!expanded) await page.click(toggle);
  await page.click(target('law'));
  await page.waitForFunction(() => document.querySelector('#pageTitle').textContent === '橙子社区 · 法律议案');
  if (!await page.locator('[data-community-panel="law"]').isVisible()) throw new Error('law panel is not visible');
  if (!await page.locator(target('law')).evaluate(element => element.classList.contains('active'))) throw new Error('law submenu is not active');

  if (mobile) await page.click('#mobileMenuToggle');
  await page.click(target('treasury'));
  await page.waitForFunction(() => document.querySelector('#pageTitle').textContent === '橙子社区 · 国库仓库');
  if (!await page.locator('[data-community-panel="treasury"]').isVisible()) throw new Error('treasury panel is not visible');

  if (mobile) await page.click('#mobileMenuToggle');
  await page.click(`${submenu} [data-view="disasters"]`);
  await page.waitForFunction(() => document.querySelector('#pageTitle').textContent === '橙子社区 · 灾难中心');
  if (!await page.locator('#view-disasters').isVisible()) throw new Error('disaster view is not visible');

  if (mobile) await page.click('#mobileMenuToggle');
  const layout = await page.evaluate(({ menu, submenu }) => {
    const documentRoot = document.documentElement;
    const menuBox = document.querySelector(menu).getBoundingClientRect();
    const submenuBox = document.querySelector(submenu).getBoundingClientRect();
    const clipped = [...document.querySelectorAll(`${submenu} button`)]
      .filter(button => button.scrollWidth > button.clientWidth + 2 || button.scrollHeight > button.clientHeight + 2)
      .map(button => button.textContent.trim());
    return {
      viewportWidth: documentRoot.clientWidth,
      pageWidth: documentRoot.scrollWidth,
      menuLeft: menuBox.left,
      menuRight: menuBox.right,
      submenuLeft: submenuBox.left,
      submenuRight: submenuBox.right,
      clipped,
    };
  }, { menu, submenu });
  return layout;
}

(async () => {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const port = server.address().port;
  const browser = await chromium.launch({ executablePath: edgePath, headless: true });
  const errors = [];
  try {
    const desktop = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
    desktop.on('pageerror', error => errors.push(`desktop: ${error.message}`));
    await desktop.goto(`http://127.0.0.1:${port}/?view=community&section=overview&server=production`, { waitUntil: 'domcontentloaded' });
    await desktop.waitForSelector('#authScreen', { state: 'hidden' });
    const desktopLayout = await inspect(desktop, false);
    await desktop.screenshot({ path: path.join(root, 'community-navigation-desktop.png'), fullPage: true });

    const mobile = await browser.newPage({ viewport: { width: 390, height: 844 } });
    mobile.on('pageerror', error => errors.push(`mobile: ${error.message}`));
    await mobile.goto(`http://127.0.0.1:${port}/?view=community&section=overview&server=production`, { waitUntil: 'domcontentloaded' });
    await mobile.waitForSelector('#authScreen', { state: 'hidden' });
    const mobileLayout = await inspect(mobile, true);
    await mobile.screenshot({ path: path.join(root, 'community-navigation-mobile.png'), fullPage: true });

    const overflow = [desktopLayout, mobileLayout].filter(layout =>
      layout.pageWidth > layout.viewportWidth + 1
      || layout.menuLeft < -1
      || layout.menuRight > layout.viewportWidth + 1
      || layout.submenuLeft < -1
      || layout.submenuRight > layout.viewportWidth + 1
      || layout.clipped.length
    );
    if (errors.length || overflow.length) throw new Error(JSON.stringify({ errors, desktopLayout, mobileLayout }, null, 2));
    console.log(JSON.stringify({ ok: true, desktopLayout, mobileLayout }, null, 2));
  } finally {
    await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
