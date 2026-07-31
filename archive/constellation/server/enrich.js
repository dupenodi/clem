// Enrich a capture from its tab URL — richer signal than OCR ever gives.
// All calls fail soft: offline or blocked, the capture still works.

const FETCH_OPTS = {
  headers: { 'User-Agent': 'Mozilla/5.0 (Macintosh) Clem/1.0' },
  signal: AbortSignal.timeout(5000),
  redirect: 'follow',
}

function isYouTube(url) {
  return /(?:youtube\.com\/watch|youtu\.be\/|youtube\.com\/shorts)/.test(url)
}

// Extract a JSON object that follows `marker` in a blob of HTML by
// counting braces (regexes can't match nested JSON reliably).
function extractJson(html, marker) {
  const start = html.indexOf(marker)
  if (start === -1) return null
  const open = html.indexOf('{', start)
  if (open === -1) return null
  let depth = 0
  let inStr = false
  let esc = false
  for (let i = open; i < html.length; i++) {
    const c = html[i]
    if (esc) { esc = false; continue }
    if (c === '\\') { esc = true; continue }
    if (c === '"') inStr = !inStr
    if (inStr) continue
    if (c === '{') depth++
    if (c === '}' && --depth === 0) {
      try {
        return JSON.parse(html.slice(open, i + 1))
      } catch {
        return null
      }
    }
  }
  return null
}

function decodeEntities(s) {
  return s
    .replace(/&amp;/g, '&')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
}

async function youtubeInfo(url) {
  // Rich path: parse the watch page's player JSON — description, length,
  // and the caption transcript when the video has one.
  try {
    const res = await fetch(url, { ...FETCH_OPTS, headers: { ...FETCH_OPTS.headers, Cookie: 'CONSENT=YES+1' } })
    if (res.ok) {
      const html = await res.text()
      const pr = extractJson(html, 'ytInitialPlayerResponse')
      const vd = pr?.videoDetails
      if (vd?.title) {
        const mins = Math.round((Number(vd.lengthSeconds) || 0) / 60)
        const desc = (vd.shortDescription || '').replace(/\s+/g, ' ').trim().slice(0, 900)
        let transcript = ''
        const track = pr.captions?.playerCaptionsTracklistRenderer?.captionTracks?.[0]
        if (track?.baseUrl) {
          const tr = await fetch(track.baseUrl, FETCH_OPTS).catch(() => null)
          if (tr?.ok) {
            transcript = decodeEntities(
              [...(await tr.text()).matchAll(/<text[^>]*>([\s\S]*?)<\/text>/g)].map((m) => m[1]).join(' '),
            )
              .replace(/\s+/g, ' ')
              .slice(0, 6000)
          }
        }
        return {
          kind: 'video',
          title: vd.title,
          author: vd.author,
          line: `Watching YouTube video "${vd.title}" by ${vd.author}${mins ? ` (${mins} min)` : ''}`,
          detail:
            [desc && `Video description: ${desc}`, transcript && `Transcript excerpt: ${transcript}`]
              .filter(Boolean)
              .join('\n') || undefined,
        }
      }
    }
  } catch {
    /* fall through to oEmbed */
  }
  const res = await fetch(`https://www.youtube.com/oembed?format=json&url=${encodeURIComponent(url)}`, FETCH_OPTS)
  if (!res.ok) return null
  const { title, author_name } = await res.json()
  return { kind: 'video', line: `Watching YouTube video "${title}" by ${author_name}`, title, author: author_name }
}

function stripHtml(html) {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<nav[\s\S]*?<\/nav>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&(nbsp|amp|quot|#39|lt|gt);/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}

async function articleInfo(url) {
  const res = await fetch(url, FETCH_OPTS)
  const type = res.headers.get('content-type') || ''
  if (!res.ok || !type.includes('html')) return null
  const html = (await res.text()).slice(0, 400000)
  const title = (html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1] || '').trim().slice(0, 150)
  const og = (m) => html.match(new RegExp(`<meta[^>]+property=["']og:${m}["'][^>]+content=["']([^"']+)`, 'i'))?.[1]
  const description = og('description') || ''
  // Prefer the <article> body when the page has one; fall back to og:description.
  const articleHtml = html.match(/<article[\s\S]*?<\/article>/i)?.[0] || ''
  const body = stripHtml(articleHtml).slice(0, 1200)
  const text = [description, body].filter(Boolean).join(' ')
  if (!title && !text) return null
  return { kind: 'article', line: `Reading "${title || url}"${text ? ` — ${text.slice(0, 900)}` : ''}`, title }
}

// Returns { line, kind, title } or null. `line` feeds the narration prompt.
export async function enrichFromUrl(url) {
  if (!url || !/^https?:/.test(url)) return null
  try {
    if (isYouTube(url)) return await youtubeInfo(url)
    return await articleInfo(url)
  } catch {
    return null
  }
}
