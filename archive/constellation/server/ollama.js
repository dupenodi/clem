import { OLLAMA_URL, ORACLE_MODEL } from './config.js'

export async function ollamaHealth() {
  try {
    const res = await fetch(`${OLLAMA_URL}/api/tags`, { signal: AbortSignal.timeout(3000) })
    if (!res.ok) return { up: false, models: [] }
    const data = await res.json()
    return { up: true, models: (data.models || []).map((m) => m.name) }
  } catch {
    return { up: false, models: [] }
  }
}

// qwen3 defaults to thinking mode; skip it — narration and oracle answers
// don't need chain-of-thought and it doubles latency.
const thinkOpt = (model) => (model.startsWith('qwen3') ? { think: false } : {})

// One-shot chat completion (non-streaming).
export async function chat(messages, model = ORACLE_MODEL) {
  const res = await fetch(`${OLLAMA_URL}/api/chat`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, messages, stream: false, ...thinkOpt(model) }),
    signal: AbortSignal.timeout(120000),
  })
  if (!res.ok) throw new Error(`ollama chat → ${res.status}`)
  const data = await res.json()
  return data.message?.content?.trim() || ''
}

// Stream chat tokens from the local model. Calls onToken for each chunk.
export async function streamChat(messages, onToken, model = ORACLE_MODEL) {
  const res = await fetch(`${OLLAMA_URL}/api/chat`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, messages, stream: true, ...thinkOpt(model) }),
  })
  if (!res.ok) throw new Error(`ollama chat → ${res.status}`)
  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    buffer += decoder.decode(value, { stream: true })
    const lines = buffer.split('\n')
    buffer = lines.pop()
    for (const line of lines) {
      if (!line.trim()) continue
      try {
        const chunk = JSON.parse(line)
        if (chunk.message?.content) onToken(chunk.message.content)
      } catch {
        /* partial line */
      }
    }
  }
}
