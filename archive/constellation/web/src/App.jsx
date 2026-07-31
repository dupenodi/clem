import { useEffect, useState, useCallback } from 'react'
import Graph from './views/Graph.jsx'
import Oracle from './views/Oracle.jsx'
import Compass from './views/Compass.jsx'
import { getHealth, capture } from './api.js'

const TABS = [
  { id: 'graph', label: '✦ Graph' },
  { id: 'oracle', label: '◉ Oracle' },
  { id: 'compass', label: '☄ Compass' },
]

export default function App() {
  const [tab, setTab] = useState('graph')
  const [health, setHealth] = useState(null)
  const [capturing, setCapturing] = useState(false)
  const [toast, setToast] = useState(null)
  const [refreshKey, setRefreshKey] = useState(0)

  useEffect(() => {
    const poll = () => getHealth().then(setHealth).catch(() => setHealth(null))
    poll()
    const t = setInterval(poll, 15000)
    return () => clearInterval(t)
  }, [])

  const showToast = useCallback((msg) => {
    setToast(msg)
    setTimeout(() => setToast(null), 3500)
  }, [])

  const doCapture = useCallback(
    async (mode) => {
      setCapturing(true)
      try {
        const m = await capture(mode)
        showToast(`✦ Captured ${m.app}${m.windowTitle ? ` — ${m.windowTitle}` : ''}`)
        // give ingestion a head start, then refresh views
        setTimeout(() => setRefreshKey((k) => k + 1), 4000)
      } catch (err) {
        showToast(`Capture failed: ${err.message}`)
      } finally {
        setCapturing(false)
      }
    },
    [showToast],
  )

  useEffect(() => {
    const onKey = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key.toLowerCase() === 'm') {
        e.preventDefault()
        doCapture('screen')
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [doCapture])

  const up = health?.supermemory

  return (
    <div className="app">
      <div className="starfield" />
      <header className="topbar">
        <div className="brand">
          <span className="spark">✦</span> CONSTELLATION
        </div>
        <nav className="tabs">
          {TABS.map((t) => (
            <button key={t.id} className={`tab ${tab === t.id ? 'active' : ''}`} onClick={() => setTab(t.id)}>
              {t.label}
            </button>
          ))}
        </nav>
        <div className="topbar-right">
          <div className="health" title={`engine ${up ? 'online' : 'offline'} · oracle ${health?.ollama ? 'online' : 'offline'}`}>
            <span className={`dot ${up ? 'up' : ''}`} />
            {up ? 'engine online' : 'engine offline'}
          </div>
          <button className="capture-btn" disabled={capturing || !up} onClick={() => doCapture('screen')}>
            {capturing ? 'Capturing…' : '⌘⇧M Capture this moment'}
          </button>
        </div>
      </header>
      <main className="main">
        {tab === 'graph' && <Graph refreshKey={refreshKey} />}
        {tab === 'oracle' && <Oracle />}
        {tab === 'compass' && <Compass refreshKey={refreshKey} />}
      </main>
      {toast && <div className="toast panel">{toast}</div>}
    </div>
  )
}
