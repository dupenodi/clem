import { useRef, useState } from 'react'
import { ask } from '../api.js'

const SUGGESTIONS = [
  'What was I working on yesterday?',
  'What have I been reading about lately?',
  'Show me everything about my current project',
  'What did I capture in Figma?',
]

export default function Oracle() {
  const [q, setQ] = useState('')
  const [answer, setAnswer] = useState('')
  const [sources, setSources] = useState([])
  const [busy, setBusy] = useState(false)
  const inputRef = useRef(null)

  const submit = async (question) => {
    const query = (question ?? q).trim()
    if (!query || busy) return
    setQ(query)
    setBusy(true)
    setAnswer('')
    setSources([])
    await ask(query, {
      onSources: setSources,
      onToken: (t) => setAnswer((a) => a + t),
      onError: (e) => setAnswer((a) => a + `\n\n⚠ ${e.message}`),
    })
    setBusy(false)
  }

  return (
    <div className="oracle">
      <div className="oracle-inner">
        <h1 className="oracle-title">Ask your memory</h1>
        <p className="oracle-sub">Answers come from your captures only — retrieved locally, synthesized locally.</p>

        <form
          className="ask-box panel"
          onSubmit={(e) => {
            e.preventDefault()
            submit()
          }}
        >
          <input
            ref={inputRef}
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="What was that thing I saw…"
            autoFocus
          />
          <button type="submit" disabled={busy || !q.trim()}>
            {busy ? 'Consulting…' : 'Ask'}
          </button>
        </form>

        {!answer && !busy && (
          <div className="suggestions">
            {SUGGESTIONS.map((s) => (
              <button key={s} onClick={() => submit(s)}>
                {s}
              </button>
            ))}
          </div>
        )}

        {(answer || busy) && (
          <div className="answer panel">
            {answer}
            {busy && <span className="cursor" />}
          </div>
        )}

        {sources.length > 0 && (
          <>
            <p className="oracle-sub" style={{ textAlign: 'left' }}>
              from {sources.length} {sources.length === 1 ? 'memory' : 'memories'}
            </p>
            <div className="sources">
              {sources.map((s, i) => {
                const meta = s.metadata || {}
                return (
                  <div className="source-card panel" key={s.documentId || i}>
                    {meta.file && <img src={`/captures/${meta.file}`} alt="" loading="lazy" />}
                    <div>
                      <span className="n">[{i + 1}]</span>
                      {(s.title || meta.windowTitle || 'memory').slice(0, 70)}
                    </div>
                    <div style={{ color: 'var(--ink-3)', marginTop: 4 }}>
                      {meta.app || ''}
                      {meta.capturedAt ? ` · ${new Date(meta.capturedAt).toLocaleDateString()}` : ''}
                    </div>
                  </div>
                )
              })}
            </div>
          </>
        )}
      </div>
    </div>
  )
}
