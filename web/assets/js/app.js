// Raxol Playground JavaScript
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

// Phoenix LiveView hooks
let Hooks = {}

// Copy to Clipboard Hook
Hooks.CopyToClipboard = {
  mounted() {
    this.el.addEventListener('click', () => {
      const text = this.el.dataset.copy
      if (!text) return

      const announceCopied = () => {
        const status = this.el.querySelector('[data-copy-status]')
        if (status) {
          status.textContent = 'Copied to clipboard'
          setTimeout(() => { status.textContent = '' }, 1500)
        }
      }

      navigator.clipboard.writeText(text).then(announceCopied).catch(() => {
        // Fallback for older browsers
        const textarea = document.createElement('textarea')
        textarea.value = text
        textarea.style.position = 'fixed'
        textarea.style.opacity = '0'
        document.body.appendChild(textarea)
        textarea.select()
        document.execCommand('copy')
        document.body.removeChild(textarea)

        announceCopied()
      })
    })
  }
}

// Code Editor Hook
Hooks.CodeEditor = {
  mounted() {
    this.handleKeydown = (e) => {
      // Cmd+Enter or Ctrl+Enter to run
      if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
        e.preventDefault()
        this.pushEvent("run_component", {})
      }

      // Tab key handling for indentation
      if (e.key === 'Tab') {
        e.preventDefault()
        const start = this.el.selectionStart
        const end = this.el.selectionEnd
        const value = this.el.value
        this.el.value = value.substring(0, start) + '  ' + value.substring(end)
        this.el.selectionStart = this.el.selectionEnd = start + 2

        // Trigger change event
        const event = new Event('input', { bubbles: true })
        this.el.dispatchEvent(event)
      }
    }

    this.el.addEventListener('keydown', this.handleKeydown)
  },

  updated() {},

  destroyed() {
    if (this.handleKeydown) {
      this.el.removeEventListener('keydown', this.handleKeydown)
    }
  }
}

// Terminal Output Hook
Hooks.TerminalOutput = {
  mounted() { this.scrollToBottom() },
  updated() { this.scrollToBottom() },
  scrollToBottom() { this.el.scrollTop = this.el.scrollHeight }
}

// Flash Hook - auto-dismiss flash messages
Hooks.Flash = {
  mounted() {
    this.timer = setTimeout(() => {
      this.pushEvent("lv:clear-flash", {})
    }, 5000)
  },
  destroyed() {
    if (this.timer) clearTimeout(this.timer)
  }
}

