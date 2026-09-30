const { chromium } = require(require.resolve('playwright', {paths: [require('node:path').join(__dirname, '../.build/web-audit')]}));
const assert = require('node:assert/strict');
const fs = require('node:fs');
(async () => {
  fs.mkdirSync('artifacts/verification', {recursive:true});
  const browser = await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
  try {
    const page = await browser.newPage({viewport:{width:1440,height:1000},deviceScaleFactor:1});
    const errors=[];
    page.on('pageerror', e=>errors.push(String(e)));
    const response=await page.goto('http://127.0.0.1:8105/',{waitUntil:'networkidle'});
    assert.equal(response.status(),200);
    const manifest=await (await page.request.get('http://127.0.0.1:8105/release.json')).json();
    await page.locator('[data-download]').first().waitFor({state:'visible'});
    assert.equal(await page.title(),'Retriever — SFTP for macOS');
    assert.equal(await page.locator('[data-download]').first().getAttribute('href'),'Retriever.dmg');
    await page.keyboard.press('Tab');
    assert.equal(await page.locator(':focus').textContent(),'Skip to content');
    const [fileDownload] = await Promise.all([page.waitForEvent('download'), page.locator('[data-download]').first().click()]);
    assert.equal(fileDownload.suggestedFilename(),'Retriever.dmg');
    await fileDownload.saveAs('.build/web-audit/clicked-Retriever.dmg');
    await page.screenshot({path:'artifacts/verification/website-desktop.png',fullPage:true});
    await page.getByRole('link',{name:'How it works'}).click();
    assert.match(page.url(),/#how-it-works$/);
    await page.getByRole('link',{name:'Release notes ↗'}).click();
    await page.waitForLoadState('networkidle');
    assert.equal(await page.title(),'Release notes — Retriever for macOS');
    await page.locator('[data-download]').waitFor({state:'visible'});
    assert.equal(await page.locator('[data-latest-release-label]').textContent(),'Published');
    assert.equal(await page.locator('#v0-2-0').count(),1);
    assert.equal(await page.locator('#v0-2-0 time').getAttribute('datetime'),'2026-09-29');
    assert.equal(await page.locator('#v0-2-0 time').textContent(),'September 29, 2026');
    assert.equal(await page.locator('#v0-1-0').count(),1);
    const screenshots = page.locator('#v0-2-0 .release-screenshot img');
    assert.equal(await screenshots.count(), 4);
    for (const screenshot of await screenshots.all()) {
      await screenshot.scrollIntoViewIfNeeded();
      await screenshot.evaluate(image => image.decode());
      assert.match(await screenshot.getAttribute('src'), /^screenshots\/0\.2\.0\/[^/]+\.png$/);
      assert.ok(await screenshot.evaluate(image => image.naturalWidth > 0 && image.naturalHeight > 0));
      const link = screenshot.locator('..');
      assert.equal(await link.getAttribute('href'), await screenshot.getAttribute('src'));
    }
    await page.evaluate(()=>window.scrollTo(0,0));
    await page.screenshot({path:'artifacts/verification/release-notes-desktop.png',fullPage:true});
    await page.setViewportSize({width:390,height:844});
    for (const path of ['/', '/release-notes.html']) {
      await page.goto('http://127.0.0.1:8105'+path,{waitUntil:'networkidle'});
      assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth), 'Mobile horizontal overflow: '+path);
      for (const screenshot of await page.locator('.release-screenshot img').all()) { await screenshot.scrollIntoViewIfNeeded(); await screenshot.evaluate(image => image.decode()); }
      await page.evaluate(()=>window.scrollTo(0,0));
      await page.screenshot({path:'artifacts/verification/'+(path==='/'?'website-mobile':'release-notes-mobile')+'.png',fullPage:true});
    }
    const download=await page.request.get('http://127.0.0.1:8105/Retriever.dmg');
    assert.equal(download.status(),200);
    const bytes=await download.body();
    assert.equal(bytes.length,manifest.bytes);
    assert.equal(require('node:crypto').createHash('sha256').update(bytes).digest('hex'),manifest.sha256);
    fs.writeFileSync('.build/web-audit/downloaded-Retriever.dmg',bytes);
    assert.equal(require('node:crypto').createHash('sha256').update(fs.readFileSync('.build/web-audit/clicked-Retriever.dmg')).digest('hex'),manifest.sha256);
    for (const response of [
      {json:{...manifest,version:'0.1.0',build:'2'}},
      {status:404,body:''},
      {json:{invalid:true}}
    ]) {
      await page.route('**/release.json', route=>route.fulfill(response));
      for (const path of ['/', '/release-notes.html']) {
        await page.goto('http://127.0.0.1:8105'+path,{waitUntil:'networkidle'});
        assert.equal(await page.locator('[data-download]').first().isVisible(),true);
        assert.equal(await page.locator('[data-download]').first().getAttribute('href'),'Retriever.dmg');
      }
      await page.unroute('**/release.json');
    }
    const noScript = await browser.newContext({javaScriptEnabled:false});
    const plainPage = await noScript.newPage();
    for (const path of ['/', '/release-notes.html']) {
      await plainPage.goto('http://127.0.0.1:8105'+path);
      assert.equal(await plainPage.locator('[data-download]').first().isVisible(),true);
      assert.equal(await plainPage.locator('[data-download]').first().getAttribute('href'),'Retriever.dmg');
    }
    const [plainDownload] = await Promise.all([plainPage.waitForEvent('download'), plainPage.locator('[data-download]').first().click()]);
    assert.equal(plainDownload.suggestedFilename(),'Retriever.dmg');
    await noScript.close();
    assert.deepEqual(errors,[]);
    console.log('PASS: desktop/mobile layouts, screenshots, Sep 29 release date, direct downloads with old/missing/invalid metadata and JavaScript disabled, and artifact checksum.');
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});
