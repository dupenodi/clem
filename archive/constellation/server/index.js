import express from 'express'
import path from 'node:path'
import { existsSync } from 'node:fs'
import { PORT, ROOT, CAPTURES_DIR, ORACLE_MODEL } from './config.js'
import { captureNow, startWatcher } from './capture.js'
import { listAllDocuments, search, health as smHealth, getDocument, deleteDocument } from './supermemory.js'
import { buildGraph } from './graph.js'
import { ollamaHealth, streamChat } from './ollama.js'

const app = express()
app.use(express.json())

// ---- health ----------------------------------------------------------
app.get('/api/health', async (_req, res) => {
  const [sm, ollama] = await Promise.all([smHealth(), ollamaHealth()])
  res.json({ supermemory: sm, ollama: ollama.up, models: ollama.models, oracleModel: ORACLE_MODEL })
})

// ---- capture ---------------------------------------------------------
app.post('/api/capture', async (req, res) => {
  try {
    const memory = await captureNow(req.body?.mode || 'screen')
    res.json(memory)
  } catch (err) {
    res.status(400).json({ error: err.message })
  }
})

// ---- memories & graph ------------------------------------------------
app.get('/api/memories', async (_req, res) => {
  try {
    res.json(await listAllDocuments())
  } catch (err) {
    res.status(502).json({ error: err.message })
  }
})

app.get('/api/memories/:id', async (req, res) => {
  try {
    res.json(await getDocument(req.params.id))
  } catch (err) {
    res.status(404).json({ error: err.message })
  }
})

app.delete('/api/memories/:id', async (req, res) => {
  try {
    res.json(await deleteDocument(req.params.id))
  } catch (err) {
    res.status(502).json({ error: err.message })
  }
})

app.get('/api/graph', async (_req, res) => {
  try {
    res.json(await buildGraph())
  } catch (err) {
    res.status(502).json({ error: err.message })
  }
})

// ---- stats for the Compass (plain aggregation, zero LLM) --------------
app.get('/api/stats', async (_req, res) => {
  try {
    const docs = await listAllDocuments()
    const days = {}
    const apps = {}
    for (const d of docs) {
      const day = d.metadata?.dayKey || (d.createdAt || '').slice(0, 10)
      const appName = d.metadata?.app || 'note'
      if (day) {
        days[day] ??= { total: 0, apps: {} }
        days[day].total++
        days[day].apps[appName] = (days[day].apps[appName] || 0) + 1
      }
      apps[appName] = (apps[appName] || 0) + 1
    }
    res.json({ totalMemories: docs.length, days, apps })
  } catch (err) {
    res.status(502).json({ error: err.message })
  }
})

// ---- search & oracle ---------------------------------------------------
app.post('/api/search', async (req, res) => {
  try {
    res.json(await search(req.body.q, { limit: 10, threshold: 0.3 }))
  } catch (err) {
    res.status(502).json({ error: err.message })
  }
})

// SSE: retrieval-first ask. The model only ever sees the top hits.
app.post('/api/ask', async (req, res) => {
  const q = (req.body?.q || '').trim()
  if (!q) return res.status(400).json({ error: 'missing q' })

  res.setHeader('Content-Type', 'text/event-stream')
  res.setHeader('Cache-Control', 'no-cache')
  const send = (event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`)

  try {
    const found = await search(q, { limit: 6, threshold: 0.25 })
    const results = found.results || []
    send('sources', results)

    if (results.length === 0) {
      send('token', "I couldn't find any memories related to that yet. Capture more moments and ask again.")
      send('done', {})
      return res.end()
    }

    const context = results
      .map((r, i) => {
        const meta = r.metadata || {}
        const when = meta.capturedAt || r.createdAt || ''
        const where = [meta.app, meta.windowTitle, meta.url].filter(Boolean).join(' · ')
        const text = r.memory || (r.chunks || []).map((c) => c.content).join('\n') || r.summary || r.title || ''
        return `[${i + 1}] (${when}) ${where}\n${String(text).slice(0, 700)}`
      })
      .join('\n\n')

    const messages = [
      {
        role: 'system',
        content:
          "You are Clem, the user's local memory companion. Answer their question conversationally, in your own words — synthesize the relevant memories into a natural reply instead of reciting them. Cite specific facts inline as [1], [2]. Ignore irrelevant memories. If the memories genuinely don't contain the answer, say so briefly.",
      },
      { role: 'user', content: `My memories:\n\n${context}\n\nQuestion: ${q}` },
    ]
    await streamChat(messages, (token) => send('token', token))
    send('done', {})
  } catch (err) {
    send('error', { message: err.message })
  }
  res.end()
})

// ---- static ------------------------------------------------------------
app.use('/captures', express.static(CAPTURES_DIR))
app.use(
  '/clem-thumbs',
  express.static(path.join(process.env.HOME || '', 'Library/Application Support/Clem/thumbs')),
)
const dist = path.join(ROOT, 'web', 'dist')
if (existsSync(dist)) {
  app.use(express.static(dist))
  app.get(/^\/(?!api|captures).*/, (_req, res) => res.sendFile(path.join(dist, 'index.html')))
}

app.listen(PORT, '127.0.0.1', () => {
  console.log(`✦ Clem running → http://127.0.0.1:${PORT}`)
  startWatcher((m) => console.log(`[watcher] captured ${m.app} → ${m.id}`))
})
