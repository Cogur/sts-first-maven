// HomeGuard Bridge: logs in to TVT/Techson recorders the way SuperLive Plus
// does (by cloud serial number through TVT's P2P servers, or by IP) using the
// vendor's Linux SDK, and re-publishes them to the HomeGuard app:
//
//   * live and recorded video -> mediamtx (RTSPS), fed through ffmpeg from
//     the internal feed server below (mediamtx `runOnDemand`)
//   * snapshots, recording search, door relay -> HTTPS JSON API
//
// Everything the app talks to is TLS + password protected. The feed server
// listens on loopback only.
import crypto from 'node:crypto'
import fs from 'node:fs'
import http from 'node:http'
import https from 'node:https'

const LIVE_PATH = /^([a-z0-9]+)_ch(\d{1,3})_(main|sub)$/
const PLAYBACK_PATH = /^([a-z0-9]+)_ch(\d{1,3})_pb_(\d{14})_(\d{14})$/

export function parseStamp(s) {
  const n = (a, b) => Number(s.slice(a, b))
  const d = new Date(n(0, 4), n(4, 6) - 1, n(6, 8), n(8, 10), n(10, 12), n(12, 14))
  return Number.isNaN(d.getTime()) ? null : d
}

export function stamp(d) {
  const p = (v) => String(v).padStart(2, '0')
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`
}

/** A logged-in device; re-logs in with backoff when the SDK reports errors. */
class DeviceSession {
  constructor(sdk, cfg, log) {
    this.sdk = sdk
    this.cfg = cfg
    this.log = log
    this.login = null
    this.error = null
    this.pending = null
  }

  async ensure() {
    if (this.login) return this.login
    this.pending ??= (async () => {
      try {
        const { id, serial, host, port, username } = this.cfg
        this.log(`[${id}] logging in ${serial ? `by serial ${serial.slice(0, 4)}… (P2P)` : `at ${host}:${port ?? 6036}`}`)
        this.login = await this.sdk.login({ serial, host, port, username, password: this.cfg.password })
        this.error = null
        this.log(`[${id}] online: ${this.login.info.name || this.login.info.product}, ${this.login.info.channels} channels`)
        return this.login
      } catch (e) {
        this.error = e.message
        throw e
      } finally {
        this.pending = null
      }
    })()
    return this.pending
  }

  /** Drops the session so the next request logs in again. */
  reset() {
    if (this.login) this.sdk.logout(this.login.id)
    this.login = null
  }
}

export function createBridge({ sdk, config, log = console.log }) {
  const sessions = new Map(config.devices.map((d) => [d.id, new DeviceSession(sdk, d, log)]))
  const active = new Set()

  async function withDevice(id, fn) {
    const s = sessions.get(id)
    if (!s) throw Object.assign(new Error('Unknown device'), { status: 404 })
    const { id: userId, info } = await s.ensure()
    // The SDK reconnects a dropped session on its own (NET_SDK_SetReconnect).
    return fn(userId, info)
  }

  // --- Internal feed for mediamtx/ffmpeg (loopback only) -------------------
  const feed = http.createServer(async (req, res) => {
    const name = decodeURIComponent((req.url ?? '').replace(/^\/feed\//, '').split('?')[0])
    const live = LIVE_PATH.exec(name)
    const pb = PLAYBACK_PATH.exec(name)
    if (!live && !pb) return res.writeHead(404).end()
    const [, dev, chText] = live ?? pb
    const channel = Number(chText) - 1
    let handle = null
    let stopped = false
    let sawKey = false
    const onFrame = (frame, data) => {
      if (frame.frameType !== 1) return // video only
      if (!sawKey && !frame.keyFrame) return
      sawKey = true
      if (!res.write(data)) {
        // Slow consumer: skip ahead to the next keyframe instead of queueing video.
        sawKey = false
      }
    }
    const stop = async () => {
      if (stopped) return
      stopped = true
      active.delete(stop)
      if (handle != null) await (live ? sdk.stopLive(handle) : sdk.stopPlayback(handle)).catch(() => {})
    }
    req.on('close', stop)
    try {
      await withDevice(dev, async (userId) => {
        if (live) {
          handle = sdk.livePlay(userId, channel, live[3] === 'main' ? 0 : 1, onFrame)
        } else {
          const from = parseStamp(pb[3])
          const to = parseStamp(pb[4])
          if (!from || !to || to <= from) throw Object.assign(new Error('Bad time range'), { status: 400 })
          handle = sdk.playback(userId, channel, from, to, onFrame)
        }
      })
      active.add(stop)
      res.writeHead(200, { 'Content-Type': 'video/h264' })
      res.flushHeaders()
      log(`[${dev}] streaming ${name}`)
    } catch (e) {
      log(`[${dev}] feed ${name} failed: ${e.message}`)
      res.writeHead(e.status ?? 502).end()
      await stop()
    }
  })

  // --- Public API ------------------------------------------------------------
  const failures = new Map()
  const authorized = (req) => {
    const ip = req.socket.remoteAddress ?? ''
    const f = failures.get(ip)
    if (f && f.count >= 5 && Date.now() - f.at < 60_000) return 'locked'
    const [scheme, value] = (req.headers.authorization ?? '').split(' ')
    const given = Buffer.from(scheme === 'Basic' && value ? Buffer.from(value, 'base64').toString() : '')
    const expected = Buffer.from(`${config.auth.username}:${config.auth.password}`)
    const ok = given.length === expected.length && crypto.timingSafeEqual(given, expected)
    if (ok) failures.delete(ip)
    else failures.set(ip, { count: (f?.count ?? 0) + 1, at: Date.now() })
    return ok
  }

  const json = (res, status, body) => {
    res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' })
    res.end(JSON.stringify(body))
  }

  async function api(req, res) {
    const url = new URL(req.url ?? '/', 'https://bridge')
    if (url.pathname === '/api/health') return json(res, 200, { ok: true })
    const auth = authorized(req)
    if (auth !== true) {
      res.writeHead(auth === 'locked' ? 429 : 401, { 'WWW-Authenticate': 'Basic realm="HomeGuard Bridge"' })
      return res.end()
    }
    const parts = url.pathname.split('/').filter(Boolean) // api, devices, :id, ...
    try {
      if (parts.length === 2 && parts[1] === 'devices') {
        const list = await Promise.all(
          [...sessions.values()].map(async (s) => {
            try {
              const { info } = await s.ensure()
              return { id: s.cfg.id, online: true, ...info }
            } catch (e) {
              return { id: s.cfg.id, online: false, error: e.message }
            }
          }),
        )
        return json(res, 200, { devices: list, streamPath: '/{device}_ch{channel}_{stream}' })
      }
      const [, , dev, kind, chText, action] = parts
      if (parts[1] !== 'devices' || !dev) return json(res, 404, { error: 'Not found' })
      const n = Number(chText)
      if (kind === 'channels' && action === 'snapshot.jpg' && req.method === 'GET') {
        const jpeg = await withDevice(dev, (id) => sdk.snapshot(id, n - 1))
        res.writeHead(200, { 'Content-Type': 'image/jpeg', 'Cache-Control': 'no-store' })
        return res.end(jpeg)
      }
      if (kind === 'channels' && action === 'recordings' && req.method === 'GET') {
        const from = new Date(url.searchParams.get('from') ?? '')
        const to = new Date(url.searchParams.get('to') ?? '')
        if (Number.isNaN(from.getTime()) || Number.isNaN(to.getTime()) || to <= from) {
          return json(res, 400, { error: 'from/to must be ISO times, from < to' })
        }
        const recs = await withDevice(dev, (id) => sdk.findRecordings(id, n - 1, from, to))
        return json(res, 200, {
          recordings: recs.map((r) => ({
            start: r.start.toISOString(),
            end: r.end.toISOString(),
            type: r.type,
            path: `/${dev}_ch${n}_pb_${stamp(r.start)}_${stamp(r.end)}`,
          })),
        })
      }
      if (kind === 'alarm-outputs' && action === 'pulse' && req.method === 'POST') {
        const hold = Math.min(10_000, Math.max(200, Number(url.searchParams.get('ms') ?? 1000)))
        await withDevice(dev, async (id) => {
          if (!sdk.setAlarmOutput(id, n, true)) throw new Error(`Alarm output failed (error ${sdk.lastError()})`)
          await new Promise((r) => setTimeout(r, hold))
          sdk.setAlarmOutput(id, n, false)
        })
        log(`[${dev}] alarm output ${n} pulsed ${hold} ms`)
        return json(res, 200, { ok: true })
      }
      return json(res, 404, { error: 'Not found' })
    } catch (e) {
      return json(res, e.status ?? 502, { error: e.message })
    }
  }

  return {
    sessions,
    feed,
    api,
    async close() {
      await Promise.all([...active].map((stop) => stop()))
      for (const s of sessions.values()) s.reset()
      feed.closeAllConnections()
      feed.close()
    },
  }
}

export function loadConfig(file, env = process.env) {
  const raw = JSON.parse(fs.readFileSync(file, 'utf8'))
  const devices = (raw.devices ?? []).map((d) => {
    if (!/^[a-z0-9]+$/.test(d.id ?? '')) throw new Error(`device id "${d.id}" must be lowercase letters/digits`)
    if (!d.serial && !d.host) throw new Error(`device ${d.id}: set "serial" (P2P) or "host"`)
    const password = env[d.passwordEnv ?? `${d.id.toUpperCase()}_PASSWORD`]
    if (!password) throw new Error(`device ${d.id}: password env ${d.passwordEnv ?? `${d.id.toUpperCase()}_PASSWORD`} not set`)
    return { ...d, username: d.username ?? 'admin', password }
  })
  const auth = { username: env.BRIDGE_USER ?? '', password: env.BRIDGE_PASSWORD ?? '' }
  if (auth.username.length < 3 || auth.password.length < 8) {
    throw new Error('Set BRIDGE_USER and BRIDGE_PASSWORD (at least 8 characters)')
  }
  return { natServer: raw.natServer ?? 'cli-nat20.eyeincloud.com:9969', devices, auth }
}

async function main() {
  const config = loadConfig(process.env.BRIDGE_CONFIG ?? '/config/bridge.json')
  const { loadSdk } = await import('./sdk.mjs')
  const sdk = await loadSdk(process.env.TVT_SDK_DIR ?? new URL('../vendor/', import.meta.url).pathname, {
    serials: config.devices.filter((d) => d.serial).map((d) => d.serial),
  })
  if (config.devices.some((d) => d.serial)) {
    const [host, port] = config.natServer.split(':')
    if (!sdk.setNat2Server(host, Number(port ?? 9969))) console.warn('NET_SDK_SetNat2Addr refused the P2P server')
  }
  const bridge = createBridge({ sdk, config })
  bridge.feed.listen(8091, '127.0.0.1')
  const tls = { key: fs.readFileSync(process.env.TLS_KEY ?? '/certs/bridge.key'), cert: fs.readFileSync(process.env.TLS_CERT ?? '/certs/bridge.crt') }
  https.createServer(tls, bridge.api).listen(Number(process.env.API_PORT ?? 8443))
  console.log('HomeGuard Bridge ready: API https://:8443, video rtsps://:8322')
  const shutdown = async () => {
    await bridge.close()
    sdk.cleanup() // the SDK's NAT thread crashes on exit otherwise
    process.exit(0)
  }
  process.on('SIGTERM', shutdown)
  process.on('SIGINT', shutdown)
  // Log in early so the first stream opens fast.
  for (const s of bridge.sessions.values()) s.ensure().catch((e) => console.warn(`[${s.cfg.id}] ${e.message}`))
}

if (import.meta.url === `file://${process.argv[1]}`) main()
