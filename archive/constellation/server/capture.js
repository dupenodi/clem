import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { mkdir, copyFile, stat, writeFile } from 'node:fs/promises'
import { watch, existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { CAPTURES_DIR, HOME } from './config.js'
import { currentContext } from './context.js'
import { addText } from './supermemory.js'
import { chat } from './ollama.js'
import { enrichFromUrl } from './enrich.js'

const run = promisify(execFile)
const OCR_SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)), 'ocr.jxa')

// On-device OCR via Apple Vision (see ocr.jxa). The engine's file-upload
// bucket is broken in v0.0.3, and local OCR is better anyway: we ingest
// screenshots as rich text documents the memory agent can actually chew on.
async function ocr(file) {
  try {
    const { stdout } = await run('osascript', ['-l', 'JavaScript', OCR_SCRIPT, file], {
      timeout: 45000,
      maxBuffer: 10 * 1024 * 1024,
    })
    return stdout.trim()
  } catch {
    return ''
  }
}

function stamp() {
  return new Date().toISOString().replace(/[:.]/g, '-')
}

function buildMetadata(ctx, source) {
  const now = new Date()
  const local = new Date(now.getTime() - now.getTimezoneOffset() * 60000)
  const meta = {
    kind: 'screenshot',
    source, // 'hotkey' | 'watcher' | 'ui'
    app: ctx.app,
    capturedAt: now.toISOString(),
    dayKey: local.toISOString().slice(0, 10),
    hour: now.getHours(),
  }
  if (ctx.windowTitle) meta.windowTitle = ctx.windowTitle.slice(0, 200)
  if (ctx.url) meta.url = ctx.url.slice(0, 500)
  if (ctx.nowPlaying) meta.nowPlaying = ctx.nowPlaying.slice(0, 200)
  return meta
}

// The engine's memory agent extracts facts from prose but returns nothing
// for raw UI text, so a local model first narrates what the screen shows.
async function narrate(header, text) {
  try {
    return await chat([
      {
        role: 'system',
        content:
          'You turn a captured moment (screenshot OCR plus page/video/music context) into the user\'s memory of it. Write 2-6 first-person sentences ("I was...") stating what the user was doing and consuming. When a video description or transcript is provided, summarize what the video is actually about in 1-2 of those sentences. STRICT RULE: state only details that literally appear in the provided context or OCR text — never invent titles, names, people, topics, or events. If the context is thin (e.g. a full-screen video with no readable text), write 1-2 honest generic sentences instead. Plain prose, no preamble, no markdown.',
      },
      { role: 'user', content: `${header}\n\nOCR text from the screen:\n${text.slice(0, 3500)}` },
    ])
  } catch {
    return ''
  }
}

// Pick the tab the screen actually shows: the OCR text usually contains the
// site's hostname or the page/video title — match candidates against it.
// Falls back to the frontmost browser's front tab.
function pickTab(ctx, ocrText) {
  const cands = ctx.tabCandidates || []
  if (!cands.length) return null
  const ocr = (ocrText || '').toLowerCase()
  if (ocr) {
    const ocrFlat = ocr.replace(/\s+/g, '')

    // 1. Exact URL-path evidence: the address bar in the screenshot shows a
    //    distinctive path segment (e.g. "p-197749849") — unambiguous.
    const pathMatch = cands.find((c) => {
      try {
        const segs = new URL(c.url).pathname.toLowerCase().split('/').filter((s) => s.length >= 6)
        return segs.some((s) => ocrFlat.includes(s))
      } catch {
        return false
      }
    })
    if (pathMatch) return pathMatch

    // 2. Hostname seen on screen; active tabs win ties.
    const seenHosts = new Set(
      [...ocr.matchAll(/(?:[a-z0-9-]+\.)+[a-z]{2,6}/g)].map((m) => m[0].replace(/^www\./, '')),
    )
    const hostMatches = cands.filter((c) => {
      try {
        return seenHosts.has(new URL(c.url).hostname.replace(/^www\./, ''))
      } catch {
        return false
      }
    })
    if (hostMatches.length) return hostMatches.find((c) => c.active) || hostMatches[0]

    // 3. Tab title words visible on screen.
    const titleMatch = cands
      .map((c) => {
        const words = (c.title || '').toLowerCase().split(/\W+/).filter((w) => w.length >= 4)
        const hits = words.filter((w) => ocr.includes(w)).length
        return { c, hits, ratio: words.length ? hits / words.length : 0 }
      })
      .filter((x) => x.hits >= 2 && x.ratio >= 0.4)
      .sort((a, b) => b.ratio - a.ratio || (b.c.active ? 1 : 0) - (a.c.active ? 1 : 0))[0]
    if (titleMatch) return titleMatch.c
  }
  // No OCR evidence: only trust the tab when the browser was frontmost.
  return ctx.url ? cands[0] : null
}

