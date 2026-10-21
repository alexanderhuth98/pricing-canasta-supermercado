const AxeBuilder = require('@axe-core/playwright').default;
const { expect, test } = require('@playwright/test');

function dashboardPath(testInfo) {
  return testInfo.project.name === 'mobile-chromium' ? 'mobile.html' : './';
}

test.beforeEach(async ({ page, baseURL }) => {
  const applicationOrigin = new URL(baseURL).origin;
  await page.route('**/*', async (route) => {
    const requestURL = new URL(route.request().url());
    if (requestURL.origin !== applicationOrigin) {
      await route.abort();
      return;
    }
    await route.continue();
  });
});

test('@smoke boots the dashboard with its local Plotly asset', async ({ page }, testInfo) => {
  const pageErrors = [];
  page.on('pageerror', (error) => pageErrors.push(error.message));
  const response = await page.goto(dashboardPath(testInfo));

  expect(response?.ok()).toBeTruthy();
  await expect(page).toHaveTitle(/Pricing y canasta de supermercado/);
  await expect(page.getByRole('heading', { level: 1 })).toHaveText(
    'Pricing y canasta de supermercado',
  );
  const graph = page.locator('.plotly-graph-div');
  await expect(graph).toBeVisible();
  await expect.poll(() => graph.evaluate((element) => element.classList.contains('js-plotly-plot'))).toBe(
    true,
  );
  expect(await page.evaluate(() => typeof window.Plotly)).toBe('object');
  await expect(page.locator('#dashboard-status')).not.toHaveClass(/error/);
  expect(pageErrors).toEqual([]);
});

test('does not overflow horizontally', async ({ page }, testInfo) => {
  await page.goto(dashboardPath(testInfo));

  await expect
    .poll(() =>
      page.evaluate(() => ({
        clientWidth: document.documentElement.clientWidth,
        scrollWidth: document.documentElement.scrollWidth,
      })),
    )
    .toEqual(
      expect.objectContaining({
        clientWidth: expect.any(Number),
        scrollWidth: expect.any(Number),
      }),
    );
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
  );
  expect(overflow).toBeLessThanOrEqual(1);
});

test('reset view restores Plotly autorange', async ({ page }, testInfo) => {
  await page.goto(dashboardPath(testInfo));
  const graph = page.locator('.plotly-graph-div');
  await expect.poll(() => graph.evaluate((element) => Boolean(element.layout?.xaxis))).toBe(true);
  await graph.evaluate(async (element) => {
    await window.Plotly.relayout(element, {
      'xaxis.autorange': false,
      'xaxis.range': ['2026-07-28', '2026-07-29'],
    });
  });

  await page.getByRole('button', { name: 'Restablecer vista' }).click();

  await expect.poll(() => graph.evaluate((element) => element.layout.xaxis.autorange)).toBe(true);
  await expect(page.locator('#dashboard-status')).not.toHaveClass(/error/);
});

test('shows a useful fallback when the Plotly asset fails', async ({ page }, testInfo) => {
  await page.route('**/plotly.min.js', (route) => route.abort());

  await page.goto(dashboardPath(testInfo));

  const status = page.locator('#dashboard-status');
  await expect(status).toHaveClass(/error/);
  await expect(status).toContainText('No se pudieron cargar los gráficos');
});

test('returns 404 for a missing resource and publishes the not-found document', async ({ page }) => {
  const missing = await page.request.get(`missing-${Date.now()}`);
  expect(missing.status()).toBe(404);

  const response = await page.goto('404.html');
  expect(response?.ok()).toBeTruthy();
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Página no encontrada.');
  await expect(page.locator('meta[name="robots"]')).toHaveAttribute('content', 'noindex');
});

test('dashboard shell has no automatic accessibility violations', async ({ page }, testInfo) => {
  await page.goto(dashboardPath(testInfo));
  await expect(page.locator('.plotly-graph-div')).toBeVisible();

  const results = await new AxeBuilder({ page })
    .include('.site-header')
    .include('.panel-notices')
    .include('.dashboard-toolbar')
    .include('#dashboard-status')
    .analyze();

  expect(results.violations).toEqual([]);
});