// Raxol Terminal Hook - renders demo output via direct innerHTML injection.
// Raw HTML from TerminalBridge changes structure every frame. LiveView's
// morphdom differ can't patch it reliably, so we bypass it: the server
// pushes terminal_html via push_event, and this hook sets innerHTML directly.
Hooks.RaxolTerminal = {
  mounted() {
    // Focus for keyboard input AND translate the click to buffer cell
    // coordinates so on_click widgets (buttons, checkboxes) respond to
    // the mouse like they do under a terminal mouse driver. The server
    // hit-tests the cell against the positioned layout.
    this.el.addEventListener('click', (e) => {
      this.el.focus()
      const cell = this.clickCell(e)
      if (cell) this.pushEvent("terminal_click", cell)
    })

    this.el.addEventListener('focus', () => {
      this.el.style.outline = '2px solid rgba(88, 161, 198, 0.4)'
      this.el.style.outlineOffset = '-2px'
    })
    this.el.addEventListener('blur', () => {
      this.el.style.outline = 'none'
    })

    this.noScroll = this.el.dataset.noScroll === "true"

    // Receive terminal HTML directly, bypassing LiveView differ
    this.handleEvent("terminal_html", ({html}) => {
      this.el.innerHTML = html
      if (!this.noScroll) this.scrollToBottom()
    })

    // Demo switching: show spinner while new demo starts
    this.handleEvent("terminal_reset", () => {
      this.el.innerHTML =
        '<div class="py-8 text-center font-mono" style="color: rgba(232, 228, 220, 0.4);">' +
        '<div class="loading-spinner mb-3 mx-auto"></div>' +
        '<p>Starting demo...</p></div>'
    })

    // Server can ask us to focus after patch navigation between demos
    this.handleEvent("focus_terminal", () => {
      this.el.focus()
      if (!this.noScroll) this.scrollToBottom()
    })

    // Demo error: show message with retry button
    this.handleEvent("terminal_error", ({message}) => {
      this.el.innerHTML =
        '<div class="py-8 text-center font-mono">' +
        '<p class="mb-4" style="color: #c75a6a;">' +
        message.replace(/</g, '&lt;').replace(/>/g, '&gt;') +
        '</p>' +
        '<button class="raxol-retry-btn" style="font-size: 0.75rem; padding: 0.5rem 1.25rem; ' +
        'border: 1px solid rgba(88, 161, 198, 0.3); border-radius: 0.375rem; ' +
        'color: #58a1c6; background: rgba(88, 161, 198, 0.08); cursor: pointer;">Retry</button></div>'
      const btn = this.el.querySelector('.raxol-retry-btn')
      if (btn) btn.addEventListener('click', () => this.pushEvent("retry_demo", {}))
    })

    if (!this.noScroll) {
      this.el.focus()
      this.scrollToBottom()
    }
  },

  updated() {
    if (!this.noScroll) this.scrollToBottom()
  },

  // Pixel offset -> buffer cell. Cell metrics are measured live (a probe
  // span for the char width, computed line-height for the row height)
  // because the injected <pre> is replaced every frame and themes can
  // change the font.
  clickCell(e) {
    const pre = this.el.querySelector('pre')
    if (!pre) return null
    const rect = pre.getBoundingClientRect()
    const probe = document.createElement('span')
    probe.textContent = '0'.repeat(100)
    probe.style.cssText = 'position:absolute;visibility:hidden;white-space:pre'
    pre.appendChild(probe)
    const cw = probe.getBoundingClientRect().width / 100
    probe.remove()
    const cs = getComputedStyle(pre)
    const lh = parseFloat(cs.lineHeight) || parseFloat(cs.fontSize)
    if (!cw || !lh) return null
    const x = Math.floor((e.clientX - rect.left + pre.scrollLeft) / cw)
    const y = Math.floor((e.clientY - rect.top + pre.scrollTop) / lh)
    if (x < 0 || y < 0) return null
    return {x, y}
  },

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}

