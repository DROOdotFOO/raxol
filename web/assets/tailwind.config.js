module.exports = {
  content: [
    './js/**/*.js',
    '../lib/*_web.ex',
    '../lib/*_web/**/*.*ex'
  ],
  theme: {
    extend: {
      colors: {
        // Core surfaces
        obsidian: '#0a0a0c',
        'deep-night': '#12121a',
        'synthwave-bg': '#241b2f',

        // Text
        pearl: {
          DEFAULT: '#e8e4dc',
          80: 'rgba(232, 228, 220, 0.8)',
          70: 'rgba(232, 228, 220, 0.7)',
          60: 'rgba(232, 228, 220, 0.6)',
          50: 'rgba(232, 228, 220, 0.5)',
          45: 'rgba(232, 228, 220, 0.45)',
          40: 'rgba(232, 228, 220, 0.4)',
          35: 'rgba(232, 228, 220, 0.35)',
          30: 'rgba(232, 228, 220, 0.3)',
          25: 'rgba(232, 228, 220, 0.25)',
          20: 'rgba(232, 228, 220, 0.2)',
          15: 'rgba(232, 228, 220, 0.15)',
        },
        frost: '#fdfff9',

        // Accents
        'axol-coral': '#ffcd9c',
        'coral-red': '#e58476',
        sky: {
          DEFAULT: '#58a1c6',
          10: 'rgba(88, 161, 198, 0.1)',
          15: 'rgba(88, 161, 198, 0.15)',
          25: 'rgba(88, 161, 198, 0.25)',
          40: 'rgba(88, 161, 198, 0.4)',
        },
        'indigo-deep': '#28338b',
        gold: {
          DEFAULT: '#a89a80',
          8: 'rgba(168, 154, 128, 0.08)',
          12: 'rgba(168, 154, 128, 0.12)',
          20: 'rgba(168, 154, 128, 0.2)',
          40: 'rgba(168, 154, 128, 0.4)',
        },
        coral: {
          10: 'rgba(255, 205, 156, 0.1)',
          15: 'rgba(255, 205, 156, 0.15)',
          25: 'rgba(255, 205, 156, 0.25)',
          40: 'rgba(255, 205, 156, 0.4)',
        },

        // Surfaces (for bg-)
        'panel': 'rgba(18, 18, 26, 0.85)',
        'panel-elevated': 'rgba(18, 18, 26, 0.9)',
        'panel-strong': 'rgba(18, 18, 26, 0.95)',
        'panel-subtle': 'rgba(18, 18, 26, 0.7)',
        'inset': 'rgba(10, 10, 12, 0.5)',
        'obsidian-80': 'rgba(10, 10, 12, 0.8)',
        'obsidian-85': 'rgba(10, 10, 12, 0.85)',
      },
      borderColor: {
        'subtle': 'rgba(168, 154, 128, 0.12)',
        'subtle-hover': 'rgba(168, 154, 128, 0.2)',
        'subtle-faint': 'rgba(168, 154, 128, 0.08)',
      },
      fontFamily: {
        // Mirror the :root --font-* vars in app.css. Monaspace is self-hosted;
        // Fira Code is the runtime fallback before the variable .woff2 swaps in.
        mono: ['"Monaspace Argon"', '"Fira Code"', 'Monaco', 'Menlo', '"Courier New"', 'monospace'],
        heading: ['"Monaspace Xenon"', '"Monaspace Argon"', '"Fira Code"', 'Monaco', 'monospace'],
        body: ['"Monaspace Neon"', '"Monaspace Argon"', '"Fira Code"', 'Monaco', 'monospace'],
      },
      fontSize: {
        'xs': 'clamp(0.55rem, 0.5rem + 0.25vw, 0.65rem)',
        'sm': 'clamp(0.7rem, 0.65rem + 0.25vw, 0.75rem)',
        'base': 'clamp(0.85rem, 0.8rem + 0.25vw, 0.95rem)',
        'lg': 'clamp(1rem, 0.9rem + 0.5vw, 1.15rem)',
        'xl': 'clamp(1.25rem, 1.1rem + 0.75vw, 1.5rem)',
        '2xl': 'clamp(1.5rem, 1.25rem + 1vw, 2rem)',
        '3xl': 'clamp(2rem, 1.5rem + 2vw, 3rem)',
      },
      letterSpacing: {
        'tight': '-0.01em',
        'normal': '0.01em',
        'wide': '0.05em',
        'wider': '0.1em',
        'widest': '0.15em',
      },
      lineHeight: {
        'tight': '1.2',
        'normal': '1.5',
        'relaxed': '1.7',
      },
      borderRadius: {
        'xs': '3px',
        'sm': '4px',
        'pill': '6px',
        'md': '8px',
        'lg': '12px',
        'xl': '16px',
      },
      boxShadow: {
        'glow': '0 4px 20px rgba(255, 205, 156, 0.2)',
        'glow-sky': '0 0 10px rgba(88, 161, 198, 0.12)',
        'glow-coral': '0 0 20px rgba(255, 205, 156, 0.15)',
        'panel': '0 4px 16px rgba(0, 0, 0, 0.2)',
        'elevated': '0 8px 24px rgba(0, 0, 0, 0.25)',
      },
      animation: {
        'float-1': 'floatOrb 20s ease-in-out infinite',
        'float-2': 'floatOrb 25s ease-in-out infinite -5s',
        'float-3': 'floatOrb 22s ease-in-out infinite -10s',
        'pearl-shift': 'pearlShift 20s ease-in-out infinite',
        'fade-in': 'fadeIn 0.3s ease-out',
        'fade-in-up': 'fadeInUp 0.5s ease-out',
        'terminal-type': 'terminalType 0.8s steps(20) forwards',
        'cursor-blink': 'cursorBlink 1s step-end infinite',
        'glow-pulse': 'glowPulse 3s ease-in-out infinite',
      },
      keyframes: {
        floatOrb: {
          '0%, 100%': { transform: 'translate(0, 0) scale(1)' },
          '33%': { transform: 'translate(30px, -30px) scale(1.05)' },
          '66%': { transform: 'translate(-20px, 20px) scale(0.95)' },
        },
        pearlShift: {
          '0%, 100%': { filter: 'hue-rotate(0deg) brightness(1)' },
          '50%': { filter: 'hue-rotate(15deg) brightness(1.1)' },
        },
        fadeIn: {
          from: { opacity: '0' },
          to: { opacity: '1' },
        },
        fadeInUp: {
          from: { opacity: '0', transform: 'translateY(12px)' },
          to: { opacity: '1', transform: 'translateY(0)' },
        },
        terminalType: {
          from: { width: '0' },
          to: { width: '100%' },
        },
        cursorBlink: {
          '0%, 100%': { opacity: '1' },
          '50%': { opacity: '0' },
        },
        glowPulse: {
          '0%, 100%': { boxShadow: '0 0 8px rgba(255, 205, 156, 0.1)' },
          '50%': { boxShadow: '0 0 20px rgba(255, 205, 156, 0.25)' },
        },
      },
    },
  },
  plugins: [],
}
