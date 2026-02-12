// @ts-check
const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './tests/e2e',
  fullyParallel: false,
  workers: 1,
  timeout: 30000,
  expect: { timeout: 5000 },
  use: {
    baseURL: 'http://localhost:3000',
    screenshot: 'only-on-failure',
    trace: 'on-first-retry',
  },
  webServer: {
    command: 'node src/server.js',
    port: 3000,
    reuseExistingServer: false,
  },
  projects: [
    { name: 'chromium', use: { browserName: 'chromium' } },
  ],
});
