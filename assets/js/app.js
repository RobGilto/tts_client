// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/tts_client"
import topbar from "../vendor/topbar"

// Audio Player Hook for streaming TTS playback
const AudioPlayer = {
  mounted() {
    // Initialize AudioContext immediately (will be suspended until user interaction)
    this.audioContext = new (window.AudioContext || window.webkitAudioContext)()
    this.audioBuffers = new Map()  // Index -> AudioBuffer (ordered storage)
    this.isPlaying = false
    this.totalChunks = 0
    this.playedChunks = 0
    this.nextToPlay = 0  // Next chunk index to play
    this.audioContextReady = Promise.resolve()  // Promise to track AudioContext readiness
    this.pendingChunks = []  // Store chunks that arrive before AudioContext is ready

    // Waiting sound setup
    this.waitingGain = null
    this.waitingOscillators = []
    this.isWaitingSoundPlaying = false
    this.setupWaitingSound()

    // Handle start of TTS job
    this.handleEvent("tts_start", ({total_chunks}) => {
      this.totalChunks = total_chunks
      this.playedChunks = 0
      this.nextToPlay = 0
      this.audioBuffers = new Map()
      this.pendingChunks = []
      this.isPlaying = false
      this.updatePlaybackStatus("Starting...")
      this.updatePlaybackProgress(0)

      // Resume AudioContext if suspended (required by browsers after user interaction)
      // Store the promise so chunks can wait for it
      if (this.audioContext.state === 'suspended') {
        this.audioContextReady = this.audioContext.resume()
      } else {
        this.audioContextReady = Promise.resolve()
      }

      // Start waiting sound immediately (will fade in)
      this.audioContextReady.then(() => this.startWaitingSound())
    })

    // Handle incoming audio chunk
    this.handleEvent("tts_chunk", ({index, wav}) => {
      // Process chunk after AudioContext is ready
      this.audioContextReady.then(async () => {
        try {
          // Decode base64 WAV to ArrayBuffer
          const binaryString = atob(wav)
          const bytes = new Uint8Array(binaryString.length)
          for (let i = 0; i < binaryString.length; i++) {
            bytes[i] = binaryString.charCodeAt(i)
          }

          // Decode audio data
          const audioBuffer = await this.audioContext.decodeAudioData(bytes.buffer.slice(0))

          // Store by index for proper ordering
          this.audioBuffers.set(index, audioBuffer)

          // Try to play next chunk in sequence
          this.tryPlayNext()
        } catch (error) {
          console.error("Error decoding audio chunk:", error)
        }
      })
    })

    // Handle job completion
    this.handleEvent("tts_complete", () => {
      this.stopWaitingSound()
      this.updatePlaybackStatus("Complete!")
    })

    // Handle error
    this.handleEvent("tts_error", ({error}) => {
      this.stopWaitingSound()
      this.updatePlaybackStatus(`Error: ${error}`)
    })
  },

  tryPlayNext() {
    // Only start if not already playing and we have the next chunk in sequence
    if (!this.isPlaying && this.audioBuffers.has(this.nextToPlay)) {
      this.playNext()
    }
  },

  playNext() {
    // Check if we have the next chunk to play
    if (!this.audioBuffers.has(this.nextToPlay)) {
      this.isPlaying = false
      // Start waiting sound if we're still expecting more chunks
      if (this.nextToPlay < this.totalChunks) {
        this.startWaitingSound()
      }
      return
    }

    // Fade out waiting sound before playing speech
    this.stopWaitingSound()

    this.isPlaying = true
    const index = this.nextToPlay
    const buffer = this.audioBuffers.get(index)

    // Remove from map after retrieving
    this.audioBuffers.delete(index)
    this.nextToPlay++

    const source = this.audioContext.createBufferSource()
    source.buffer = buffer
    source.connect(this.audioContext.destination)

    this.updatePlaybackStatus(`Playing sentence ${index + 1}/${this.totalChunks}`)

    source.onended = () => {
      this.playedChunks++
      this.updatePlaybackProgress(this.playedChunks / this.totalChunks * 100)
      this.playNext()
    }

    source.start(0)
  },

  // Setup the ambient waiting sound (soft pulsing tone)
  setupWaitingSound() {
    // Create a gain node for volume control and fading
    this.waitingGain = this.audioContext.createGain()
    this.waitingGain.gain.value = 0
    this.waitingGain.connect(this.audioContext.destination)
  },

  startWaitingSound() {
    if (this.isWaitingSoundPlaying) return

    this.isWaitingSoundPlaying = true

    // Create soft ambient tones (low frequency, gentle)
    const frequencies = [220, 277.18, 329.63] // A3, C#4, E4 - A major chord
    this.waitingOscillators = []

    frequencies.forEach((freq, i) => {
      const osc = this.audioContext.createOscillator()
      const oscGain = this.audioContext.createGain()

      osc.type = 'sine'
      osc.frequency.value = freq
      oscGain.gain.value = 0.03 // Very quiet

      osc.connect(oscGain)
      oscGain.connect(this.waitingGain)
      osc.start()

      this.waitingOscillators.push({ osc, gain: oscGain })
    })

    // Create a subtle LFO for pulsing effect
    this.lfo = this.audioContext.createOscillator()
    this.lfoGain = this.audioContext.createGain()
    this.lfo.type = 'sine'
    this.lfo.frequency.value = 0.5 // Slow pulse (0.5 Hz)
    this.lfoGain.gain.value = 0.015 // Modulation depth
    this.lfo.connect(this.lfoGain)
    this.lfoGain.connect(this.waitingGain.gain)
    this.lfo.start()

    // Fade in the waiting sound
    const now = this.audioContext.currentTime
    this.waitingGain.gain.setValueAtTime(0, now)
    this.waitingGain.gain.linearRampToValueAtTime(0.06, now + 0.5) // Fade in over 0.5s
  },

  stopWaitingSound() {
    if (!this.isWaitingSoundPlaying) return

    // Fade out
    const now = this.audioContext.currentTime
    this.waitingGain.gain.setValueAtTime(this.waitingGain.gain.value, now)
    this.waitingGain.gain.linearRampToValueAtTime(0, now + 0.3) // Fade out over 0.3s

    // Stop oscillators after fade
    setTimeout(() => {
      this.waitingOscillators.forEach(({ osc }) => {
        try { osc.stop() } catch (e) {}
      })
      this.waitingOscillators = []

      if (this.lfo) {
        try { this.lfo.stop() } catch (e) {}
        this.lfo = null
      }

      this.isWaitingSoundPlaying = false
    }, 350)
  },

  updatePlaybackStatus(text) {
    const statusEl = document.getElementById("playback-status")
    if (statusEl) statusEl.textContent = text
  },

  updatePlaybackProgress(percent) {
    const progressEl = document.getElementById("playback-progress")
    if (progressEl) progressEl.style.width = `${percent}%`
  },

  destroyed() {
    this.stopWaitingSound()
    if (this.audioContext) {
      this.audioContext.close()
    }
  }
}

const Hooks = {
  ...colocatedHooks,
  AudioPlayer
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks,
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

