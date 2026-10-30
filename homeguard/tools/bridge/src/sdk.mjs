// Thin koffi FFI layer over TVT's Linux NET_SDK (libdvrnetsdk.so).
//
// The vendor libraries are NOT part of this repository. `npm run fetch-sdk`
// copies them from the @2bad/tvt npm package, which redistributes them. Struct
// layouts follow 2BAD/tvt (MIT, https://github.com/2BAD/tvt) and the vendor
// header DVR_NET_SDK.h.
//
// Channels are 0-based at this layer, as in the SDK.
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

export const CONNECT = { TCP: 0, NAT: 1, NAT20: 2 }
export const STREAM = { MAIN: 0, SUB: 1 }
export const FRAME = { VIDEO: 1, AUDIO: 2 }

/** Upper-case MD5 hex, which is what the SDK sends instead of the serial. */
export const serialCode = (serial) => crypto.createHash('md5').update(serial).digest('hex').toUpperCase()

/**
 * @param libDir folder with libdvrnetsdk.so and its siblings
 * @param serials cloud serials that will be logged in by P2P; the
 *   hg_p2p_serial shim (native/) must be loaded before the SDK for them.
 */
export async function loadSdk(libDir, { serials = [] } = {}) {
  const { default: koffi } = await import('koffi')
  const shim = path.join(libDir, 'libhg_p2p_serial.so')
  if (serials.length) {
    if (!fs.existsSync(shim)) throw new Error(`${shim} missing: serial (P2P) login needs it, see native/`)
    process.env.HG_P2P_SERIAL_MAP = serials.map((s) => `${serialCode(s)}=${s}`).join(',')
    // RTLD_GLOBAL and before the SDK, so the SDK's NAT call binds to the shim.
    koffi.load(shim, { global: true })
  }
  const lib = koffi.load(path.join(libDir, 'libdvrnetsdk.so'))

  const DD_TIME = koffi.struct('DD_TIME', {
    second: 'uchar', minute: 'uchar', hour: 'uchar', wday: 'uchar',
    mday: 'uchar', month: 'uchar', year: 'ushort',
    nTotalseconds: 'int', nMicrosecond: 'int',
  })
  const DEVICEINFO = koffi.struct('NET_SDK_DEVICEINFO', {
    localVideoInputNum: 'uchar', audioInputNum: 'uchar', sensorInputNum: 'uchar', sensorOutputNum: 'uchar',
    displayResolutionMask: 'uint',
    videoOuputNum: 'uchar', netVideoOutputNum: 'uchar', netVideoInputNum: 'uchar', IVSNum: 'uchar',
    presetNumOneCH: 'uchar', cruiseNumOneCH: 'uchar', presetNumOneCruise: 'uchar', trackNumOneCH: 'uchar',
    userNum: 'uchar', netClientNum: 'uchar', netFirstStreamNum: 'uchar', deviceType: 'uchar',
    doblueStream: 'uchar', audioStream: 'uchar', talkAudio: 'uchar', bPasswordCheck: 'uchar',
    defBrightness: 'uchar', defContrast: 'uchar', defSaturation: 'uchar', defHue: 'uchar',
    videoInputNum: 'ushort', deviceID: 'ushort', videoFormat: 'uint',
    function: koffi.array('uint', 8),
    deviceIP: 'uint', deviceMAC: koffi.array('uchar', 6), devicePort: 'ushort',
    buildDate: 'uint', buildTime: 'uint',
    deviceName: koffi.array('char', 36),
    firmwareVersion: koffi.array('char', 36), kernelVersion: koffi.array('char', 64),
    hardwareVersion: koffi.array('char', 36), MCUVersion: koffi.array('char', 36),
    firmwareVersionEx: koffi.array('char', 64), softwareVer: 'uint',
    szSN: koffi.array('char', 32), deviceProduct: koffi.array('char', 28),
  })
  const CLIENTINFO = koffi.struct('NET_SDK_CLIENTINFO', {
    lChannel: 'long', streamType: 'long', hPlayWnd: 'void *', bNoDecode: 'int',
  })
  const FRAME_INFO = koffi.struct('NET_SDK_FRAME_INFO', {
    deviceID: 'uint', channel: 'uint', frameType: 'uint', length: 'uint', keyFrame: 'uint',
    width: 'uint', height: 'uint', frameIndex: 'uint', frameAttrib: 'uint', streamID: 'uint',
    time: 'int64', relativeTime: 'int64',
  })
  const REC_FILE = koffi.struct('NET_SDK_REC_FILE', {
    dwChannel: 'uint32', bFileLocked: 'uint32', startTime: DD_TIME, stopTime: DD_TIME,
    dwRecType: 'uint32', dwPartition: 'uint32', dwFileIndex: 'uint32',
  })
  const DATA_CB = koffi.proto('void HG_DATA_CB(long handle, NET_SDK_FRAME_INFO frameInfo, void *buffer, void *user)')

  const f = {
    init: lib.func('NET_SDK_Init', 'bool', []),
    cleanup: lib.func('NET_SDK_Cleanup', 'bool', []),
    setConnectTime: lib.func('NET_SDK_SetConnectTime', 'bool', ['uint32', 'uint32']),
    setReconnect: lib.func('NET_SDK_SetReconnect', 'bool', ['uint32', 'bool']),
    setNat2Addr: lib.func('NET_SDK_SetNat2Addr', 'bool', ['str', 'uint16']),
    loginEx: lib.func('NET_SDK_LoginEx', 'long', [
      'str', 'uint16', 'str', 'str', koffi.out(koffi.pointer(DEVICEINFO)), 'int', 'str',
    ]),
    logout: lib.func('NET_SDK_Logout', 'bool', ['long']),
    lastError: lib.func('NET_SDK_GetLastError', 'uint32', []),
    livePlay: lib.func('NET_SDK_LivePlay', 'long', ['long', koffi.pointer(CLIENTINFO), 'void *', 'void *']),
    setLiveCb: lib.func('NET_SDK_SetLiveDataCallBack', 'bool', ['long', koffi.pointer(DATA_CB), 'void *']),
    stopLive: lib.func('NET_SDK_StopLivePlay', 'bool', ['long']),
    makeKeyFrame: lib.func('NET_SDK_MakeKeyFrameEx', 'bool', ['long', 'long', 'uint']),
    playByTime: lib.func('NET_SDK_PlayBackByTime', 'long', [
      'long', 'long *', 'long', koffi.pointer(DD_TIME), koffi.pointer(DD_TIME), 'void *',
    ]),
    setPlayCb: lib.func('NET_SDK_SetPlayDataCallBack', 'bool', ['long', koffi.pointer(DATA_CB), 'void *']),
    stopPlay: lib.func('NET_SDK_StopPlayBack', 'bool', ['long']),
    findFile: lib.func('NET_SDK_FindFile', 'long', ['long', 'long', koffi.pointer(DD_TIME), koffi.pointer(DD_TIME)]),
    findNext: lib.func('NET_SDK_FindNextFile', 'long', ['long', koffi.out(koffi.pointer(REC_FILE))]),
    findClose: lib.func('NET_SDK_FindClose', 'bool', ['long']),
    jpeg: lib.func('NET_SDK_CaptureJPEGData_V2', 'bool', ['long', 'long', 'void *', 'uint32', koffi.out('uint32 *')]),
    manualAlarm: lib.func('NET_SDK_SetDeviceManualAlarm', 'bool', ['long', 'long *', 'long *', 'long', 'bool']),
  }

  // Calls that can block for seconds (P2P logins take ~5-20 s) run on a
  // koffi worker thread so the event loop keeps serving.
  const runAsync = (fn, ...args) => new Promise((resolve, reject) =>
    fn.async(...args, (err, value) => (err ? reject(err) : resolve(value))))

  const cstr = (arr) => Buffer.from(arr).toString('latin1').replace(/\0.*$/s, '').trim()
  const toDD = (d) => ({
    second: d.getSeconds(), minute: d.getMinutes(), hour: d.getHours(), wday: d.getDay(),
    mday: d.getDate(), month: d.getMonth() + 1, year: d.getFullYear(), nTotalseconds: 0, nMicrosecond: 0,
  })
  const fromDD = (t) => new Date(t.year, t.month - 1, t.mday, t.hour, t.minute, t.second)

  const callbacks = new Map()
  const register = (onFrame) => koffi.register((_h, frame, buffer) => {
    try {
      if (frame.length > 0) onFrame(frame, Buffer.from(koffi.decode(buffer, koffi.array('uint8', frame.length))))
    } catch {
      // Never throw into the SDK's streaming thread.
    }
  }, koffi.pointer(DATA_CB))

  if (!f.init()) throw new Error('NET_SDK_Init failed')
  f.setConnectTime(8000, 2)
  f.setReconnect(10000, true)

  return {
    lastError: () => f.lastError(),

    /** Must be called before the first serial login; effective once per process. */
    setNat2Server: (host, port) => f.setNat2Addr(host, port),

    async login({ host, port = 6036, serial, username, password }) {
      const info = {}
      const id = serial
        ? await runAsync(f.loginEx, serial, port, username, password, info, CONNECT.NAT20, serial)
        : await runAsync(f.loginEx, host, port, username, password, info, CONNECT.TCP, null)
      if (id < 0) throw new Error(`NET_SDK login failed (error ${f.lastError()})`)
      return {
        id,
        info: {
          name: cstr(info.deviceName),
          product: cstr(info.deviceProduct),
          serial: cstr(info.szSN),
          firmware: cstr(info.firmwareVersion),
          channels: info.videoInputNum || info.localVideoInputNum + info.netVideoInputNum,
          alarmOutputs: info.sensorOutputNum,
        },
      }
    },

    logout: (id) => f.logout(id),

    livePlay(id, channel, stream, onFrame) {
      const handle = f.livePlay(id, { lChannel: channel, streamType: stream, hPlayWnd: null, bNoDecode: 0 }, null, null)
      if (handle <= 0) throw new Error(`LivePlay failed (error ${f.lastError()})`)
      const cb = register(onFrame)
      callbacks.set(`l${handle}`, cb)
      f.setLiveCb(handle, cb, null)
      f.makeKeyFrame(id, channel, stream)
      return handle
    },

    async stopLive(handle) {
      await runAsync(f.stopLive, handle)
      const cb = callbacks.get(`l${handle}`)
      if (cb) koffi.unregister(cb)
      callbacks.delete(`l${handle}`)
    },

    playback(id, channel, start, stop, onFrame) {
      const handle = f.playByTime(id, [channel], 1, toDD(start), toDD(stop), null)
      if (handle <= 0) throw new Error(`PlayBackByTime failed (error ${f.lastError()})`)
      const cb = register(onFrame)
      callbacks.set(`p${handle}`, cb)
      f.setPlayCb(handle, cb, null)
      return handle
    },

    async stopPlayback(handle) {
      await runAsync(f.stopPlay, handle)
      const cb = callbacks.get(`p${handle}`)
      if (cb) koffi.unregister(cb)
      callbacks.delete(`p${handle}`)
    },

    async findRecordings(id, channel, start, stop) {
      const h = await runAsync(f.findFile, id, channel, toDD(start), toDD(stop))
      if (h <= 0) return []
      const out = []
      try {
        for (let i = 0; i < 5000; i++) {
          const rec = {}
          const r = f.findNext(h, rec)
          // NET_SDK_FILE_SUCCESS (85); NOFIND / NOMOREFILE end the search.
          if (r !== 85) break
          out.push({ channel: rec.dwChannel, start: fromDD(rec.startTime), end: fromDD(rec.stopTime), type: rec.dwRecType })
        }
      } finally {
        f.findClose(h)
      }
      return out
    },

    async snapshot(id, channel) {
      const size = 2 * 1024 * 1024
      const buf = Buffer.alloc(size)
      const got = [0]
      const ok = await runAsync(f.jpeg, id, channel, buf, size, got)
      if (!ok || got[0] === 0) throw new Error(`Snapshot failed (error ${f.lastError()})`)
      return buf.subarray(0, got[0])
    },

    /** Switches alarm output [output] (0-based). Door relays on TVT intercoms. */
    setAlarmOutput: (id, output, on) => f.manualAlarm(id, [output], [on ? 1 : 0], 1, !!on),

    cleanup: () => f.cleanup(),
  }
}
