// End-to-end check of the leader conversations in the sidebar (#3623, docs/web/web.md "Persona chats"): with the hub's
// `assistant.leaders` set, a fresh browser (nothing in localStorage) shows them first among the Persona chats, in the
// hub's order, as the 方向 (Directions) group under each direction's name from GET /api/v1/assistant/leaders, with no
// 主管 label and no 置顶 heading; the rest are 其他对话; New chat is the compose icon on the section's title, not a row;
// a chat pinned in this browser comes after the directions under 置顶; 其他对话 shows at most 5 rows, then 全部对话; a
// direction's menu has 取消置顶 (#4331), which the hub keeps: it moves after the pinned ones, still under 方向, and 置顶
// puts it back.
//
// Needs the web page against the fake hub with leaders, and Chrome (or any Chromium through --executable):
//
//   MOCK_LEADERS=1 PORT=18986 python3 scripts/mock/mock_hub.py &
//   (cd web && PERSONA_HUB_URL=http://127.0.0.1:18986 npx vite --port 5986 --strictPort &)
//   node web/e2e/leader-pins.mjs http://127.0.0.1:5986 [--shots <dir>] [--executable <chromium>]
//
// Runs wide (1280) and phone width (390, the drawer), light and dark, in Chinese; --shots saves each. Prints one line per
// check and a verdict; exits 1 on a failure and after three minutes.
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { chromium } from "playwright-core";

const args = process.argv.slice(2);
const flag = (name) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : undefined;
};
const base = (args[0] ?? "").replace(/\/$/, "");
const shots = flag("--shots");
const executable = flag("--executable");
if (!base) {
  console.error("usage: node web/e2e/leader-pins.mjs <web URL> [--shots <dir>] [--executable <chromium>]");
  process.exit(2);
}
if (shots) mkdirSync(shots, { recursive: true });
setTimeout(() => {
  console.log("FAIL timed out after 3 minutes");
  process.exit(1);
}, 180_000).unref();

const ok = (msg) => console.log(`ok  ${msg}`);
function fail(msg) {
  console.log(`FAIL ${msg}`);
  process.exit(1);
}

const hub = (path) => fetch(`${base}/api/v1${path}`, { headers: { Authorization: "Bearer mock" }, signal: AbortSignal.timeout(5000) }).then((r) => r.json());
const assistant = await hub("/assistant");
const leaders = assistant.leaders ?? [];
if (leaders.length < 2) fail(`the fake hub has no leaders (start it with MOCK_LEADERS=1): ${JSON.stringify(leaders)}`);
const names = new Map(((await hub("/assistant/leaders")).leaders ?? []).map((l) => [l.id, l.name]));
const others = assistant.conversations.filter((c) => c.session_id !== assistant.main && !leaders.includes(c.session_id));
const local = others[others.length - 1].session_id;

// the Persona chats' rows in the order shown, without New chat
const rowIds = (page) => page.$$eval('aside a[href^="/persona/"]', (as) => as.map((a) => a.getAttribute("href").slice("/persona/".length).split("?")[0]).filter((id) => id !== "new"));
// the group titles inside Persona chats
const headings = (page) => page.$$eval('aside [role="heading"]', (hs) => hs.map((h) => h.textContent.trim()));

async function open(browser, theme, width, pins) {
  const ctx = await browser.newContext({ viewport: { width, height: width > 600 ? 820 : 844 }, deviceScaleFactor: 2, colorScheme: theme, locale: "zh-CN", hasTouch: width <= 600 });
  const page = await ctx.newPage();
  await page.goto(`${base}/?token=mock`);
  await page.waitForFunction(() => localStorage.getItem("persona.token"), null, { timeout: 15000 });
  await page.evaluate(([t, p]) => {
    localStorage.setItem("persona.theme", t);
    localStorage.setItem("persona.language", "zh-Hans");
    if (p) localStorage.setItem("assistant.pinned", JSON.stringify(p));
    else localStorage.removeItem("assistant.pinned");
  }, [theme, pins]);
  await page.goto(`${base}/overview`);
  await page.waitForSelector("main", { timeout: 15000 });
  if (width <= 600) {
    await page.locator("main").getByRole("button", { name: "侧边栏" }).first().click();
    await page.waitForTimeout(500); // the drawer slides in
  }
  await page.locator(`aside a[href^="/persona/${leaders[0]}"]`).first().waitFor({ state: "visible", timeout: 10000 }).catch(() => fail(`${theme} ${width}: no row for the first leader`));
  return { ctx, page };
}

