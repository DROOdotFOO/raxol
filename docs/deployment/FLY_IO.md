# Fly.io Deployment

Raxol uses a multi-tier deployment strategy. Fly.io handles the main application, with optional static hosting on Cloudflare Pages and metrics on GitHub Pages.

## Fly.io (Primary)

**URL:** `https://raxol.io`

The main deployment runs Phoenix LiveView with full Elixir/OTP and WebSocket support.

Current setup:
- 2 machines in SJC region
- Auto-scaling (min: 0, max: dynamic)
- 1GB memory, shared CPU per instance
- Force HTTPS, connection pooling (soft/hard: 1000)

**Config files:**
- `fly.toml` -- app config
- `docker/Dockerfile.web` -- multi-stage Docker build
- Release command: `/app/bin/migrate`

**Deploy:**
```bash
flyctl deploy
flyctl status --app raxol
flyctl logs --app raxol
```

Custom domain support for raxol.io is available. Auto-start/stop keeps costs down when idle.

## Cloudflare Pages (Optional)

Static file CDN. Configured but not required for primary functionality.

- Deploys `web/priv/static` via `.github/workflows/deploy-web.yml`
- Triggered on push to `master`
- No backend, no WebSocket, no LiveView -- static files only
- Good for marketing pages, docs hosting, reducing Fly.io bandwidth

## GitHub Pages (Metrics)

Performance dashboard published to GitHub Pages `/performance` subdirectory.

- Config: `.github/workflows/performance-tracking.yml`
- Deploys `docs/performance` directory via `peaceiris/actions-gh-pages@v4`
- Benchmark results, historical trends, pre-commit timings

## Comparison

| Feature | Fly.io | Cloudflare Pages | GitHub Pages |
|---------|--------|------------------|--------------|
| **Use** | Full app | Static CDN | Metrics |
| **LiveView** | Yes | No | No |
| **WebSockets** | Yes | No | No |
| **Custom Domain** | Yes | Possible | Limited |
| **Auto-scaling** | Yes | CDN | N/A |
| **Cost** | Pay-per-use | Free tier | Free |
| **Deploy** | flyctl/Docker | GitHub Actions | GitHub Actions |

## Architecture

```
                 raxol.io
                    |
        +-----------+-----------+
        |                       |
   Fly.io (Primary)      Cloudflare Pages
   Phoenix LiveView        (Optional CDN)
   raxol.io           Static Assets
        |
        | (Optional)
        v
   PostgreSQL
   (Fly.io managed)
```

Fly.io is primary because it provides the OTP runtime, WebSocket connections for LiveView, and plugin/session management. Cloudflare Pages can offload static content but cannot replace the backend.

## CI/CD

**On push to master:**
1. Tests run (unit, integration, property)
2. Code quality checks (Credo, Dialyzer)
3. Security audit
4. Cloudflare Pages deploys static assets (if configured)

**Manual Fly.io deploy:**
```bash
flyctl deploy
flyctl deploy --dockerfile docker/Dockerfile.web
flyctl secrets set DATABASE_URL=...
```

**GitHub Actions workflows:**
- `.github/workflows/ci-unified.yml` -- tests and quality
- `.github/workflows/deploy-web.yml` -- Cloudflare Pages
- `.github/workflows/performance-tracking.yml` -- metrics
- `.github/workflows/security.yml` -- security scanning

## Environment Config

```toml
# fly.toml
[env]
  PHX_HOST = 'raxol.io'
  PORT = '8080'
```

```bash
# Secrets
flyctl secrets set SECRET_KEY_BASE="..."
flyctl secrets set DATABASE_URL="..."  # if using PostgreSQL
```

```dockerfile
# docker/Dockerfile.web (build-time)
ENV MIX_ENV="prod"
ENV SKIP_TERMBOX2_TESTS="true"
ENV TMPDIR="/tmp"
```

## Monitoring

```bash
flyctl dashboard       # metrics
flyctl status          # machine status
flyctl logs            # live logs
flyctl ssh console     # SSH into machine
```

Performance benchmarks run on schedule, publish to GitHub Pages, and alert on regressions beyond 5% tolerance.

## Rollback

```bash
flyctl releases                       # list deployments
flyctl releases rollback              # previous release
flyctl releases rollback --version X  # specific version
```

Backups: app state via Fly.io snapshots, config in git, DB via Fly.io PostgreSQL automatic backups, secrets in Fly.io (not in git).

## Domain Setup

`raxol.io` is the live custom domain (set as `PHX_HOST` in `fly.toml`). To recreate or rotate certificates:

```bash
flyctl certs create raxol.io
flyctl certs show raxol.io
```

## Cost

Fly.io free tier includes 3 shared-cpu-1x machines with 256MB RAM. The current setup (2x 1GB machines) pays for the extra RAM. Setting `min_machines_running = 0` and offloading static assets to Cloudflare Pages helps keep costs down.

## Troubleshooting

**Deployment fails:**
```bash
flyctl logs
flyctl secrets list
flyctl status
```

**Assets not loading:** Check that `mix phx.digest` ran, that `web/priv/static` exists, and that template paths are correct.

**WebSocket connection fails:** Verify `force_https = true` in fly.toml, check the WebSocket endpoint config, and make sure port 8080 is exposed.

## References

- [Fly.io Documentation](https://fly.io/docs/)
- [Phoenix Deployment Guide](https://hexdocs.pm/phoenix/deployment.html)
- [Cloudflare Pages Docs](https://developers.cloudflare.com/pages/)
- `fly.toml`
- `docker/Dockerfile.web`
