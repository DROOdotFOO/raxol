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
    this.el.addEventListener('click', () => this.el.focus())

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

  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
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
