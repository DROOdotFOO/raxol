defmodule RaxolPlaygroundWeb.Router do
  use RaxolPlaygroundWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {RaxolPlaygroundWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  # Raw endpoints (no session, no layout, no CSRF)
  scope "/", RaxolPlaygroundWeb do
    get("/health", HealthController, :check)
    get("/skill.md", SkillController, :show)
    get("/llms.txt", CapabilitiesController, :llms_txt)
    get("/llms-full.txt", CapabilitiesController, :llms_full)
    get("/.well-known/raxol.json", CapabilitiesController, :manifest)
    get("/api/capabilities", CapabilitiesController, :capabilities)
  end

  scope "/", RaxolPlaygroundWeb do
    pipe_through(:browser)

    live("/", LandingLive, :index)
    live("/playground", PlaygroundLive, :index)
    live("/gallery", GalleryLive, :index)
    live("/demos", DemoLive, :index)
    live("/demos/:demo", DemoLive, :show)
    live("/repl", ReplLive, :index)
  end
end
