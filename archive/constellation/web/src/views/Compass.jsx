import { useEffect, useMemo, useState } from 'react'
import { getStats } from '../api.js'
import { makeAppColors, OTHER, INK } from '../palette.js'

function lastNDays(n) {
  const out = []
  const d = new Date()
  for (let i = n - 1; i >= 0; i--) {
    const day = new Date(d)
    day.setDate(d.getDate() - i)
    out.push(day.toISOString().slice(0, 10))
  }
  return out
}

export default function Compass({ refreshKey }) {
  const [stats, setStats] = useState(null)
  const [tip, setTip] = useState(null)

  useEffect(() => {
    getStats().then(setStats).catch(() => {})
  }, [refreshKey])

  const model = useMemo(() => {
    if (!stats) return null
    const appColors = makeAppColors(stats.apps)
    const days = lastNDays(14)
    const apps = Object.entries(stats.apps)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 6)
      .map(([name, count]) => ({ name, count }))
    const topSet = new Set(apps.map((a) => a.name))
    const series = days.map((day) => {
      const d = stats.days[day] || { total: 0, apps: {} }
      const segs = {}
      for (const [app, c] of Object.entries(d.apps)) {
        const key = topSet.has(app) ? app : 'Other'
        segs[key] = (segs[key] || 0) + c
      }
      return { day, total: d.total, segs }
    })
    const today = stats.days[days.at(-1)]?.total || 0
    const week = days.slice(-7).reduce((s, d) => s + (stats.days[d]?.total || 0), 0)
    const activeDays = days.filter((d) => stats.days[d]?.total > 0).length
    return { appColors, days, apps, series, today, week, activeDays }
  }, [stats])

  if (!model) return <div className="empty-state">Loading…</div>

  const { appColors, apps, series, today, week, activeDays } = model
  const W = 900
  const H = 220
  const PAD = { l: 8, r: 8, t: 12, b: 24 }
  const innerW = W - PAD.l - PAD.r
  const innerH = H - PAD.t - PAD.b
  const maxTotal = Math.max(1, ...series.map((s) => s.total))
  const barW = Math.min(34, (innerW / series.length) * 0.62)
  const step = innerW / series.length
  const maxApp = Math.max(1, ...apps.map((a) => a.count))

  return (
    <div className="compass">
      <div className="compass-inner">
        <div className="tiles">
          <div className="tile panel">
            <div className="label">Memories</div>
            <div className="value">{stats.totalMemories}</div>
            <div className="hint">total stars in your sky</div>
          </div>
          <div className="tile panel">
            <div className="label">Today</div>
            <div className="value">{today}</div>
            <div className="hint">moments captured</div>
          </div>
          <div className="tile panel">
            <div className="label">This week</div>
            <div className="value">{week}</div>
            <div className="hint">last 7 days</div>
          </div>
          <div className="tile panel">
            <div className="label">Active days</div>
            <div className="value">{activeDays}/14</div>
            <div className="hint">days with at least one capture</div>
          </div>
        </div>

        <div className="chart-card panel">
          <h3>Capture rhythm</h3>
          <div className="sub">memories per day by app · last 14 days</div>
          <svg viewBox={`0 0 ${W} ${H}`} style={{ width: '100%', display: 'block' }}>
            {/* baseline */}
            <line x1={PAD.l} x2={W - PAD.r} y1={H - PAD.b} y2={H - PAD.b} stroke={INK.baseline} strokeWidth="1" />
            {series.map((s, i) => {
              const x = PAD.l + i * step + (step - barW) / 2
              let yCursor = H - PAD.b
              const entries = Object.entries(s.segs)
              const isLast = (j) => j === entries.length - 1
              return (
                <g
                  key={s.day}
                  onMouseMove={(e) =>
                    s.total > 0 &&
                    setTip({
                      x: e.clientX,
                      y: e.clientY,
                      day: s.day,
                      lines: entries.map(([app, c]) => ({ app, c, color: appColors[app] || OTHER })),
                    })
                  }
                  onMouseLeave={() => setTip(null)}
                >
                  {/* invisible hit target across full column */}
                  <rect x={PAD.l + i * step} y={PAD.t} width={step} height={innerH} fill="transparent" />
                  {entries.map(([app, c], j) => {
                    const h = Math.max(2, (c / maxTotal) * innerH - 2)
                    yCursor -= h
                    const y = yCursor
                    yCursor -= 2 // 2px surface gap between stacked segments
                    return (
                      <rect
                        key={app}
                        x={x}
                        y={y}
                        width={barW}
                        height={h}
                        rx={isLast(j) ? 4 : 0}
                        fill={appColors[app] || OTHER}
                      />
                    )
                  })}
                  <text
                    x={PAD.l + i * step + step / 2}
                    y={H - 7}
                    textAnchor="middle"
                    fontSize="10"
                    fill={INK.muted}
                    fontFamily="system-ui"
                  >
                    {s.day.slice(8)}
                  </text>
                </g>
              )
            })}
          </svg>
          <div className="legend">
            {apps.map((a) => (
              <span key={a.name}>
                <span className="swatch" style={{ background: appColors[a.name] || OTHER }} />
                {a.name}
              </span>
            ))}
          </div>
        </div>

        <div className="chart-card panel">
          <h3>Where your attention lives</h3>
          <div className="sub">captures by app · all time</div>
          {apps.map((a) => (
            <div key={a.name} style={{ display: 'flex', alignItems: 'center', gap: 12, margin: '9px 0' }}>
              <span style={{ width: 130, fontSize: 12.5, color: 'var(--ink-2)', textAlign: 'right', flexShrink: 0, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {a.name}
              </span>
              <div style={{ flex: 1, display: 'flex', alignItems: 'center', gap: 8 }}>
                <div
                  style={{
                    width: `${(a.count / maxApp) * 100}%`,
                    height: 14,
                    borderRadius: '0 4px 4px 0',
                    background: appColors[a.name] || OTHER,
                    minWidth: 2,
                  }}
                />
                <span style={{ fontSize: 12, color: 'var(--ink-2)' }}>{a.count}</span>
              </div>
            </div>
          ))}
        </div>
      </div>

      {tip && (
        <div className="viz-tooltip" style={{ left: tip.x + 14, top: tip.y + 10 }}>
          <strong>{tip.day}</strong>
          {tip.lines.map((l) => (
            <div key={l.app}>
              <span className="swatch" style={{ background: l.color, display: 'inline-block', width: 8, height: 8, borderRadius: 2, marginRight: 6 }} />
              {l.app}: {l.c}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
