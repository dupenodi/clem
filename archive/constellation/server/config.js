import { homedir } from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

export const ROOT = path.resolve(__dirname, '..')
export const PORT = Number(process.env.CONSTELLATION_PORT || 7777)
export const SUPERMEMORY_URL = process.env.SUPERMEMORY_URL || 'http://localhost:6767'
export const OLLAMA_URL = process.env.OLLAMA_URL || 'http://localhost:11434'
// Same model the engine uses for extraction — keeping one model resident
// avoids multi-GB swap thrashing between calls.
export const ORACLE_MODEL = process.env.ORACLE_MODEL || 'qwen3:8b'
export const CONTAINER_TAG = process.env.CONSTELLATION_TAG || 'clem'

// Local copies of captured screenshots, so the UI can render them.
export const CAPTURES_DIR = path.join(ROOT, 'data', 'captures')
export const CACHE_DIR = path.join(ROOT, 'data', 'cache')
export const HOME = homedir()