async function ingest(file, ctx, source) {
  const text = await ocr(file)
  const tab = pickTab(ctx, text)
  if (tab) {
    ctx = { ...ctx, url: tab.url, windowTitle: tab.title || ctx.windowTitle }
  }
  const meta = buildMetadata(ctx, source)
  meta.file = path.basename(file)
  meta.ref = meta.file // unique (ms timestamp) — lets search results map back to docs
  // Full OCR text kept as a local sidecar for the UI; only the narrative
  // goes to the engine (keeps docs at 1 chunk, which its agent handles).
  if (text) await writeFile(`${file}.txt`, text).catch(() => {})

  const enriched = ctx.url ? await enrichFromUrl(ctx.url) : null
  const header = [
    `Screenshot of ${ctx.app}`,
    ctx.windowTitle ? `Window: ${ctx.windowTitle}` : '',
    ctx.url ? `URL: ${ctx.url}` : '',
    enriched ? `Page context: ${enriched.line}` : '',
    ctx.nowPlaying ? `Now playing on Spotify: ${ctx.nowPlaying}` : '',
    `Captured: ${meta.capturedAt}`,
  ]
    .filter(Boolean)
    .join('\n')
  // Rich detail (video description/transcript) informs the narration only —
  // the stored document stays short so the memory agent handles it in 1 chunk.
  const narrationContext = enriched?.detail ? `${header}\n\n${enriched.detail}` : header

  const story = text || enriched || ctx.nowPlaying ? await narrate(narrationContext, text) : ''
  const content = story
    ? `${story}\n\n${header}`
    : `${header}\n\n${text ? `On-screen text:\n${text.slice(0, 1500)}` : '(No readable on-screen text — visual content only.)'}`
  const doc = await addText(content, meta)
  return { id: doc.id, status: doc.status, ...meta, ocrChars: text.length, narrated: Boolean(story) }
}

// Take a screenshot right now. mode: 'screen' (whole display, silent),
// 'window' (frontmost window), or 'selection' (interactive crosshair).
export async function captureNow(mode = 'screen') {
  await mkdir(CAPTURES_DIR, { recursive: true })
  // Grab context BEFORE the interactive modes steal focus.
  const ctx = await currentContext()
  const file = path.join(CAPTURES_DIR, `capture-${stamp()}.png`)

  const args = { screen: ['-x'], selection: ['-i'], window: ['-i', '-o', '-J', 'window'] }[mode] || ['-x']
  await run('screencapture', [...args, file], { timeout: 60000 })
  if (!existsSync(file)) throw new Error('capture cancelled')
  const { size } = await stat(file)
  if (size === 0) throw new Error('capture produced empty file')

  return ingest(file, ctx, 'hotkey')
}

// Where macOS saves ⌘⇧3/⌘⇧4 screenshots.
async function screenshotsDir() {
  try {
    const { stdout } = await run('defaults', ['read', 'com.apple.screencapture', 'location'])
    const dir = stdout.trim().replace(/^~/, HOME)
    if (dir && existsSync(dir)) return dir
  } catch {
    /* default location */
  }
  return path.join(HOME, 'Desktop')
}

// Watch the native screenshots folder: any screenshot the user takes
// with ⌘⇧3/⌘⇧4 becomes a memory automatically.
export async function startWatcher(onCapture) {
  const dir = await screenshotsDir()
  const seen = new Set()
  watch(dir, async (event, filename) => {
    if (!filename || seen.has(filename)) return
    if (!/^(Screenshot|Screen Shot).*\.png$/i.test(filename)) return
    seen.add(filename)
    setTimeout(() => seen.delete(filename), 15000)
    // Grab context NOW — the user may switch tabs within seconds of ⌘⇧3,
    // and the tab list must reflect the moment of the screenshot.
    const ctxPromise = currentContext().catch(() => ({ app: 'Unknown', tabCandidates: [] }))
    // Give macOS a moment to finish writing (it renames from a dotfile).
    await new Promise((r) => setTimeout(r, 1500))
    const src = path.join(dir, filename)
    if (!existsSync(src)) return
    try {
      const ctx = await ctxPromise
      await mkdir(CAPTURES_DIR, { recursive: true })
      const local = path.join(CAPTURES_DIR, `native-${stamp()}.png`)
      await copyFile(src, local)
      const memory = await ingest(local, ctx, 'watcher')
      onCapture?.(memory)
    } catch (err) {
      console.error('[watcher] ingest failed:', err.message)
    }
  })
  console.log(`[watcher] watching ${dir} for native screenshots`)
  return dir
}
