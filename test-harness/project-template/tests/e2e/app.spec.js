const { test, expect } = require('@playwright/test');

test.describe('Task Tracker App', () => {
  test('page loads with correct title', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveTitle('Task Tracker');
  });

  test('page has main heading', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('h1')).toContainText('Task Tracker');
  });

  test('app container exists', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#app')).toBeVisible();
  });
});
