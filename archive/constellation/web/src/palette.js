// Validated categorical palette for the dark cosmic surface (#0b0e1a).
// dataviz six-checks: all PASS (worst adjacent CVD ΔE 23.7, all ≥3:1 contrast).
// Fixed slot order — never cycled. Apps beyond 6 fold into "Other".
export const SERIES = ['#3987e5', '#199e70', '#c98500', '#9085e9', '#e66767', '#d55181']
export const OTHER = '#6b7280'

export const INK = {
  primary: '#f4f6fb',
  secondary: '#a9b1c7',
  muted: '#6b7280',
  grid: '#1c2233',
  baseline: '#2a3147',
}

// Deterministic app → color. Slots are assigned by overall frequency
// (computed once per dataset), so color follows the entity, not its rank
// in whatever filter is active.
export function makeAppColors(appCounts) {
  const ranked = Object.entries(appCounts)
    .sort((a, b) => b[1] - a[1])
    .map(([app]) => app)
  const map = {}
  ranked.forEach((app, i) => {
    map[app] = i < SERIES.length ? SERIES[i] : OTHER
  })
  return map
}
