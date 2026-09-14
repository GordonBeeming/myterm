import { chromium } from 'playwright';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';

const browserDirectory = resolve(import.meta.dirname);
const relayDirectory = resolve(browserDirectory, '../..');
const evidenceDirectory = process.env.MYTERM_RELAY_EVIDENCE_DIR
  ?? resolve(browserDirectory, 'test-results');
const chromePath = process.env.PLAYWRIGHT_CHROME_PATH
  ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const profile = await mkdtemp(join(tmpdir(), 'myterm-relay-playwright-'));
await mkdir(evidenceDirectory, { recursive: true });
const fixtureBinary = join(profile, 'relay-browser-fixture');
const build = spawnSync('go', ['build', '-o', fixtureBinary, './tests/browser/fixture'], {
  cwd: relayDirectory, encoding: 'utf8',
});
if (build.status !== 0) throw new Error(`fixture build failed: ${build.stderr}`);

const fixture = spawn(fixtureBinary, [], {
  cwd: relayDirectory,
  stdio: ['ignore', 'pipe', 'pipe'],
  env: { ...process.env },
});
let fixtureErrors = '';
fixture.stderr.on('data', chunk => { fixtureErrors += chunk.toString(); });

let context;
try {
  const fixtureInfo = await firstJSONLine(fixture.stdout);
  context = await chromium.launchPersistentContext(profile, {
    executablePath: chromePath,
    headless: true,
    viewport: { width: 1200, height: 900 },
    ignoreHTTPSErrors: false,
    args: [
      `--ignore-certificate-errors-spki-list=${fixtureInfo.spki_hash}`,
      '--host-resolver-rules=MAP relay.localhost 127.0.0.1',
    ],
  });
  const page = context.pages()[0] ?? await context.newPage();
  const browserErrors = [];
  page.on('pageerror', error => browserErrors.push(String(error)));
  await page.route('myterm-companion://**', route => route.abort('aborted'));

  const cdp = await context.newCDPSession(page);
  await cdp.send('WebAuthn.enable');
  const { authenticatorId } = await cdp.send('WebAuthn.addVirtualAuthenticator', {
    options: {
      protocol: 'ctap2',
      transport: 'internal',
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      automaticPresenceSimulation: true,
    },
  });

  await page.goto(fixtureInfo.bootstrap_url, { waitUntil: 'networkidle' });
  await assertPageLayout(page, 'Register owner passkey');
  await page.screenshot({ path: join(evidenceDirectory, 'register-desktop.png'), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await assertPageLayout(page, 'Register owner passkey');
  await page.screenshot({ path: join(evidenceDirectory, 'register-mobile.png'), fullPage: true });
  await page.setViewportSize({ width: 1200, height: 900 });

  const registration = await finishCeremony(page, 'register');
  assert(registration.state.length >= 32, 'registration state missing');
  await page.goto(`${fixtureInfo.origin}/healthz`);
  await assertTokenFailuresAndExchange(page, fixtureInfo, registration.code);

  // The production auth limiter refills one request every six seconds. The test waits instead of weakening it.
  await page.waitForTimeout(18_500);

  await page.goto(fixtureInfo.login_url, { waitUntil: 'networkidle' });
  await assertPageLayout(page, 'Sign in with a passkey');
  await page.screenshot({ path: join(evidenceDirectory, 'login-desktop.png'), fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  await assertPageLayout(page, 'Sign in with a passkey');
  await page.screenshot({ path: join(evidenceDirectory, 'login-mobile.png'), fullPage: true });
  const login = await finishCeremony(page, 'login');
  await page.goto(`${fixtureInfo.origin}/healthz`);
  const loginToken = await exchange(page, fixtureInfo, login.code,
                                    'myterm-companion://auth/callback', fixtureInfo.verifier);
  assert(loginToken.status === 200 && loginToken.body.account_id, 'login token exchange failed');

  await page.waitForTimeout(12_500);

  const invalid = new URL(fixtureInfo.bootstrap_url);
  invalid.hash = `bootstrap_token=${'x'.repeat(43)}`;
  await page.goto(invalid.toString(), { waitUntil: 'networkidle' });
  const failedOptions = page.waitForResponse(response => response.url().endsWith('/v1/webauthn/register/options'));
  await page.locator('#continue').click({ noWaitAfter: true });
  const failedResponse = await failedOptions;
  assert(failedResponse.status() === 401, `invalid bootstrap returned ${failedResponse.status()}`);
  await page.waitForFunction(() => document.querySelector('#error')?.textContent?.length > 0);
  assert(await page.locator('#continue').isEnabled(), 'retry button stayed disabled after error');

  const credentials = await cdp.send('WebAuthn.getCredentials', { authenticatorId });
  assert(credentials.credentials.length === 1, `virtual authenticator has ${credentials.credentials.length} credentials`);
  assert(browserErrors.length === 0, `browser JavaScript errors: ${browserErrors.join('; ')}`);
  console.log(JSON.stringify({
    result: 'passed',
    credentials: credentials.credentials.length,
    screenshots: ['register-desktop.png', 'register-mobile.png', 'login-desktop.png', 'login-mobile.png'],
  }));
} finally {
  if (context) await context.close();
  if (fixture.exitCode === null) {
    const fixtureExit = new Promise(resolvePromise => fixture.once('exit', resolvePromise));
    fixture.kill('SIGTERM');
    await fixtureExit;
  }
  await rm(profile, { recursive: true, force: true });
  if (fixture.exitCode && fixtureErrors) process.stderr.write(fixtureErrors);
}

async function finishCeremony(page, mode) {
  const responsePromise = page.waitForResponse(response => response.url().endsWith(`/v1/webauthn/${mode}/finish`));
  await page.locator('#continue').click({ noWaitAfter: true });
  const response = await responsePromise;
  const body = await response.json();
  assert(response.status() === 200, `${mode} failed: ${JSON.stringify(body)}`);
  assert(typeof body.code === 'string' && body.code.length > 20, `${mode} returned no code`);
  return body;
}

async function assertTokenFailuresAndExchange(page, fixtureInfo, code) {
  const wrongCallback = await exchange(page, fixtureInfo, code, 'myterm-dev://companion-auth/callback', fixtureInfo.verifier);
  assert(wrongCallback.status === 401, `wrong callback returned ${wrongCallback.status}: ${JSON.stringify(wrongCallback.body)}`);
  const wrongVerifier = await exchange(page, fixtureInfo, code,
                                       'myterm-companion://auth/callback', `${fixtureInfo.verifier}x`);
  assert(wrongVerifier.status === 401, `wrong verifier returned ${wrongVerifier.status}`);
  const valid = await exchange(page, fixtureInfo, code,
                               'myterm-companion://auth/callback', fixtureInfo.verifier);
  assert(valid.status === 200 && valid.body.access_token && valid.body.account_id, 'valid code exchange failed');
  const refresh = await page.evaluate(async refreshToken => {
    const response = await fetch('/v1/oauth/token', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ grant_type: 'refresh_token', refresh_token: refreshToken }),
    });
    return { status: response.status, body: await response.json() };
  }, valid.body.refresh_token);
  assert(refresh.status === 200 && refresh.body.refresh_token !== valid.body.refresh_token,
         'refresh did not rotate');
  const replay = await page.evaluate(async refreshToken => {
    const response = await fetch('/v1/oauth/token', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ grant_type: 'refresh_token', refresh_token: refreshToken }),
    });
    return response.status;
  }, valid.body.refresh_token);
  assert(replay === 401, `old refresh token replay returned ${replay}`);
  const descendant = await page.evaluate(async refreshToken => {
    const response = await fetch('/v1/oauth/token', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ grant_type: 'refresh_token', refresh_token: refreshToken }),
    });
    return response.status;
  }, refresh.body.refresh_token);
  assert(descendant === 401, `refresh replay left descendant active: ${descendant}`);
}

