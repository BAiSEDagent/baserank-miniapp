import { chromium } from 'playwright'
import fs from 'fs/promises'
import path from 'path'

const outDir = path.resolve('demo-recording')
await fs.mkdir(outDir, { recursive: true })

const browser = await chromium.launch({ headless: true })
const context = await browser.newContext({
  viewport: { width: 430, height: 932 },
  recordVideo: { dir: outDir, size: { width: 430, height: 932 } },
})

const page = await context.newPage()
await page.goto('https://baserank-miniapp.vercel.app/?demo=1', { waitUntil: 'networkidle' })

// Scroll leaderboard a bit
await page.mouse.wheel(0, 1200)
await page.waitForTimeout(700)
await page.mouse.wheel(0, -400)
await page.waitForTimeout(500)

// Tap an app card
await page.locator('button:has(h3)').first().click()
await page.waitForTimeout(500)

// Tap $50 chip
await page.locator('button', { hasText: '$50' }).first().click()
await page.waitForTimeout(300)

// Drag swipe thumb to the right
const thumb = page.locator('button', { hasText: '»' }).first()
const box = await thumb.boundingBox()
if (box) {
  const startX = box.x + box.width / 2
  const startY = box.y + box.height / 2
  await page.mouse.move(startX, startY)
  await page.mouse.down()
  await page.mouse.move(startX + 260, startY, { steps: 12 })
  await page.mouse.up()
}

// Let processing + confetti show
await page.waitForTimeout(3500)

await context.close()
await browser.close()

// Print latest video path
const files = await fs.readdir(outDir)
const webm = files.filter((f) => f.endsWith('.webm')).sort().pop()
if (webm) {
  console.log(path.join(outDir, webm))
}
