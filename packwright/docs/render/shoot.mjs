// Screenshots every window in screens.html into ../screenshots at 2x.
//   npm install --no-save playwright && npx playwright install chromium
//   node shoot.mjs            (all windows)   node shoot.mjs editor picker   (some)
import { chromium } from 'playwright';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
const here = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const out = path.resolve(here, '../screenshots');
const only = process.argv.slice(2);
const browser = await chromium.launch();
const page = await browser.newPage({ deviceScaleFactor: 2, viewport: { width: 1400, height: 1000 } });
await page.goto(pathToFileURL(path.join(here, 'screens.html')).href);
await page.waitForSelector('body[data-ready]');
await page.evaluate(() => document.fonts.ready);
// transparent page, so the rounded window corners come out transparent
await page.addStyleTag({ content: 'html, body { background: transparent !important; }' });
for (const id of await page.$$eval('.win', els => els.map(e => e.id))) {
  if (only.length && !only.includes(id)) continue;
  await page.locator('#' + id).screenshot({ path: path.join(out, id + '.png'), omitBackground: true });
  console.log('shot', id);
}
await browser.close();
