/**
 * take-screenshots.mjs — Captures dashboard screenshots with mock data.
 *
 * Starts serve.py, copies mock data into position, intercepts the Tailwind
 * CDN with a locally-built CSS file, captures 6 views (one per sidebar nav
 * view + handoff detail), then cleans up.
 *
 * Intended to be invoked by capture.sh, which handles environment detection
 * and sets the env vars below. Can also be run directly if you set them yourself.
 *
 * Environment variables (set by capture.sh):
 *   PLAYWRIGHT_MODULE   — absolute path to playwright index.mjs
 *   CHROMIUM_BIN        — absolute path to chromium executable
 *   SCREENSHOT_PORT     — HTTP server port (default: 8089)
 *
 * Output: screenshots/*.png
 */

const playwrightPath = process.env.PLAYWRIGHT_MODULE;
if (!playwrightPath) {
  console.error("PLAYWRIGHT_MODULE env var not set. Run via capture.sh or set it manually.");
  process.exit(1);
}
const { chromium } = await import(playwrightPath);

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

const CHROMIUM_BIN = process.env.CHROMIUM_BIN || null;
const PORT = parseInt(process.env.SCREENSHOT_PORT || "8089", 10);
const TAILWIND_CSS = readFileSync(resolve(__dirname, "tailwind-generated.css"), "utf-8");

// ---- Mock data management ------------------------------------------------

// Discover handoff files dynamically from mock-data/ directory
const MOCK_FILES = [
  { src: "state.json", dest: resolve(RALPH_DIR, "state.json"), backup: true },
  { src: "plan.json", dest: resolve(PROJECT_ROOT, "plan.json"), backup: true },
  { src: "knowledge-index.json", dest: resolve(RALPH_DIR, "knowledge-index.json"), backup: true },
  { src: "progress-log.json", dest: resolve(RALPH_DIR, "progress-log.json"), backup: true },
  { src: "events.jsonl", dest: resolve(RALPH_DIR, "logs", "events.jsonl"), backup: true },
];

for (let i = 1; i <= 99; i++) {
  const num = String(i).padStart(3, "0");
  const srcPath = resolve(MOCK_DIR, `handoff-${num}.json`);
  if (!existsSync(srcPath)) break;
  MOCK_FILES.push({
    src: `handoff-${num}.json`,
    dest: resolve(RALPH_DIR, "handoffs", `handoff-${num}.json`),
    backup: true,
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

    if (existsSync(f.dest)) {
      const bak = f.dest + ".screenshot-bak";
      renameSync(f.dest, bak);
      backups.push({ original: f.dest, backup: bak });
    } else {
      created.push(f.dest);
    }

    copyFileSync(srcPath, f.dest);
  }
}

function cleanupMockData() {
  // Remove files we created (didn't exist before)
  for (const f of created) {
    if (existsSync(f)) rmSync(f);
  }

  // Restore all backups
  for (const b of backups) {
    if (existsSync(b.backup)) {
      // Remove the mock copy first (it replaced the original)
      if (existsSync(b.original)) rmSync(b.original);
      renameSync(b.backup, b.original);
    }
  }
}

// ---- Server ---------------------------------------------------------------

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

// ---- Screenshot capture ---------------------------------------------------

async function capturePage(context, name, actions) {
  console.log(`  ${name}`);
  const page = await context.newPage();

  // Intercept Tailwind CDN → inject locally-built CSS
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

// ---- Main -----------------------------------------------------------------

async function main() {
  console.log("Installing mock data...");
  installMockData();

  let serverProc;
  try {
    console.log("Starting server on port", PORT, "...");
    serverProc = await startServer();

    const launchOptions = {
      args: [
        "--no-sandbox", "--disable-setuid-sandbox",
        "--disable-gpu", "--disable-dev-shm-usage", "--single-process",
      ],
    };
    if (CHROMIUM_BIN) launchOptions.executablePath = CHROMIUM_BIN;

    const browser = await chromium.launch(launchOptions);
    const context = await browser.newContext({
      viewport: { width: 1440, height: 900 },
      deviceScaleFactor: 2,
    });

    console.log("Capturing screenshots...");

    // Helper: click a sidebar nav button by its title attribute
    async function clickSidebarNav(page, title) {
      const btn = page.locator(`button[title="${title}"]`).first();
      if (await btn.count() > 0) {
        await btn.click();
        await page.waitForTimeout(500);
      }
    }

    // 1. Run view — default (TaskPlan + HandoffViewer)
    await capturePage(context, "01-dashboard-main.png");

    // 2. Run view — navigate to handoff #3
    await capturePage(context, "02-handoff-detail.png", async (page) => {
      // Navigate to handoff 3 via keyboard shortcut
      await page.keyboard.press("ArrowRight");
      await page.waitForTimeout(300);
      await page.keyboard.press("ArrowRight");
      await page.waitForTimeout(500);
    });

    // 3. Log view — event log with filters
    await capturePage(context, "03-log-view.png", async (page) => {
      await clickSidebarNav(page, "Log");
    });

    // 4. Insights view — progress log
    await capturePage(context, "04-insights-progress.png", async (page) => {
      await clickSidebarNav(page, "Insights");
    });

    // 5. Insights view — knowledge index tab
    await capturePage(context, "05-insights-knowledge.png", async (page) => {
      await clickSidebarNav(page, "Insights");
      const kiTab = page.locator("button").filter({ hasText: "Knowledge Index" }).first();
      if (await kiTab.count() > 0) {
        await kiTab.click();
        await page.waitForTimeout(500);
      }
    });

    // 6. Control view — settings + control plane + metrics
    await capturePage(context, "06-control-view.png", async (page) => {
      await clickSidebarNav(page, "Control");
    });

    await browser.close();
    console.log("Done! Screenshots saved to screenshots/ directory.");
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
