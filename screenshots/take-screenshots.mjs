/**
 * take-screenshots.mjs — Captures dashboard screenshots with mock data.
 *
 * Starts a local HTTP server, copies mock data into position,
 * intercepts the Tailwind CDN with a locally-built CSS file,
 * uses Playwright to navigate and capture screenshots, then cleans up.
 *
 * Usage: PLAYWRIGHT_BROWSERS_PATH=/root/.cache/ms-playwright node screenshots/take-screenshots.mjs
 * Output: screenshots/*.png
 *
 * Prerequisites:
 *   npm install --save-dev tailwindcss@3
 *   npx tailwindcss -i <input.css> -o screenshots/tailwind-generated.css --minify
 */

import { chromium } from "/opt/node22/lib/node_modules/playwright/index.mjs";
import {
  readFileSync, mkdirSync, copyFileSync,
  existsSync, rmSync, renameSync
} from "fs";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";
import { spawn } from "child_process";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(__dirname, "..");
const MOCK_DIR = resolve(__dirname, "mock-data");
const OUT_DIR = resolve(__dirname);
const RALPH_DIR = resolve(PROJECT_ROOT, ".ralph");

const PORT = 8089;
const TAILWIND_CSS = readFileSync(resolve(__dirname, "tailwind-generated.css"), "utf-8");

// Files to place and their mock source / destination
const MOCK_FILES = [
  { src: "state.json", dest: resolve(RALPH_DIR, "state.json"), backup: true },
  { src: "plan.json", dest: resolve(PROJECT_ROOT, "plan.json"), backup: true },
  { src: "knowledge-index.json", dest: resolve(RALPH_DIR, "knowledge-index.json"), backup: false },
  { src: "progress-log.json", dest: resolve(RALPH_DIR, "progress-log.json"), backup: false },
  { src: "events.jsonl", dest: resolve(RALPH_DIR, "logs", "events.jsonl"), backup: false },
];

for (let i = 1; i <= 12; i++) {
  const num = String(i).padStart(3, "0");
  MOCK_FILES.push({
    src: `handoff-${num}.json`,
    dest: resolve(RALPH_DIR, "handoffs", `handoff-${num}.json`),
    backup: false,
  });
}

const backups = [];
const created = [];

function installMockData() {
  mkdirSync(resolve(RALPH_DIR, "handoffs"), { recursive: true });
  mkdirSync(resolve(RALPH_DIR, "logs"), { recursive: true });

  for (const f of MOCK_FILES) {
    const srcPath = resolve(MOCK_DIR, f.src);
    if (!existsSync(srcPath)) continue;

    if (f.backup && existsSync(f.dest)) {
      const bak = f.dest + ".screenshot-bak";
      renameSync(f.dest, bak);
      backups.push({ original: f.dest, backup: bak });
    } else if (!existsSync(f.dest)) {
      created.push(f.dest);
    }

    copyFileSync(srcPath, f.dest);
  }
}

function cleanupMockData() {
  for (const f of created) {
    if (existsSync(f)) rmSync(f);
  }
  for (let i = 1; i <= 12; i++) {
    const num = String(i).padStart(3, "0");
    const p = resolve(RALPH_DIR, "handoffs", `handoff-${num}.json`);
    if (existsSync(p)) rmSync(p);
  }
  for (const name of ["knowledge-index.json", "progress-log.json"]) {
    const p = resolve(RALPH_DIR, name);
    if (existsSync(p)) rmSync(p);
  }
  const eventsPath = resolve(RALPH_DIR, "logs", "events.jsonl");
  if (existsSync(eventsPath)) rmSync(eventsPath);

  for (const b of backups) {
    if (existsSync(b.backup)) {
      renameSync(b.backup, b.original);
    }
  }
}

function startServer() {
  return new Promise((resolveP, reject) => {
    const proc = spawn("python3", [
      resolve(RALPH_DIR, "serve.py"), "--port", String(PORT),
    ], { cwd: PROJECT_ROOT, stdio: ["ignore", "pipe", "pipe"] });

    let started = false;
    const onData = (data) => {
      if (data.toString().includes("running at") && !started) {
        started = true;
        resolveP(proc);
      }
    };
    proc.stdout.on("data", onData);
    proc.stderr.on("data", onData);
    proc.on("error", reject);
    setTimeout(() => { if (!started) { started = true; resolveP(proc); } }, 2000);
  });
}

