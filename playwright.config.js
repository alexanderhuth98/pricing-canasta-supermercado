const { defineConfig, devices } = require('@playwright/test');

const localBaseURL = 'http://127.0.0.1:41731';
const python = process.platform === 'win32' ? 'python' : 'python3';

module.exports = defineConfig({
  testDir: './tests/e2e',
  fullyParallel: true,
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: [
    ['line'],
    ['html', { open: 'never', outputFolder: 'playwright-report' }],
  ],
  outputDir: 'test-results',
  use: {
    baseURL: process.env.E2E_BASE_URL || localBaseURL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'off',
  },
  webServer: process.env.E2E_BASE_URL
    ? undefined
    : {
        command: `${python} -m http.server 41731 --bind 127.0.0.1 --directory site`,
        url: localBaseURL,
        reuseExistingServer: !process.env.CI,
      },
  projects: [
    {
      name: 'desktop-chromium',
      use: { ...devices['Desktop Chrome'] },
    },
    {
      name: 'mobile-chromium',
      use: { ...devices['Pixel 7'] },
    },
  ],
});
