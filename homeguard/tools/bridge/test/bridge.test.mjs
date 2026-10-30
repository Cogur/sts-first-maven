import assert from 'node:assert/strict'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import { serialCode } from '../src/sdk.mjs'
import { createBridge, loadConfig, parseStamp, stamp } from '../src/server.mjs'

function fakeSdk() {
  const calls = []
  const streams = new Map()
  let next = 1
  return {
    calls,
    streams,
    lastError: () => 0,
    async login({ serial, host, password }) {
      calls.push(['login', serial ?? host])
      if (password !== 'secret') throw new Error('NET_SDK login failed (error 3)')
      return { id: 7, info: { name: 'NVR', product: 'TCR', serial: 'SN1', channels: 3, alarmOutputs: 1 } }
    },
    logout: () => true,
    livePlay(id, ch, stream, onFrame) {
      calls.push(['live', id, ch, stream])
      const h = next++
      streams.set(h, onFrame)
      return h
    },
    async stopLive(h) {
      calls.push(['stopLive', h])
      streams.delete(h)
    },
    playback(id, ch, from, to, onFrame) {
      calls.push(['playback', ch, stamp(from), stamp(to)])
      const h = next++
      streams.set(h, onFrame)
      return h
    },
    async stopPlayback(h) {
      streams.delete(h)
    },
    async findRecordings(id, ch) {
      calls.push(['find', ch])
      return [{ channel: ch, start: new Date(2026, 9, 30, 8, 0, 0), end: new Date(2026, 9, 30, 8, 30, 0), type: 1 }]
    },
    async snapshot() {
      return Buffer.from('JPEGDATA')
    },
    setAlarmOutput(id, n, on) {
      calls.push(['alarm', n, on])
      return true
    },
  }
}

const config = {
  devices: [{ id: 'nvr', serial: 'NB8AF056T0D2', username: 'admin', password: 'secret' }],
  auth: { username: 'app', password: 'a-long-password' },
}

async function start(sdk = fakeSdk()) {
  const bridge = createBridge({ sdk, config, log: () => {} })
  const api = http.createServer(bridge.api)
  await new Promise((r) => api.listen(0, '127.0.0.1', r))
  await new Promise((r) => bridge.feed.listen(0, '127.0.0.1', r))
  return {
    sdk,
    bridge,
    api: `http://127.0.0.1:${api.address().port}`,
    feed: `http://127.0.0.1:${bridge.feed.address().port}`,
    async close() {
      await bridge.close()
      api.closeAllConnections()
      api.close()
    },
  }
}

const auth = { Authorization: `Basic ${Buffer.from('app:a-long-password').toString('base64')}` }

test('time stamps round-trip in local time', () => {
  const d = new Date(2026, 9, 30, 7, 5, 9)
  assert.equal(stamp(d), '20261030070509')
  assert.equal(parseStamp('20261030070509').getTime(), d.getTime())
})

test('serial code matches what the SDK sends', () => {
  assert.equal(serialCode('abc'), '900150983CD24FB0D6963F7D28E17F72')
})

test('API requires the bridge password and locks out after failures', async () => {
  const t = await start()
  try {
    assert.equal((await fetch(`${t.api}/api/health`)).status, 200)
    assert.equal((await fetch(`${t.api}/api/devices`)).status, 401)
    for (let i = 0; i < 5; i++) {
      await fetch(`${t.api}/api/devices`, { headers: { Authorization: 'Basic eDp5' } })
    }
    assert.equal((await fetch(`${t.api}/api/devices`, { headers: auth })).status, 429)
  } finally {
    await t.close()
  }
})