const browser = await chromium.launch(executable ? { executablePath: executable } : { channel: "chrome" });
try {
  for (const theme of ["light", "dark"]) {
    for (const width of [1280, 390]) {
      const where = `${theme} ${width}px`;
      const { ctx, page } = await open(browser, theme, width, null);
      const ids = await rowIds(page);
      if (JSON.stringify(ids.slice(0, leaders.length)) !== JSON.stringify(leaders)) fail(`${where}: leaders not first in the hub's order: ${ids.join(",")}`);
      for (const id of leaders) {
        const text = await page.locator(`aside a[href^="/persona/${id}"]`).first().textContent();
        if (text.includes("主管")) fail(`${where}: leader ${id} still has the 主管 label`);
        if (!names.get(id) || !text.includes(names.get(id))) fail(`${where}: leader ${id} does not show its direction's name ${names.get(id)}: ${text}`);
      }
      const hs = await headings(page);
      if (JSON.stringify(hs) !== JSON.stringify(["方向", "其他对话"])) fail(`${where}: group titles are ${hs.join(" | ")}`);
      const compose = page.locator('aside .group\\/sec a[href="/persona/new"][aria-label="新对话"]');
      if (!(await compose.count()) || (await compose.first().textContent()) !== "") fail(`${where}: New chat is not the icon on the Persona chats title`);
      if (await page.locator('aside a[href="/persona/new"]', { hasText: "新对话" }).count()) fail(`${where}: New chat still has a row of its own`);
      ok(`${where}: a fresh browser shows the ${leaders.length} leaders first under 方向 by name (${leaders.map((id) => names.get(id)).join(" / ")}), the rest under 其他对话, New chat as the title's icon`);
      if (shots) await page.screenshot({ path: join(shots, `web-leader-pins-${width > 600 ? "wide" : "narrow"}-${theme}.png`) });
      await ctx.close();
    }
  }

  const { ctx, page } = await open(browser, "light", 1280, [local]);
  const ids = await rowIds(page);
  if (JSON.stringify(ids.slice(0, leaders.length + 1)) !== JSON.stringify([...leaders, local])) fail(`a local pin is not right after the leaders: ${ids.join(",")}`);
  const hs = await headings(page);
  if (JSON.stringify(hs) !== JSON.stringify(["方向", "置顶", "其他对话"])) fail(`with a local pin the group titles are ${hs.join(" | ")}`);
  ok("a chat pinned in this browser comes right after the directions, under 置顶");

  const menuOf = async (id) => {
    await page.locator(`aside a[href^="/persona/${id}"]`).first().click({ button: "right" });
    const menu = page.locator('[role="menu"]').last();
    await menu.waitFor({ state: "visible", timeout: 5000 });
    const items = await menu.locator('[role="menuitem"]').allTextContents();
    await page.keyboard.press("Escape");
    return items;
  };
  const others5 = ids.slice(leaders.length + 1);
  if (others5.length > 5) fail(`其他对话 shows ${others5.length} rows, more than 5`);
  if (!(await page.locator('aside a[href="/history"]', { hasText: "全部对话" }).count())) fail("no 全部对话 entry under 其他对话");
  ok(`其他对话 shows ${others5.length} rows, then 全部对话`);
  const localMenu = await menuOf(local);
  if (!localMenu.some((x) => x.includes("取消置顶"))) fail(`the local pin's menu has no Unpin: ${localMenu.join(" | ")}`);
  if (shots) await page.screenshot({ path: join(shots, "web-leader-pins-wide-with-local-pin.png") });

  // a direction: 取消置顶 through the hub, after the pinned ones but still under 方向; 置顶 puts it back
  const pick = async (id, label) => {
    await page.locator(`aside a[href^="/persona/${id}"]`).first().click({ button: "right" });
    const menu = page.locator('[role="menu"]').last();
    await menu.waitFor({ state: "visible", timeout: 5000 });
    if (shots && label === "取消置顶") await page.screenshot({ path: join(shots, "web-direction-menu-unpin.png") });
    await menu.locator('[role="menuitem"]', { hasText: new RegExp(`^${label}`) }).first().click();
  };
  await pick(leaders[0], "取消置顶");
  const moved = [...leaders.slice(1), leaders[0]];
  await page.waitForFunction(([want]) => {
    const got = [...document.querySelectorAll('aside a[href^="/persona/"]')].map((a) => a.getAttribute("href").slice("/persona/".length).split("?")[0]).filter((id) => id !== "new");
    return JSON.stringify(got.slice(0, want.length)) === JSON.stringify(want);
  }, [moved], { timeout: 5000 }).catch(async () => fail(`unpinned, the first direction did not move after the others: ${(await rowIds(page)).join(",")}`));
  if (JSON.stringify((await headings(page))[0]) !== JSON.stringify("方向")) fail("unpinned, the direction left 方向");
  if (!(await menuOf(leaders[0])).some((x) => x.startsWith("置顶"))) fail("an unpinned direction's menu has no 置顶");
  if (!(await hub("/assistant")).leaders_unpinned?.includes(leaders[0])) fail("the hub did not keep the unpin");
  ok("a direction's 取消置顶 goes to the hub: it moves after the pinned ones, still under 方向");
  if (shots) await page.screenshot({ path: join(shots, "web-direction-unpinned.png") });
  await pick(leaders[0], "置顶");
  await page.waitForFunction(([want]) => {
    const got = [...document.querySelectorAll('aside a[href^="/persona/"]')].map((a) => a.getAttribute("href").slice("/persona/".length).split("?")[0]).filter((id) => id !== "new");
    return JSON.stringify(got.slice(0, want.length)) === JSON.stringify(want);
  }, [leaders], { timeout: 5000 }).catch(async () => fail(`pinned again, the order is ${(await rowIds(page)).join(",")}`));
  ok("置顶 puts it back first");
  await ctx.close();
} finally {
  await browser.close();
}
console.log("PASS web leader pins e2e");
process.exit(0);
