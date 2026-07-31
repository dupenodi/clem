import { SUPERMEMORY_URL, CONTAINER_TAG } from './config.js'

// Localhost requests are auto-authenticated by supermemory-server,
// so no bearer token is needed here.

async function api(route, { method = 'POST', body, headers = {} } = {}) {
  const res = await fetch(`${SUPERMEMORY_URL}${route}`, {
    method,
    headers: body instanceof FormData ? headers : { 'Content-Type': 'application/json', ...headers },
    body: body instanceof FormData ? body : body !== undefined ? JSON.stringify(body) : undefined,
  })
  if (!res.ok) {
    const text = await res.text().catch(() => '')
    throw new Error(`supermemory ${method} ${route} → ${res.status}: ${text.slice(0, 300)}`)
  }
  return res.json()
}

export function addText(content, metadata = {}) {
  // Every doc gets a unique ref so memory-level search results can be
  // resolved back to their parent document (used by the graph builder).
  if (!metadata.ref) metadata = { ...metadata, ref: `note-${Date.now()}-${Math.round(Math.random() * 1e6)}` }
  return api('/v3/documents', { body: { content, containerTag: CONTAINER_TAG, metadata } })
}

export function getDocument(id) {
  return api(`/v3/documents/${id}`, { method: 'GET' })
}

// One sky, two clems: deliberate captures + Clem's passive
// screen memories live in separate containers but are shown together.
export const ALL_TAGS = [CONTAINER_TAG, 'clem']

export async function listAllDocuments() {
  const all = []
  let page = 1
  while (true) {
    const res = await api('/v3/documents/list', {
      body: { containerTags: ALL_TAGS, limit: 100, page, sort: 'createdAt', order: 'desc' },
    })
    all.push(...(res.memories || []))
    const { totalPages = 1, currentPage = page } = res.pagination || {}
    if (currentPage >= totalPages) break
    page = currentPage + 1
  }
  return all
}

// v4/search only accepts a single containerTag — search each and merge.
export async function search(q, { limit = 8, threshold = 0.35, rerank = false } = {}) {
  const perTag = await Promise.all(
    ALL_TAGS.map((tag) =>
      api('/v4/search', { body: { q, containerTag: tag, limit, threshold, rerank } }).catch(() => ({ results: [] })),
    ),
  )
  const results = perTag
    .flatMap((r) => r.results || [])
    .sort((a, b) => (b.similarity ?? 0) - (a.similarity ?? 0))
    .slice(0, limit)
  return { results, total: results.length }
}

export function deleteDocument(id) {
  return api(`/v3/documents/${id}`, { method: 'DELETE' })
}

export async function health() {
  try {
    const res = await fetch(`${SUPERMEMORY_URL}/`, { signal: AbortSignal.timeout(3000) })
    return res.status < 500
  } catch {
    return false
  }
}
