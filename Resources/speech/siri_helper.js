// Read Aloud's voice for Workbench: Siri Voice 6 behind a pipe (protocol: Speaker.swift).
// Run by /usr/bin/osascript -l JavaScript: macOS lists Siri voices to AVSpeechSynthesizer only in Apple-signed
// processes, and osascript is one that every Mac has (no Xcode needed).
//
// stdin: JSON lines {"id": N, "text": "..."} (one chunk of job N) or {"cancel": N}.
// stdout: frames <u32 LE id><u32 LE sample rate Hz><u32 LE byte count> + float32 LE mono PCM at that rate
//   (Siri 48000; the en-US fallback may differ; never resampled), batched to >= 100 ms each (the first
//   buffer of a chunk goes out at once); the end of a chunk is a frame <id><0><0>.
// stderr: "voice: <identifier>" at start. Exits after 300 s without a job, and at stdin EOF.
ObjC.import('AVFAudio')

function run(argv) {
  const out = $.NSFileHandle.fileHandleWithStandardOutput
  const IDLE_EXIT = 300              // seconds without a job: exit; Workbench respawns on the next press
  // Siri Voice 6; the en-US system voice only if it is not installed
  let voice = $.AVSpeechSynthesisVoice.voiceWithIdentifier('com.apple.siri.natural.en-US-G')
  if (voice.isNil()) voice = $.AVSpeechSynthesisVoice.voiceWithLanguage('en-US')
  $.NSFileHandle.fileHandleWithStandardError.writeData($('voice: ' + voice.identifier.js + '\n').dataUsingEncoding($.NSUTF8StringEncoding))

  const u32 = (n) => String.fromCharCode(n & 255, n >>> 8 & 255, n >>> 16 & 255, n >>> 24)
  function frame(id, rate, pcm) {
    out.writeData($(u32(id) + u32(pcm ? rate : 0) + u32(pcm ? Number(pcm.length) : 0)).dataUsingEncoding($.NSISOLatin1StringEncoding))
    if (pcm) out.writeData(pcm)
  }

  const synth = $.AVSpeechSynthesizer.alloc.init
  const jobs = []
  const cancelled = new Set()
  let busy = null                    // the id being synthesized; its leftovers after a cancel are dropped
  let pending = null                 // PCM not yet written (< 100 ms)
  let rate = 0                       // sample rate of the current job's buffers

  function next() {
    while (busy === null && jobs.length) {
      const job = jobs.shift()
      if (cancelled.has(job.id)) continue
      busy = job.id
      pending = $.NSMutableData.data
      rate = 0
      const u = $.AVSpeechUtterance.speechUtteranceWithString(job.text)
      u.voice = voice
      synth.writeUtteranceToBufferCallback(u, (buf) => {
        if (busy !== job.id) return
        const n = Number(buf.frameLength)
        if (n > 0) {
          rate = Number(buf.format.sampleRate)
          pending.appendBytesLength(buf.floatChannelData[0], n * 4)   // the buffer is not ours after the callback
          if (!started.has(job.id) || Number(pending.length) >= Math.floor(rate / 10) * 4) { started.add(job.id); flush(job.id) }
          return
        }
        flush(job.id)
        frame(job.id, 0, null)
        busy = null
        next()
      })
    }
  }
  const started = new Set()          // jobs whose first buffer went out unbatched: first sound as soon as it exists
  function flush(id) {
    if (Number(pending.length) > 0) frame(id, rate, pending)
    pending = $.NSMutableData.data
  }

  const acc = $.NSMutableData.data   // raw stdin bytes: a read can end inside a UTF-8 sequence
  const NL = $('\n').dataUsingEncoding($.NSUTF8StringEncoding)
  function received(data) {
    acc.appendData(data)
    const r = acc.rangeOfDataOptionsRange(NL, $.NSDataSearchBackwards, $.NSMakeRange(0, acc.length))
    if (Number(r.length) === 0) return
    const upto = Number(r.location) + 1
    const text = $.NSString.alloc.initWithDataEncoding(acc.subdataWithRange($.NSMakeRange(0, upto)), $.NSUTF8StringEncoding).js
    acc.replaceBytesInRangeWithBytesLength($.NSMakeRange(0, upto), $(), 0)
    for (const raw of text.split('\n')) {
      if (!raw) continue
      let msg; try { msg = JSON.parse(raw) } catch (e) { continue }
      if (typeof msg.cancel === 'number') {
        cancelled.add(msg.cancel)
        if (busy === msg.cancel) { synth.stopSpeakingAtBoundary($.AVSpeechBoundaryImmediate); busy = null; next() }
      } else if (typeof msg.id === 'number' && typeof msg.text === 'string') {
        jobs.push(msg); next()
      }
    }
  }

  const stdin = $.NSFileHandle.fileHandleWithStandardInput
  let open = true
  $.NSNotificationCenter.defaultCenter.addObserverForNameObjectQueueUsingBlock(
    $.NSFileHandleReadCompletionNotification, stdin, $.NSOperationQueue.mainQueue, (note) => {
      const data = note.userInfo.objectForKey($.NSFileHandleNotificationDataItem)
      if (Number(data.length) === 0) { open = false; return }   // stdin closed: Workbench quit
      received(data)
      stdin.readInBackgroundAndNotify
    })
  stdin.readInBackgroundAndNotify

  const loop = $.NSRunLoop.currentRunLoop
  let last = Date.now()
  while (open) {
    loop.runModeBeforeDate($.NSDefaultRunLoopMode, $.NSDate.dateWithTimeIntervalSinceNow(IDLE_EXIT))
    if (busy !== null || jobs.length) last = Date.now()
    else if (Date.now() - last >= IDLE_EXIT * 1000) break
  }
}
