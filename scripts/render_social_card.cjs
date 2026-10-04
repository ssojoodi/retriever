// Render with the website audit's Playwright dependency and installed Chrome.
// Run: node scripts/render_social_card.cjs
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require(require.resolve('playwright', {paths: [path.join(__dirname, '../.build/web-audit')]}));
(async () => {
  const root = path.join(__dirname, '..');
  const icon = fs.readFileSync(path.join(root, 'web-page/app-icon.png')).toString('base64');
  const browser = await chromium.launch({executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true});
  try {
    const page = await browser.newPage({viewport: {width: 1200, height: 630}, deviceScaleFactor: 1});
    await page.setContent(`<!doctype html><html lang="en"><meta charset="utf-8"><style>
      * {box-sizing:border-box} body {margin:0;width:1200px;height:630px;background:#f6f1e8;color:#201d19;font-family:-apple-system,BlinkMacSystemFont,sans-serif}
      main {position:relative;width:100%;height:100%;padding:62px 72px}
      .brand {font-size:26px;font-weight:750;letter-spacing:-.5px}
      .label {margin-top:40px;color:#9b5f28;font-size:16px;font-weight:700;letter-spacing:1.8px;text-transform:uppercase}
      h1 {font-family:Georgia,serif;font-size:88px;line-height:.99;letter-spacing:-4px;margin:20px 0 23px;font-weight:700}
      .features {font-size:21px;line-height:1.5;color:#615b52;max-width:550px;margin:0}
      img {position:absolute;right:56px;top:108px;width:420px;height:420px;object-fit:contain}
      footer {position:absolute;left:72px;right:72px;bottom:44px;border-top:1px solid #d6cfc3;padding-top:20px;color:#126d76;font-size:18px;font-weight:600}
    </style><main><div class="brand">Retriever</div><div class="label">Native SFTP for Mac</div>
      <h1>Go fetch<br>your files.</h1><p class="features">Drag files and folders. Preview before saving.<br>Keep Files and your SSH terminal in sync.</p>
      <img src="data:image/png;base64,${icon}" alt="Retriever mascot"><footer>sojoodi.com/apps/Retriever</footer></main></html>`);
    await page.locator('img').evaluate(image => image.decode());
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({path: path.join(root, 'web-page/social-card.png')});
  } finally {await browser.close();}
})().catch(error => {console.error(error);process.exit(1)});
