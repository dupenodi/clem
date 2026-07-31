async function json(res) {
  if (!res.ok) throw new Error((await res.text()).slice(0, 200))
  return res.json()
}

export const getHealth = () => fetch('/api/health').then(json)
export const getMemories = () => fetch('/api/memories').then(json)
export const getGraph = () => fetch('/api/graph').then(json)
export const getStats = () => fetch('/api/stats').then(json)
export const capture = (mode = 'screen') =>
  fetch('/api/capture', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ mode }),
  }).then(json)
export const getMemory = (id) => fetch(`/api/memories/${id}`).then(json)
export const deleteMemory = (id) => fetch(`/api/memories/${id}`, { method: 'DELETE' }).then(json)

// SSE over POST: parse the event stream by hand.
export async function ask(q, { onSources, onToken, onDone, onError }) {
  const res = await fetch('/api/ask', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ q }),
  })
  if (!res.ok || !res.body) return onError?.(new Error(`ask failed: ${res.status}`))
  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    buffer += decoder.decode(value, { stream: true })
    const blocks = buffer.split('\n\n')
    buffer = blocks.pop()
    for (const block of blocks) {
      const event = /^event: (.*)$/m.exec(block)?.[1]
      const dataLine = /^data: (.*)$/m.exec(block)?.[1]
      if (!event || dataLine === undefined) continue
      let data
      try {
        data = JSON.parse(dataLine)
      } catch {
        continue
      }
      if (event === 'sources') onSources?.(data)
      else if (event === 'token') onToken?.(data)
      else if (event === 'done') onDone?.()
      else if (event === 'error') onError?.(new Error(data.message))
    }
  }
  onDone?.()
}
