# First Iteration — Task Tracker Test Project

This is **iteration 1** of Ralph Deluxe running on a Node.js test project.

## Project Context
- **Task Tracker**: Express API + vanilla HTML/CSS/JS frontend
- The project is a CRUD application for managing tasks with statuses, due dates, filtering, and statistics
- Tech stack: Express 4.x, Jest for testing, ESLint for linting, supertest for HTTP assertions

## Current Project State
The project has been bootstrapped with minimal seed files:
- `src/server.js` — Express app skeleton (creates app, serves static files from `public/`, exports `{ app, PORT }`; starts server when run directly via `require.main === module`)
- `public/index.html` — Empty HTML shell with title and app container
- `tests/setup.test.js` — Basic smoke test (package.json valid, server exports app)
- `tests/e2e/app.spec.js` — Playwright seed test (page loads, title correct, h1 exists)
- `playwright.config.js` — Playwright config (auto-starts server on port 3000, Chromium only)
- `package.json` — Dependencies declared: express, jest, eslint, supertest, @playwright/test

**npm install has already been run.** All dependencies are in `node_modules/`.

## Validation Commands
Three commands must pass after every iteration:
1. `npx jest --forceExit --detectOpenHandles` — All test files in `tests/` must pass
2. `npx eslint src/ tests/ --max-warnings 0` — Zero warnings/errors allowed
3. `npx playwright test` — All Playwright E2E browser tests must pass

## Key Conventions
- Use `module.exports` (CommonJS), not ES modules
- Use `'single quotes'` for strings (ESLint rule)
- Always end statements with semicolons (ESLint rule)
- Prefix unused function parameters with `_` (e.g., `_req`)
- Use `supertest` with `const request = require('supertest');` for HTTP tests
- Export `app` from server.js without starting it (tests use supertest, not a running server)
- Place tests in `tests/` mirroring `src/` structure (e.g., `tests/routes/tasks.test.js`)

## E2E Testing with Playwright
- Place Playwright tests in `tests/e2e/` with `.spec.js` extension (NOT `.test.js` — that's for Jest)
- Playwright runs via `npx playwright test` (separate runner from Jest)
- `playwright.config.js` auto-starts the Express server — no manual server management needed
- For frontend tasks, write Playwright tests alongside supertest API tests
- Use `page.goto('/')`, `page.locator()`, `expect(locator).toBeVisible()` patterns
- Playwright tests verify the actual browser-rendered UI, not just API responses

## Important Notes
- Do **NOT** install additional npm packages unless the task explicitly requires it
- Do **NOT** use TypeScript — this is a plain JavaScript project
- Do **NOT** modify `tests/setup.test.js` — it must continue to pass
- Do **NOT** modify `tests/e2e/app.spec.js` seed tests — they must continue to pass (add new spec files instead)
- Keep the in-memory data store simple (no database, no file I/O)
- Each test file should be self-contained with proper setup/teardown

## Handoff Importance
Your handoff is the **only context** the next iteration receives. Document thoroughly:
- What you built and the design decisions you made
- File paths for all created/modified files
- How the new code integrates with existing code
- Any gotchas or edge cases the next iteration should know about
- The current test count and pass status

The handoff JSON must match the schema provided via `--json-schema`.
