import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

const run = promisify(execFile)

async function osascript(script) {
  try {
    const { stdout } = await run('osascript', ['-e', script], { timeout: 4000 })
    return stdout.trim()
  } catch {
    return ''
  }
}

// Real web pages only — and never our own UI tab.
const isWebUrl = (u) => /^https?:\/\//.test(u) && !/^https?:\/\/(localhost|127\.0\.0\.1):7777/.test(u)

// Chromium-family browsers share the same AppleScript dictionary.
const CHROMIUM = ['Google Chrome', 'Brave Browser', 'Arc', 'Microsoft Edge']
const BROWSERS = [...CHROMIUM, 'Safari']

// Active tab (url + title) of every window of a browser, front-to-back.
// The front window can be junk (about:blank, devtools, an extension popup),
// so we return ALL candidates and let the capture pick the right one.
async function browserTabCandidates(name) {
  if (name === 'Safari') {
    const out = await osascript(
      `tell application "Safari" to return (URL of front document) & "\n" & (name of front document)`,
    )
    const [url = '', title = ''] = out.split('\n')
    return isWebUrl(url) ? [{ browser: name, url, title, active: true }] : []
  }
  // Every tab of every window, with the active ones marked: when the OCR
  // names a site the user may have already switched tabs, so the right tab
  // can be a background one.
  const out = await osascript(
    `set output to ""
     tell application "${name}"
       repeat with w in windows
         try
           set a to active tab of w
           set output to output & "A|" & (URL of a) & linefeed & (title of a) & linefeed & "---" & linefeed
         end try
         try
           repeat with t in tabs of w
             set output to output & "T|" & (URL of t) & linefeed & (title of t) & linefeed & "---" & linefeed
           end repeat
         end try
       end repeat
     end tell
     return output`,
  )
  const active = []
  const rest = []
  const seen = new Set()
  for (const entry of out.split('---')) {
    const lines = entry.trim().split('\n')
    if (!lines[0]) continue
    const isActive = lines[0].startsWith('A|')
    const url = lines[0].slice(2)
    const title = lines[1] || ''
    if (!isWebUrl(url) || seen.has(url)) continue
    seen.add(url)
    ;(isActive ? active : rest).push({ browser: name, url, title, active: isActive })
  }
  return [...active, ...rest]
}

// Ask every RUNNING browser for its active tab — catches the case where a
// video plays full-screen or the browser sits behind the frontmost app.
// Candidate tabs from every running browser (frontmost browser first).
async function allTabCandidates(frontmostApp) {
  const procs = await osascript('tell application "System Events" to get name of every application process')
  const order = [frontmostApp, ...BROWSERS.filter((b) => b !== frontmostApp)]
  const tabs = []
  for (const name of order) {
    if (!BROWSERS.includes(name) || !procs.includes(name)) continue
    tabs.push(...(await browserTabCandidates(name)))
  }
  return tabs
}

// What's playing in the Spotify desktop app right now (fully local,
// works even when Spotify is in the background).
async function spotifyNowPlaying() {
  const out = await osascript(
    `tell application "System Events"
       if not (exists process "Spotify") then return ""
     end tell
     tell application "Spotify"
       if player state is playing then
         return name of current track & " — " & artist of current track & " — " & album of current track
       end if
       return ""
     end tell`,
  )
  return out
}

// Snapshot of what the user is doing right now: frontmost app,
// its window title, the browser URL when the app is a browser,
// and whatever Spotify is playing.
export async function currentContext() {
  const app = await osascript(
    'tell application "System Events" to get name of first application process whose frontmost is true',
  )
  const [sysTitle, tabCandidates, nowPlaying] = await Promise.all([
    app
      ? osascript(
          `tell application "System Events" to tell (first application process whose frontmost is true) to try
             get name of front window
           on error
             return ""
           end try`,
        )
      : '',
    allTabCandidates(app),
    spotifyNowPlaying(),
  ])
  const isBrowser = BROWSERS.includes(app)
  return {
    app: app || 'Unknown',
    windowTitle: (isBrowser && tabCandidates[0]?.title) || sysTitle,
    // Best guess before OCR: frontmost browser's front-window tab.
    url: isBrowser ? tabCandidates[0]?.url || '' : '',
    nowPlaying,
    tabCandidates,
  }
}