async function capturePage(context, name, actions) {
  console.log(`Capturing: ${name}`);
  const page = await context.newPage();

  // Intercept Tailwind CDN script → inject local CSS instead
  await page.route("**cdn.tailwindcss.com**", (route) => {
    route.fulfill({
      contentType: "application/javascript",
      body: `
        const style = document.createElement("style");
        style.textContent = ${JSON.stringify(TAILWIND_CSS)};
        document.head.appendChild(style);
      `,
    });
  });

  const BASE_URL = `http://127.0.0.1:${PORT}/.ralph/dashboard.html`;
  await page.goto(BASE_URL, { waitUntil: "networkidle", timeout: 15000 });
  await page.waitForTimeout(2000);

  if (actions) await actions(page);

  await page.screenshot({
    path: resolve(OUT_DIR, name),
    fullPage: true,
  });
  await page.close();
}

async function main() {
  console.log("Installing mock data...");
  installMockData();

  let serverProc;
  try {
    console.log("Starting server on port", PORT, "...");
    serverProc = await startServer();

    const browser = await chromium.launch({
      executablePath: "/root/.cache/ms-playwright/chromium-1194/chrome-linux/chrome",
      args: [
        "--no-sandbox", "--disable-setuid-sandbox",
        "--disable-gpu", "--disable-dev-shm-usage", "--single-process",
      ],
    });
    const context = await browser.newContext({
      viewport: { width: 1440, height: 900 },
      deviceScaleFactor: 2,
    });

    // 1. Main dashboard (handoff-plus-index mode, running)
    await capturePage(context, "01-dashboard-main.png");

    // 2. Handoff #3 selected (deviations, bugs, constraints)
    await capturePage(context, "02-handoff-detail.png", async (page) => {
      const btns = page.locator("button.w-7.h-7");
      if (await btns.count() >= 3) {
        await btns.nth(2).click();
        await page.waitForTimeout(500);
      }
    });

    // 3. Handoff-only mode
    await capturePage(context, "03-handoff-only-mode.png", async (page) => {
      const toggle = page.locator("button").filter({
        has: page.locator("text=Handoff Only"),
      }).first();
      if (await toggle.count() > 0) {
        await toggle.click();
        await page.waitForTimeout(500);
      }
    });

    // 4. Architecture tab
    await capturePage(context, "04-architecture-tab.png", async (page) => {
      const btn = page.locator("button").filter({ hasText: "architecture" }).first();
      if (await btn.count() > 0) {
        await btn.click();
        await page.waitForTimeout(500);
      }
    });

    // 5. Progress log detail view with expanded tasks
    await capturePage(context, "05-progress-log-detail.png", async (page) => {
      const detailBtn = page.locator("button").filter({ hasText: "detail" }).first();
      if (await detailBtn.count() > 0) {
        await detailBtn.click();
        await page.waitForTimeout(500);
      }
      const t3 = page.locator("text=TASK-003").first();
      if (await t3.count() > 0) { await t3.click(); await page.waitForTimeout(300); }
      const t4 = page.locator("text=TASK-004").first();
      if (await t4.count() > 0) { await t4.click(); await page.waitForTimeout(300); }
    });

    // 6. Settings panel open
    await capturePage(context, "06-settings-panel.png", async (page) => {
      const hdr = page.locator("h2").filter({ hasText: "Settings" }).first();
      if (await hdr.count() > 0) {
        await hdr.click();
        await page.waitForTimeout(500);
      }
      await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
      await page.waitForTimeout(300);
    });

    await browser.close();
    console.log("\nDone! Screenshots saved to screenshots/ directory.");
  } finally {
    if (serverProc) serverProc.kill("SIGTERM");
    console.log("Cleaning up mock data...");
    cleanupMockData();
  }
}

main().catch((err) => {
  console.error("Screenshot capture failed:", err);
  cleanupMockData();
  process.exit(1);
});
