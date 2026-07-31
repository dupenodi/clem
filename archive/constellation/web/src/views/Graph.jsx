import { useEffect, useMemo, useRef, useState } from 'react'
import ForceGraph2D from 'react-force-graph-2d'
import { getGraph, getMemory, deleteMemory } from '../api.js'
import { makeAppColors, OTHER, INK } from '../palette.js'

function timeAgo(iso) {
  if (!iso) return ''
  const s = (Date.now() - new Date(iso)) / 1000
  if (s < 60) return 'just now'
  if (s < 3600) return `${Math.floor(s / 60)}m ago`
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`
  return `${Math.floor(s / 86400)}d ago`
}

export default function Graph({ refreshKey }) {
  const [data, setData] = useState({ nodes: [], links: [] })
  const [selected, setSelected] = useState(null)
  const [fullDoc, setFullDoc] = useState(null)

  const select = (node) => {
    setSelected(node)
    setFullDoc(null)
    if (node) getMemory(node.id).then(setFullDoc).catch(() => {})
  }
  const [size, setSize] = useState({ w: 800, h: 600 })
  const wrapRef = useRef(null)
  const fgRef = useRef(null)

  useEffect(() => {
    // Merge fetches into existing node objects: force-graph stores positions
    // on the node objects themselves, so replacing them restarts the physics
    // and stars drift mid-click. Reusing objects keeps the sky still.
    const load = () =>
      getGraph()
        .then((g) =>
          setData((prev) => {
            const prevById = new Map(prev.nodes.map((n) => [n.id, n]))
            return {
              nodes: g.nodes.map((n) => Object.assign(prevById.get(n.id) || {}, n)),
              links: g.links,
            }
          }),
        )
        .catch(() => {})
    load()
    const t = setInterval(load, 20000)
    return () => clearInterval(t)
  }, [refreshKey])

  useEffect(() => {
    const measure = () =>
      wrapRef.current && setSize({ w: wrapRef.current.clientWidth, h: wrapRef.current.clientHeight })
    measure()
    window.addEventListener('resize', measure)
    return () => window.removeEventListener('resize', measure)
  }, [])

  const appColors = useMemo(() => {
    const counts = {}
    for (const n of data.nodes) counts[n.app] = (counts[n.app] || 0) + 1
    return makeAppColors(counts)
  }, [data.nodes])

  const paintNode = (node, ctx, scale) => {
    if (!Number.isFinite(node.x) || !Number.isFinite(node.y)) return
    const color = appColors[node.app] || OTHER
    const r = node.id === selected?.id ? 7 : 4.5
    // glow
    const glow = ctx.createRadialGradient(node.x, node.y, 0, node.x, node.y, r * 4)
    glow.addColorStop(0, `${color}55`)
    glow.addColorStop(1, `${color}00`)
    ctx.fillStyle = glow
    ctx.beginPath()
    ctx.arc(node.x, node.y, r * 4, 0, 2 * Math.PI)
    ctx.fill()
    // core
    ctx.fillStyle = color
    ctx.beginPath()
    ctx.arc(node.x, node.y, r, 0, 2 * Math.PI)
    ctx.fill()
    ctx.strokeStyle = 'rgba(255,255,255,0.85)'
    ctx.lineWidth = 0.8
    ctx.stroke()
    // label when zoomed in or selected
    if (scale > 2.2 || node.id === selected?.id) {
      ctx.font = `${11 / scale}px system-ui, sans-serif`
      ctx.textAlign = 'center'
      ctx.fillStyle = INK.secondary
      const label = (node.title || '').slice(0, 42)
      ctx.fillText(label, node.x, node.y + r + 12 / scale)
    }
  }

  const remove = async (id) => {
    await deleteMemory(id).catch(() => {})
    setSelected(null)
    setData((d) => ({
      nodes: d.nodes.filter((n) => n.id !== id),
      links: d.links.filter((l) => (l.source.id || l.source) !== id && (l.target.id || l.target) !== id),
    }))
  }

  return (
    <div ref={wrapRef} style={{ position: 'absolute', inset: 0 }}>
      {data.nodes.length === 0 ? (
        <div className="empty-state">
          <div className="big">✦</div>
          <h2>Your sky is empty — for now</h2>
          <p>
            Press <kbd>⌘⇧M</kbd> here (or hit the capture button) to remember this moment. Every native macOS
            screenshot (<kbd>⌘⇧3</kbd>/<kbd>⌘⇧4</kbd>) becomes a star too. Related memories will link up into
            clems automatically.
          </p>
        </div>
      ) : (
        <ForceGraph2D
          ref={fgRef}
          width={size.w}
          height={size.h}
          graphData={data}
          backgroundColor="rgba(0,0,0,0)"
          nodeCanvasObject={paintNode}
          nodePointerAreaPaint={(node, color, ctx) => {
            if (!Number.isFinite(node.x) || !Number.isFinite(node.y)) return
            ctx.fillStyle = color
            ctx.beginPath()
            ctx.arc(node.x, node.y, 16, 0, 2 * Math.PI)
            ctx.fill()
          }}
          nodeLabel={(n) => `${n.title}\n${n.app} · ${timeAgo(n.createdAt)}`}
          linkColor={(l) => `rgba(122, 156, 229, ${0.15 + 0.5 * (l.score || 0.3)})`}
          linkWidth={(l) => 0.6 + 1.6 * (l.score || 0.3)}
          onNodeClick={select}
          onBackgroundClick={() => select(null)}
          cooldownTicks={120}
          d3VelocityDecay={0.25}
        />
      )}

      {selected && (
        <aside className="detail-panel panel">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
            <span className="chip" style={{ borderColor: appColors[selected.app] || OTHER, color: appColors[selected.app] || OTHER }}>
              {selected.app}
            </span>
            <button className="icon-btn" onClick={() => remove(selected.id)}>
              forget
            </button>
          </div>
          {selected.file && <img src={`/captures/${selected.file}`} alt="" loading="lazy" />}
          {!selected.file && selected.thumb && <img src={`/clem-thumbs/${selected.thumb}`} alt="" loading="lazy" />}
          {/* full narrative from the document itself — list titles are truncated by the engine */}
          <p className="summary" style={{ whiteSpace: 'pre-wrap' }}>
            {(fullDoc?.content || selected.title || '').split('\n\nScreenshot of')[0]}
          </p>
          {!fullDoc?.content && selected.summary && <p className="summary">{selected.summary}</p>}
          <div className="meta-row">
            <span className="k">when</span>
            <span>
              {timeAgo(selected.createdAt)} · {new Date(selected.createdAt).toLocaleString()}
            </span>
          </div>
          {selected.url && (
            <div className="meta-row">
              <span className="k">url</span>
              <a href={selected.url} target="_blank" rel="noreferrer" style={{ color: '#3987e5', wordBreak: 'break-all' }}>
                {selected.url.slice(0, 60)}
              </a>
            </div>
          )}
          <div className="meta-row">
            <span className="k">status</span>
            <span>{selected.status}</span>
          </div>
        </aside>
      )}
    </div>
  )
}