test('lists devices, snapshots, recordings and pulses the relay', async () => {
  const t = await start()
  try {
    const devices = await (await fetch(`${t.api}/api/devices`, { headers: auth })).json()
    assert.equal(devices.devices[0].online, true)
    assert.equal(devices.devices[0].channels, 3)
    assert.deepEqual(t.sdk.calls[0], ['login', 'NB8AF056T0D2'])

    const snap = await fetch(`${t.api}/api/devices/nvr/channels/2/snapshot.jpg`, { headers: auth })
    assert.equal(snap.headers.get('content-type'), 'image/jpeg')
    assert.equal(await snap.text(), 'JPEGDATA')

    const q = new URLSearchParams({ from: '2026-10-30T00:00:00', to: '2026-10-31T00:00:00' })
    const recs = await (await fetch(`${t.api}/api/devices/nvr/channels/1/recordings?${q}`, { headers: auth })).json()
    assert.equal(recs.recordings[0].path, '/nvr_ch1_pb_20261030080000_20261030083000')
    assert.deepEqual(t.sdk.calls.at(-1), ['find', 0])

    const pulse = await fetch(`${t.api}/api/devices/nvr/alarm-outputs/0/pulse?ms=200`, { method: 'POST', headers: auth })
    assert.equal(pulse.status, 200)
    assert.deepEqual(t.sdk.calls.slice(-2), [['alarm', 0, true], ['alarm', 0, false]])

    const bad = await fetch(`${t.api}/api/devices/nvr/channels/1/recordings?from=x&to=y`, { headers: auth })
    assert.equal(bad.status, 400)
    assert.equal((await fetch(`${t.api}/api/devices/zzz/channels/1/snapshot.jpg`, { headers: auth })).status, 404)
  } finally {
    await t.close()
  }
})

test('feed streams video from the first keyframe and stops on disconnect', async () => {
  const t = await start()
  try {
    const chunks = []
    await new Promise((resolve, reject) => {
      const req = http.get(`${t.feed}/feed/nvr_ch2_sub`, (res) => {
        assert.equal(res.statusCode, 200)
        res.on('data', (c) => {
          chunks.push(c.toString())
          if (chunks.join('').includes('K2')) {
            req.destroy()
            resolve()
          }
        })
        const push = t.sdk.streams.values().next().value
        push({ frameType: 1, keyFrame: 0 }, Buffer.from('P0')) // before keyframe: dropped
        push({ frameType: 2, keyFrame: 0 }, Buffer.from('A0')) // audio: dropped
        push({ frameType: 1, keyFrame: 1 }, Buffer.from('K1'))
        push({ frameType: 1, keyFrame: 0 }, Buffer.from('P1'))
        push({ frameType: 1, keyFrame: 1 }, Buffer.from('K2'))
      })
      req.on('error', (e) => (e.code === 'ECONNRESET' ? resolve() : reject(e)))
    })
    assert.equal(chunks.join(''), 'K1P1K2')
    assert.ok(t.sdk.calls.some((c) => c[0] === 'live' && c[2] === 1 && c[3] === 1))
    for (let i = 0; i < 50 && t.sdk.streams.size; i++) await new Promise((r) => setTimeout(r, 10))
    assert.equal(t.sdk.streams.size, 0)

    const pb = await fetch(`${t.feed}/feed/nvr_ch1_pb_20261030080000_20261030083000`)
    assert.equal(pb.status, 200)
    await pb.body.cancel()
    assert.deepEqual(t.sdk.calls.find((c) => c[0] === 'playback'), ['playback', 0, '20261030080000', '20261030083000'])
    assert.equal((await fetch(`${t.feed}/feed/../../etc/passwd`)).status, 404)
  } finally {
    await t.close()
  }
})

test('config validation refuses weak bridge passwords and missing secrets', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hgb-'))
  const file = path.join(dir, 'bridge.json')
  fs.writeFileSync(file, JSON.stringify({ devices: [{ id: 'nvr', serial: 'X1' }] }))
  assert.throws(() => loadConfig(file, { BRIDGE_USER: 'app', BRIDGE_PASSWORD: 'long-enough-pw' }), /NVR_PASSWORD/)
  assert.throws(() => loadConfig(file, { NVR_PASSWORD: 'p', BRIDGE_USER: 'app', BRIDGE_PASSWORD: 'short' }), /8 characters/)
  const ok = loadConfig(file, { NVR_PASSWORD: 'p', BRIDGE_USER: 'app', BRIDGE_PASSWORD: 'long-enough-pw' })
  assert.equal(ok.devices[0].username, 'admin')
  assert.equal(ok.natServer, 'cli-nat20.eyeincloud.com:9969')
})
