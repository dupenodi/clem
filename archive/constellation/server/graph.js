import { mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { CACHE_DIR } from './config.js'
import { listAllDocuments, search } from './supermemory.js'

const CACHE_FILE = path.join(CACHE_DIR, 'edges.json')

async function loadCache() {
  try {
    return JSON.parse(await readFile(CACHE_FILE, 'utf8'))
  } catch {
    return {}
  }
}

async function saveCache(cache) {
  await mkdir(CACHE_DIR, { recursive: true })
  await writeFile(CACHE_FILE, JSON.stringify(cache))
}

function queryTextFor(doc) {
  return [doc.title, doc.summary, doc.metadata?.windowTitle, doc.metadata?.app]
    .filter(Boolean)
    .join(' — ')
    .slice(0, 400)
}

// Semantic edges: each doc's content queried against the rest of the
// memory via /v4/search. Cached per (doc id, updatedAt) so we only pay
// for new or changed documents. Zero LLM involvement.
export async function buildGraph() {
  const docs = await listAllDocuments()
  const byId = new Map(docs.map((d) => [d.id, d]))
  // Search results are memory-level and carry the parent doc's metadata,
  // so we resolve them to documents through the metadata.ref we set at ingest.
  const byRef = new Map(docs.filter((d) => d.metadata?.ref).map((d) => [d.metadata.ref, d.id]))
  const cache = await loadCache()
  let cacheDirty = false

  for (const doc of docs) {
    const key = `${doc.id}:${doc.updatedAt}`
    if (cache[key]) continue
    const q = queryTextFor(doc)
    if (!q) {
      cache[key] = []
      cacheDirty = true
      continue
    }
    try {
      const res = await search(q, { limit: 8, threshold: 0.4 })
      const neighbors = []
      const seen = new Set()
      for (const r of res.results || []) {
        const id = byRef.get(r.metadata?.ref)
        if (!id || id === doc.id || seen.has(id)) continue
        seen.add(id)
        neighbors.push({ id, score: r.similarity ?? r.score ?? 0.5 })
        if (neighbors.length >= 4) break
      }
      cache[key] = neighbors
      cacheDirty = true
    } catch {
      /* engine busy — retry next build */
    }
  }
  if (cacheDirty) await saveCache(cache)

  const edgeKey = (a, b) => (a < b ? `${a}|${b}` : `${b}|${a}`)
  const edges = new Map()
  for (const doc of docs) {
    for (const n of cache[`${doc.id}:${doc.updatedAt}`] || []) {
      if (!byId.has(n.id)) continue
      const k = edgeKey(doc.id, n.id)
      const prev = edges.get(k)
      if (!prev || n.score > prev.score) edges.set(k, { score: n.score })
    }
  }

  return {
    nodes: docs.map((d) => ({
      id: d.id,
      title: d.title || d.metadata?.windowTitle || d.metadata?.window_title || 'Untitled',
      summary: d.summary,
      app: d.metadata?.app_name || d.metadata?.app || 'note',
      kind: d.metadata?.source === 'screen-capture' ? 'clem' : d.metadata?.kind || d.type || 'text',
      url: d.metadata?.url || d.url || null,
      file: d.metadata?.file || null,
      thumb: d.metadata?.thumb || null,
      status: d.status,
      createdAt: d.metadata?.captured_at || d.createdAt,
    })),
    links: [...edges.entries()].map(([k, v]) => {
      const [source, target] = k.split('|')
      return { source, target, score: v.score }
    }),
  }
}
