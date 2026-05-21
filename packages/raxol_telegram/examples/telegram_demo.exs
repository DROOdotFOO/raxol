#
# Live-test harness for the Raxol Telegram surface.
#
# Walks through what it takes to actually drive a TEA app from a Telegram
# bot: create a bot via @BotFather, get a token, configure Telegex, point
# the supervisor at a TEA app module, and let `Raxol.Telegram.Bot` route
# updates to per-chat sessions.
#
# Setup
#   1. Open @BotFather in Telegram. `/newbot`, follow prompts, save the
#      token it gives you.
#   2. (Recommended) Send `/setprivacy disable` to @BotFather for your bot
#      so it can read message text in groups. For 1:1 chats this isn't
#      needed.
#   3. Get your own chat_id: message @userinfobot, it'll print your
#      numeric ID. Use that in `allowed_chat_ids` so randoms can't drive
#      the bot.
#
# Run
#   cd packages/raxol_telegram
#   TELEGRAM_BOT_TOKEN=<your-token> \
#   TELEGRAM_ALLOWED_CHAT_IDS=123456789,987654321 \
#   mix run --no-halt examples/telegram_demo.exs
#
#   Then DM your bot. Send `/start` to open a session, then keys (single
#   chars like `q`, `=`, `-`, or words like `quit`) to drive the counter.
#   Use the inline keyboard for arrows / Tab / Enter / Quit.
#
# Notes
#   - Telegex (and its Finch transport) is the optional HTTP layer. This
#     script raises early if the env vars are missing so you don't
#     accidentally start a bot with no token.
#   - The supervisor uses the small counter TEA app defined inline below.
#

require Logger

defmodule TelegramDemo.Counter do
  @moduledoc false
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Events.Event

  @impl true
  def init(_context), do: %{count: 0}

  @impl true
  def update(%Event{type: :key, data: %{key: :char, char: "="}}, model),
    do: {%{model | count: model.count + 1}, []}

  def update(%Event{type: :key, data: %{key: :char, char: "+"}}, model),
    do: {%{model | count: model.count + 1}, []}

  def update(%Event{type: :key, data: %{key: :char, char: "-"}}, model),
    do: {%{model | count: model.count - 1}, []}

  def update(%Event{type: :key, data: %{key: :char, char: "q"}}, model),
    do: {model, [command(:quit)]}

  def update(_msg, model), do: {model, []}

  @impl true
  def view(model) do
    import Raxol.View

    column do
      text("Telegram Counter Demo")
      text("")
      text("Count: #{model.count}")
      text("")
      text("Send `=` or `+` to increment, `-` to decrement, `q` to quit.")
    end
  end
end

defmodule TelegramDemo do
  @required_env "TELEGRAM_BOT_TOKEN"
  @chat_ids_env "TELEGRAM_ALLOWED_CHAT_IDS"

  def run do
    case System.get_env(@required_env) do
      nil ->
        die("#{@required_env} is required. See the header of this file for setup.")

      "" ->
        die("#{@required_env} is empty.")

      token ->
        start(token)
    end
  end

  defp start(token) do
    allowed_chat_ids = parse_chat_ids(System.get_env(@chat_ids_env))

    case allowed_chat_ids do
      [] ->
        Logger.warning(
          "No #{@chat_ids_env} set. The bot will accept messages from any Telegram user. " <>
            "This is fine for a quick local test, but NOT safe for a long-running deployment."
        )

      ids ->
        Logger.info("Restricting to chat_ids: #{inspect(ids)}.")
    end

    # Telegex configuration (token + Finch HTTP adapter).
    Application.put_env(:telegex, :token, token)
    Application.put_env(:telegex, :caller_adapter, Telegex.Caller.Adapter.Finch)

    {:ok, _} = Application.ensure_all_started(:finch)

    children = [
      {Finch, name: Telegex.Finch},
      {Raxol.Telegram.Supervisor, app_module: TelegramDemo.Counter},
      {Telegex.Polling.GenHandler, [&dispatch_update(&1, allowed_chat_ids)]}
    ]

    {:ok, _sup} = Supervisor.start_link(children, strategy: :one_for_one, name: TelegramDemo.Supervisor)

    Logger.info("Bot online. Send /start to your bot in Telegram to begin.")
    Process.sleep(:infinity)
  end

  defp dispatch_update(update, allowed_chat_ids) do
    Raxol.Telegram.Bot.handle_update(update, allowed_chat_ids: allowed_chat_ids)
  end

  defp parse_chat_ids(nil), do: []
  defp parse_chat_ids(""), do: []

  defp parse_chat_ids(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_integer/1)
  end

  defp die(msg) do
    IO.puts(:stderr, "telegram_demo: " <> msg)
    System.halt(1)
  end
end

TelegramDemo.run()
