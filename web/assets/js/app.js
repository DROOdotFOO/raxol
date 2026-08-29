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
  FRAME_MS: 850,
  TAB_MS: 3400,

  mounted() {
    this.tab = 0
    this.frame = 0
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

  syncPauseLabel() {
    const btn = this.el.querySelector('[data-role="player-pause"]')
    if (btn) btn.textContent = this.userPaused ? 'play' : 'pause'
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
    this.frame = (this.frame + 1) % frames.length
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
    const label = this.el.querySelector('[data-role="out-label"]')
    if (active && title) title.textContent = active.dataset.title
    if (active && label) label.textContent = active.dataset.label
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
Hooks.InstallTabs = {
  mounted() {
    this.onClick = (e) => {
      const btn = e.target.closest('.install-tab')
      if (!btn || !this.el.contains(btn)) return
      const method = btn.dataset.m
      this.el.querySelectorAll('.install-tab').forEach((tab) => {
        tab.setAttribute('aria-selected', tab.dataset.m === method ? 'true' : 'false')
      })
      this.el.querySelectorAll('.install-pane').forEach((pane) => {
        pane.hidden = pane.dataset.m !== method
      })
    }
    this.el.addEventListener('click', this.onClick)
  },
  destroyed() {
    this.el.removeEventListener('click', this.onClick)
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
