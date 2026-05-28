# Deployment Guide

## Options

### [Fly.io](FLY_IO.md): Primary Production

Phoenix LiveView playground with full backend. Auto-scaling, WebSocket support, PostgreSQL.

- **URL**: https://raxol.io
- **Deploy**: `flyctl deploy`

## Quick Start

```bash
brew install flyctl
flyctl auth login
flyctl deploy
flyctl status --app raxol
```

## Infrastructure

- **Primary**: Fly.io (production app)
- **CDN**: Cloudflare Pages (static assets, optional)
- **Metrics**: GitHub Pages (performance dashboard)

See [FLY_IO.md](FLY_IO.md) for full infrastructure details.