async function exchange(page, fixtureInfo, code, redirectURI, verifier) {
  return page.evaluate(async args => {
    const response = await fetch('/v1/oauth/token', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        grant_type: 'authorization_code', code: args.code,
        code_verifier: args.verifier, redirect_uri: args.redirectURI,
      }),
    });
    return { status: response.status, body: await response.json() };
  }, { code, redirectURI, verifier });
}

async function assertPageLayout(page, heading) {
  assert(await page.getByRole('heading', { name: heading }).isVisible(), `${heading} is not visible`);
  assert(await page.getByRole('button', { name: 'Continue' }).isVisible(), 'Continue button is not visible');
  const layout = await page.evaluate(() => {
    const card = document.querySelector('.card').getBoundingClientRect();
    return {
      cardLeft: card.left, cardRight: card.right, width: innerWidth,
      scrollWidth: document.documentElement.scrollWidth,
      scrollHeight: document.documentElement.scrollHeight,
    };
  });
  assert(layout.cardLeft >= 0 && layout.cardRight <= layout.width, `card clipped: ${JSON.stringify(layout)}`);
  assert(layout.scrollWidth <= layout.width, `horizontal overflow: ${JSON.stringify(layout)}`);
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function firstJSONLine(stream) {
  return new Promise((resolvePromise, reject) => {
    const lines = createInterface({ input: stream });
    lines.once('line', line => {
      try { resolvePromise(JSON.parse(line)); } catch (error) { reject(error); }
      lines.close();
    });
    stream.once('error', reject);
  });
}