// Hero surface-tabbed demo. All content is server-rendered; this hook only
// toggles hidden/aria-selected: it auto-advances the surface tabs and steps
// the recorded terminal frames on a fixed-timestep rAF accumulator
// (while-loop catch-up keeps wall-clock lockstep on any refresh rate).
// Clicking a tab stops the auto-advance. Reduced motion pauses everything,
// with a live change listener; the pause button is the manual override.
// When the server swaps in the live session (data-live), the player stops.
Hooks.HeroDemo = {
  // Fallback only. The real rate comes from the recording via data-frame-ms:
  // the generator samples each example at its module's own tick and writes
  // that beside the frames, so playback runs at the speed the program runs.
  // A constant here was a second place the frame rate lived, and the two had
  // drifted -- 850ms playback over a recording sampled every 280ms.
  FRAME_MS: 100,
  TAB_MS: 3400,

  mounted() {
    this.tab = 0
    this.frame = 0
    const declared = parseInt(this.el.dataset.frameMs, 10)
    if (Number.isFinite(declared) && declared > 0) this.FRAME_MS = declared
    this.autoTabs = true
    this.acc = {frame: 0, tab: 0}
    this.raf = null

    this.mql = window.matchMedia('(prefers-reduced-motion: reduce)')
    this.userPaused = this.mql.matches
    this.onMql = (e) => this.setPaused(e.matches)
    this.mql.addEventListener('change', this.onMql)

    // Delegated clicks survive LiveView patches of the children.
    this.onClick = (e) => {
      const tabBtn = e.target.closest('.hero-tab')
      if (tabBtn && this.el.contains(tabBtn)) {
        this.autoTabs = false
        this.showTab(parseInt(tabBtn.dataset.i, 10))
        return
      }
      const pauseBtn = e.target.closest('[data-role="player-pause"]')
      if (pauseBtn && this.el.contains(pauseBtn)) {
        this.setPaused(!this.userPaused)
      }
    }
    this.el.addEventListener('click', this.onClick)

    this.syncPauseLabel()
    this.sync()
  },

  updated() {
    // A patch may or may not have touched the toggled attributes; derive
    // state from the DOM rather than assuming.
    const sel = this.el.querySelector('.hero-tab[aria-selected="true"]')
    this.tab = sel ? parseInt(sel.dataset.i, 10) : 0
    const vis = this.el.querySelector('.hero-frames [data-frame]:not([hidden])')
    this.frame = vis ? parseInt(vis.dataset.frame, 10) : 0
    this.syncPauseLabel()
    this.sync()
  },

  destroyed() {
    this.stopLoop()
    this.mql.removeEventListener('change', this.onMql)
    this.el.removeEventListener('click', this.onClick)
  },

  live() { return this.el.dataset.live === 'true' },
  playing() { return !this.live() && !this.userPaused },

  setPaused(v) {
    this.userPaused = v
    this.syncPauseLabel()
    this.sync()
  },

  // Glyph for sight, label for everything else: `||` and `|>` carry no meaning
  // to a screen reader, so the accessible name is the word and is kept in step
  // with the glyph here rather than left on the markup's initial value.
  syncPauseLabel() {
    const btn = this.el.querySelector('[data-role="player-pause"]')
    if (!btn) return
    const label = this.userPaused ? 'Play the demo' : 'Pause the demo'
    btn.textContent = this.userPaused ? '|>' : '||'
    btn.setAttribute('aria-label', label)
    btn.setAttribute('title', label)
  },

  sync() {
    if (this.playing()) this.startLoop()
    else this.stopLoop()
  },

  startLoop() {
    if (this.raf) return
    this.last = undefined
    if (!this.step) {
      this.step = (ts) => {
        if (this.last === undefined) this.last = ts
        // Clamp dt: rAF suspends in background tabs, and an unclamped
        // accumulator would fast-forward the whole hidden interval on return.
        const dt = Math.min(ts - this.last, 1000)
        this.last = ts
        this.acc.frame += dt
        this.acc.tab += dt
        while (this.acc.frame >= this.FRAME_MS) {
          this.acc.frame -= this.FRAME_MS
          this.nextFrame()
        }
        while (this.acc.tab >= this.TAB_MS) {
          this.acc.tab -= this.TAB_MS
          if (this.autoTabs) this.showTab((this.tab + 1) % this.tabCount())
        }
        this.raf = requestAnimationFrame(this.step)
      }
    }
    this.raf = requestAnimationFrame(this.step)
  },

  stopLoop() {
    if (this.raf) {
      cancelAnimationFrame(this.raf)
      this.raf = null
    }
  },

  tabCount() {
    return this.el.querySelectorAll('.hero-tab').length
  },

  nextFrame() {
    const frames = this.el.querySelectorAll('.hero-frames [data-frame]')
    if (frames.length < 2) return
    // Count DISTINCT indices, not elements: two panes now carry the same
    // sequence (the terminal frame and the ANSI the SSH pane paints), so
    // element count is a multiple of the real frame count and using it would
    // step past every index and blank both panes.
    //
    // Indices are filtered rather than trusted: one unparseable `data-frame`
    // makes `Math.max` NaN, `% NaN` NaN, and then no element's index equals
    // `this.frame`, so every pane hides and the hero goes blank and stays
    // blank. Falling back to the element count animates something wrong; the
    // frames themselves are still on the page either way.
    const indices = Array.from(frames, (f) => parseInt(f.dataset.frame, 10)).filter(
      (n) => Number.isInteger(n) && n >= 0
    )
    if (indices.length < 2) return
    const count = 1 + Math.max(...indices)
    this.frame = (this.frame + 1) % count
    frames.forEach((f) => {
      f.hidden = parseInt(f.dataset.frame, 10) !== this.frame
    })
  },

  showTab(n) {
    this.tab = n
    const tabs = this.el.querySelectorAll('.hero-tab')
    tabs.forEach((t) => {
      t.setAttribute('aria-selected', String(parseInt(t.dataset.i, 10) === n))
    })
    this.el.querySelectorAll('.hero-out').forEach((o) => {
      o.hidden = parseInt(o.dataset.surface, 10) !== n
    })
    const active = tabs[n]
    const title = this.el.querySelector('[data-role="title"]')
    if (active && title) title.textContent = active.dataset.title
  }
}

