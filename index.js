import { spawn } from 'node:child_process'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const SCRIPT = path.join(HERE, 'scripts', 'popup.ps1')
const POWERSHELL = path.join(
  process.env.SystemRoot || 'C:\\Windows',
  'System32',
  'WindowsPowerShell',
  'v1.0',
  'powershell.exe',
)

const DEFAULT_LABELS = {
  zh: { heading: '需要审批', allow: '允许', deny: '拒绝' },
  en: { heading: 'Approval required', allow: 'Allow', deny: 'Deny' },
}

let queue = Promise.resolve()

function enqueue(task) {
  const run = queue.then(task, task)
  queue = run.then(() => {}, () => {})
  return run
}

function normalizeConfig(config = {}) {
  const timeout = Number(config.timeoutSec)
  return {
    enabled: config.enabled !== false,
    lang: config.lang === 'en' ? 'en' : 'zh',
    timeoutSec: Number.isFinite(timeout) ? Math.max(0, Math.min(600, timeout)) : 60,
    sound: config.sound === true,
    focusWindow: config.focusWindow === true,
    showWhenFocused: config.showWhenFocused === true,
    labels: {
      zh: { ...DEFAULT_LABELS.zh, ...(config.labels?.zh || {}) },
      en: { ...DEFAULT_LABELS.en, ...(config.labels?.en || {}) },
    },
  }
}

function reasonFor(request, lang) {
  const display = request.displayReason
  if (typeof display === 'string') return display
  if (display && typeof display === 'object') {
    const value = display[lang] ?? display.en
    if (typeof value === 'string') return value
    const first = Object.values(display).find((item) => typeof item === 'string')
    if (first) return first
  }
  return typeof request.reason === 'string' ? request.reason : ''
}

function parseDecision(stdout) {
  const lines = stdout.split(/\r?\n/)
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index].trim()
    if (!line) continue
    const start = line.indexOf('{')
    if (start < 0) continue
    try {
      const value = JSON.parse(line.slice(start))
      if (value && typeof value.decision === 'string') return value.decision
    } catch {
      // Ignore partial or non-JSON output from the helper.
    }
  }
  return null
}

function showCard(request, cfg) {
  return new Promise((resolve) => {
    const payload = {
      tool: request.toolName,
      reason: reasonFor(request, cfg.lang),
      timeoutSec: cfg.timeoutSec,
      sound: cfg.sound,
      focusWindow: cfg.focusWindow,
      onlyWhenUnfocused: !cfg.showWhenFocused,
      watchFocus: !cfg.showWhenFocused,
      lang: cfg.lang,
      labels: cfg.labels,
    }

    let settled = false
    let stderr = ''
    let child
    let lifeTimer
    const finish = (decision) => {
      if (settled) return
      settled = true
      request.signal?.removeEventListener('abort', onAbort)
      if (lifeTimer) clearTimeout(lifeTimer)
      resolve(decision)
    }
    const onAbort = () => {
      try { child?.kill() } catch {}
      finish(null)
    }

    try {
      child = spawn(POWERSHELL, [
        '-NoProfile',
        '-STA',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', SCRIPT,
      ], {
        env: {
          ...process.env,
          DSH_APPROVAL_PAYLOAD: Buffer.from(JSON.stringify(payload), 'utf8').toString('base64'),
        },
        stdio: ['ignore', 'pipe', 'pipe'],
        windowsHide: true,
      })
    } catch {
      finish(null)
      return
    }

    if (cfg.timeoutSec > 0) {
      const lifeSeconds = cfg.timeoutSec + 20
      lifeTimer = setTimeout(() => {
        try { child.kill() } catch {}
        finish(null)
      }, lifeSeconds * 1000)
    }

    let stdout = ''
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', (chunk) => { stdout += chunk })
    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (chunk) => { stderr += chunk })
    child.on('error', () => finish(null))
    child.on('close', () => {
      const decision = parseDecision(stdout)
      if (decision !== 'allow' && decision !== 'deny') {
        if (stderr) {
          // Keep the helper output out of the approval result, but make a
          // broken helper diagnosable from the DSH log.
          console.warn('[dsh-approval-popup] helper:', stderr.trim().slice(0, 500))
        }
      }
      finish(decision)
    })

    if (request.signal?.aborted) {
      onAbort()
      return
    }
    request.signal?.addEventListener('abort', onAbort, { once: true })
  })
}

async function decide(request, cfg) {
  const result = await enqueue(() => {
    if (request.signal?.aborted) return null
    return showCard(request, cfg)
  })
  if (result === 'allow') return 'allowed-once'
  if (result === 'deny') return 'rejected'
  return null
}

export const name = 'dsh-approval-popup'

export function apply(ctx, config) {
  if (process.platform !== 'win32') return
  const cfg = normalizeConfig(config)
  if (!cfg.enabled) return

  ctx.on('approval/request', async (request, next) => {
    if (!request || typeof request !== 'object') return next()
    try {
      const outcome = await decide(request, cfg)
      return outcome ?? next()
    } catch {
      return next()
    }
  }, { prepend: true })
}
