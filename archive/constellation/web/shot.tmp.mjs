import { chromium } from 'playwright'

const OUT = process.env.OUT || '/tmp/ui'
const browser = await chromium.launch()
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })
await page.emulateMedia({ colorScheme: 'dark' })
await page.goto('http://localhost:7777', { waitUntil: 'networkidle' })
await page.waitForTimeout(2500)
await page.screenshot({ path: `${OUT}-clem.png` })

await page.click('text=Oracle')
await page.waitForTimeout(600)
await page.screenshot({ path: `${OUT}-oracle.png` })

await page.click('text=Compass')
await page.waitForTimeout(1200)
await page.screenshot({ path: `${OUT}-compass.png` })

await browser.close()
console.log('done')