// Keyboard parity with the mix raxol.playground TUI: j/k navigate
// components, c toggles the code panel, ? toggles the shortcuts overlay.
// Guarded so keystrokes aimed at the demo terminal, the search box, or
// any form field pass through untouched. Pages configure it via
// data-terminal (the demo terminal's id) and data-keys (which of
// jk/c/? this page handles -- the hook must not push events the
// LiveView has no handler for).
Hooks.PlaygroundKeys = {
  mounted() {
    this.termId = this.el.dataset.terminal || 'playground-terminal'
    this.keys = (this.el.dataset.keys || 'jk,c,?').split(',')
    this.onKey = (e) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return
      const ae = document.activeElement
      const tag = ae && ae.tagName
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' ||
          (ae && ae.isContentEditable)) return
      // The focused terminal owns every key (the TUI's :demo focus mode);
      // Escape is the way back, mirroring "Esc back".
      if (ae && ae.id === this.termId) {
        if (e.key === 'Escape') ae.blur()
        return
      }
      if (this.keys.includes('jk') && e.key === 'j') this.pushEvent('nav_component', {dir: 'next'})
      else if (this.keys.includes('jk') && e.key === 'k') this.pushEvent('nav_component', {dir: 'prev'})
      else if (this.keys.includes('c') && e.key === 'c') this.pushEvent('toggle_code', {})
      else if (this.keys.includes('?') && e.key === '?') this.pushEvent('toggle_shortcuts', {})
      else return
      e.preventDefault()
    }
    document.addEventListener('keydown', this.onKey)
  },
  destroyed() {
    document.removeEventListener('keydown', this.onKey)
  }
}

// Motion preference reporter. CSS media queries can gate stylesheet
// animation but not server-pushed terminal frames, so the LiveView needs
// to know. Reports at connect (only when reduce is on) and on every
// preference change, live, not just once at mount.
Hooks.MotionPref = {
  mounted() {
    this.mql = window.matchMedia('(prefers-reduced-motion: reduce)')
    this.report = () => this.pushEvent("motion_pref", {reduce: this.mql.matches})
    this.mql.addEventListener('change', this.report)
    if (this.mql.matches) this.report()
  },
  destroyed() {
    if (this.mql) this.mql.removeEventListener('change', this.report)
  }
}

// Install-method tabs (hero). All four panes ship server-rendered; this
// only toggles which is visible, so no server round trip and the curl
// pane shows before JS loads. Delegated click survives LiveView patches.
// The hero brand mark: the axol face (AxolFace.glyph/3 frames, exported by
// the server in data-faces) dithered into character cells, framed by a
// drifting edge texture -- the Halo treatment. Face and halo are two
// separate tones that never mix: the face draws from the block ramp only
// (alpha 0.58-1.0), the halo from the punctuation ramp (alpha 0.05-0.37).
// Reduced motion renders one static frame mid-pass, never the empty t=0.
Hooks.HaloField = {
  FACE_RAMP: '░▒▓█',
  HALO_RAMP: '·:-=+*#%',
  FRAME_MS: 110,
  EYE_MS: 500,
  STATE_MS: 2600,

  mounted() {
    this.canvas = this.el.querySelector('canvas')
    this.ctx = this.canvas.getContext('2d')
    this.faces = JSON.parse(this.el.dataset.faces)
    this.stateIdx = 0
    this.frameIdx = 0
    this.t = 0
    this.acc = {frame: 0, eye: 0, state: 0}
    this.raf = null

    const rootStyle = getComputedStyle(document.documentElement)
    this.faceColor = rootStyle.getPropertyValue('--axol-coral').trim() || '#ffcd9c'
    this.haloColor = rootStyle.getPropertyValue('--pearl-cream').trim() || '#e8e4dc'
    this.fontFamily = getComputedStyle(this.el).fontFamily

    this.mql = window.matchMedia('(prefers-reduced-motion: reduce)')
    this.onMql = () => this.sync()
    this.mql.addEventListener('change', this.onMql)

    this.onResize = () => {
      clearTimeout(this.resizeTimer)
      this.resizeTimer = setTimeout(() => { this.layout(); this.sync() }, 200)
    }
    window.addEventListener('resize', this.onResize)

    this.layout()
    this.sync()
  },

  destroyed() {
    if (this.raf) cancelAnimationFrame(this.raf)
    clearTimeout(this.resizeTimer)
    this.mql.removeEventListener('change', this.onMql)
    window.removeEventListener('resize', this.onResize)
  },

  face() { return this.faces[this.stateIdx].frames[this.frameIdx % 4] },

  // Measure the character grid, size the backing store for the device
  // pixel ratio, and rebuild the face coverage mask.
  layout() {
    const rect = this.el.getBoundingClientRect()
    if (rect.width === 0 || rect.height === 0) return
    const dpr = window.devicePixelRatio || 1
    this.w = rect.width
    this.h = rect.height
    this.canvas.width = Math.round(this.w * dpr)
    this.canvas.height = Math.round(this.h * dpr)
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0)

    // Definition comes from the row count, not the type size: the face's gill
    // bars and eye dots need cells to resolve into ≡··≡ rather than a blob.
    // So the cell is sized to hold a target number of rows at any box height
    // -- a fixed cell turns a taller mark into bigger blocks rather than a
    // finer one.
    //
    // 40 rows, not 30. Because the cell scales with the box, growing the mark
    // alone bought bigger blocks at the same 26-row grid, which is a coarser
    // face, not a larger one. The target row count is the only thing that
    // makes it finer. The floor drops with it: these are solid block glyphs
    // (░▒▓█), not letterforms, so they stay legible well under 5px where text
    // would not.
    this.fontPx = Math.max(4.5, Math.min(10, this.h / 40))
    this.ctx.font = `${this.fontPx}px ${this.fontFamily}`
    this.cellW = this.ctx.measureText('█').width || this.fontPx * 0.6
    this.cellH = Math.round(this.fontPx * 1.15)
    this.cols = Math.max(8, Math.floor(this.w / this.cellW))
    this.rows = Math.max(4, Math.floor(this.h / this.cellH))
    this.buildMask()
  },

  // Draw the face string to an offscreen canvas supersampled 3x per axis,
  // then box-filter each 3x3 block to a per-cell coverage fraction.
  buildMask() {
    const S = 3
    const off = document.createElement('canvas')
    off.width = this.cols * S
    off.height = this.rows * S
    const octx = off.getContext('2d', {willReadFrequently: true})

    // Size the glyph from a share of the grid's WIDTH, capped by height, so
    // the face keeps the same proportion whether the mark is a wide banner or
    // an upright box. Sizing from height alone blew a portrait mark up into
    // four chunky blocks that read as texture rather than a face.
    const glyph = this.face()
    octx.font = `100px ${this.fontFamily}`
    const unit = octx.measureText(glyph).width / 100
    // A larger share of the grid than it was: with a finer cell the keep-out
    // ring costs proportionally less room, so the face can take more of the
    // box without the halo losing the frame it needs.
    const px = Math.min((off.width * 0.52) / unit, off.height * 0.46)
    octx.font = `${px}px ${this.fontFamily}`
    octx.fillStyle = '#fff'
    octx.textAlign = 'center'
    octx.textBaseline = 'middle'
    octx.fillText(glyph, off.width / 2, off.height * 0.54)

    const data = octx.getImageData(0, 0, off.width, off.height).data
    this.mask = new Float32Array(this.cols * this.rows)
    for (let y = 0; y < this.rows; y++) {
      for (let x = 0; x < this.cols; x++) {
        let sum = 0
        for (let sy = 0; sy < S; sy++) {
          for (let sx = 0; sx < S; sx++) {
            sum += data[((y * S + sy) * off.width + (x * S + sx)) * 4 + 3]
          }
        }
        this.mask[y * this.cols + x] = sum / (S * S * 255)
      }
    }

    // Dilated keep-out (3 cells x, 2 cells y) so the halo texture tracks
    // the glyph outline instead of crowding it.
    this.keepOut = new Uint8Array(this.cols * this.rows)
    for (let y = 0; y < this.rows; y++) {
      for (let x = 0; x < this.cols; x++) {
        if (this.mask[y * this.cols + x] <= 0.2) continue
        for (let dy = -2; dy <= 2; dy++) {
          for (let dx = -3; dx <= 3; dx++) {
            const nx = x + dx, ny = y + dy
            if (nx >= 0 && nx < this.cols && ny >= 0 && ny < this.rows) {
              this.keepOut[ny * this.cols + nx] = 1
            }
          }
        }
      }
    }
  },

  // Hash-based 2D value noise with smoothstep interpolation.
  hash(x, y) {
    let h = (Math.imul(x, 374761393) + Math.imul(y, 668265263)) ^ 1274126177
    h = Math.imul(h ^ (h >>> 13), 1274126177)
    return ((h ^ (h >>> 16)) >>> 0) / 4294967295
  },

  noise(fx, fy) {
    const x0 = Math.floor(fx), y0 = Math.floor(fy)
    const tx = fx - x0, ty = fy - y0
    const sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
    const a = this.hash(x0, y0), b = this.hash(x0 + 1, y0)
    const c = this.hash(x0, y0 + 1), d = this.hash(x0 + 1, y0 + 1)
    return a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy
  },

  sync() {
    if (this.mql.matches) {
      this.stopLoop()
      // One static frame mid-pass: idle face, drift field at a non-zero
      // phase, so reduced motion still gets a composed image.
      this.stateIdx = 0
      this.frameIdx = 0
      this.t = 37
      this.buildMask()
      this.draw()
    } else {
      this.startLoop()
    }
  },

  startLoop() {
    if (this.raf) return
    // Paint immediately: the first accumulator tick is ~110ms away, and
    // the hero must never show a blank mark while waiting for it.
    this.draw()
    this.last = undefined
    const step = (ts) => {
      if (this.last === undefined) this.last = ts
      // Clamp dt: rAF suspends in background tabs, and an unclamped
      // accumulator would fast-forward the whole hidden interval.
      const dt = Math.min(ts - this.last, 1000)
      this.last = ts
      this.acc.frame += dt
      this.acc.eye += dt
      this.acc.state += dt
      let dirty = false
      while (this.acc.frame >= this.FRAME_MS) {
        this.acc.frame -= this.FRAME_MS
        this.t += 1
        dirty = true
      }
      let faceDirty = false
      while (this.acc.eye >= this.EYE_MS) {
        this.acc.eye -= this.EYE_MS
        this.frameIdx += 1
        faceDirty = true
      }
      while (this.acc.state >= this.STATE_MS) {
        this.acc.state -= this.STATE_MS
        this.stateIdx = (this.stateIdx + 1) % this.faces.length
        this.frameIdx = 0
        faceDirty = true
      }
      if (faceDirty) this.buildMask()
      if (dirty || faceDirty) this.draw()
      this.raf = requestAnimationFrame(step)
    }
    this.raf = requestAnimationFrame(step)
  },

  stopLoop() {
    if (this.raf) cancelAnimationFrame(this.raf)
    this.raf = null
  },

  draw() {
    if (!this.mask) return
    const ctx = this.ctx
    ctx.clearRect(0, 0, this.w, this.h)
    ctx.font = `${this.fontPx}px ${this.fontFamily}`
    ctx.textBaseline = 'top'
    const t = this.t * 0.045

    for (let y = 0; y < this.rows; y++) {
      for (let x = 0; x < this.cols; x++) {
        const cov = this.mask[y * this.cols + x]
        const cx = x * this.cellW
        const cy = y * this.cellH

        if (cov > 0.2) {
          // Face: threshold then rescale with a floor, so a half-covered
          // edge cell still lands on a solid block.
          // Rescale hard: a cell inside the glyph should read as solid,
          // not as a probability. The old floor (0.3) plus a 0.58 alpha
          // base left edge cells at ~64% opacity on a mid ramp glyph,
          // which is what made the mark look soft.
          const c = 0.55 + 0.45 * ((cov - 0.2) / 0.8)
          const g = this.FACE_RAMP[Math.min(3, Math.floor(c * 4))]
          ctx.globalAlpha = 0.78 + 0.22 * c
          ctx.fillStyle = this.faceColor
          ctx.fillText(g, cx, cy)
          continue
        }
        if (this.keepOut[y * this.cols + x]) continue

        // Halo: edge weight is the PRODUCT of per-axis depths (max would
        // draw a rectangle), raised to push texture toward the frame, and
        // the boundary is jittered by the drift noise itself.
        const centX = 1 - Math.abs((2 * x) / (this.cols - 1) - 1)
        const centY = 1 - Math.abs((2 * y) / (this.rows - 1) - 1)
        const n = this.noise(x * 0.3 + t * 0.5, y * 0.5 + t * 0.12)
        const edge = Math.pow(Math.max(0, 1 - centX * centY), 1.6)
        const w = Math.max(0, Math.min(1, edge + (n - 0.5) * 0.3))
        const v = n * w
        if (v < 0.14) continue
        const idx = Math.min(7, Math.floor(((v - 0.14) / 0.86) * 8))
        // Dimmer than it was: the halo is a frame for the face, and at the
        // old ceiling it competed with it at small sizes.
        ctx.globalAlpha = 0.04 + 0.24 * ((v - 0.14) / 0.86)
        ctx.fillStyle = this.haloColor
        ctx.fillText(this.HALO_RAMP[idx], cx, cy)
      }
    }
    ctx.globalAlpha = 1
  }
}

// Initialize LiveSocket
let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Global keyboard shortcuts
document.addEventListener('DOMContentLoaded', () => {
  document.addEventListener('keydown', (e) => {
    // Skip when typing in a real form field; we don't want to hijack search
    // boxes or text inputs the user is actively using.
    const ae = document.activeElement
    const tag = ae && ae.tagName
    const inField = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' ||
      (ae && ae.isContentEditable)

    // Cmd+K or Ctrl+K for search
    if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
      e.preventDefault()
      const searchInput = document.querySelector('input[placeholder="Search..."]') ||
        document.querySelector('input[placeholder="Search components..."]')
      if (searchInput) searchInput.focus()
      return
    }

    // "/" focuses the demo terminal so users can type without first clicking
    // the rendered text input. Skip when typing in a real form field, when a
    // modifier is held, or when the terminal is already focused.
    if (e.key === '/' && !e.metaKey && !e.ctrlKey && !e.altKey && !inField) {
      const terminal = document.querySelector('#demo-terminal') ||
        document.querySelector('#playground-terminal')
      if (terminal && document.activeElement !== terminal) {
        e.preventDefault()
        terminal.focus()
      }
      return
    }

    // "[" / "]" navigate prev/next on /demos/{name}. Bracket keys are not
    // used as input by any catalog demo. When the terminal has focus we let
    // the keystroke through to the demo (some future demo may want them).
    if ((e.key === '[' || e.key === ']') && !e.metaKey && !e.ctrlKey && !e.altKey && !inField) {
      const terminal = document.querySelector('#demo-terminal')
      if (terminal && document.activeElement === terminal) return

      const sel = e.key === '['
        ? 'a[aria-label^="Previous demo:"]'
        : 'a[aria-label^="Next demo:"]'
      const link = document.querySelector(sel)
      if (link) {
        e.preventDefault()
        link.click()
      }
    }
  })
})

// Connect if there are any LiveViews on the page
liveSocket.connect()

// Expose liveSocket on window for web console debug logs
window.liveSocket = liveSocket
