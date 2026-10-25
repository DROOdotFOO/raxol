defmodule Raxol.Agent.SessionKey do
  @moduledoc """
  Mints and checks the identifier a session is stored under.

  One authority, because a session key is a filesystem path in two places at
  once: `Raxol.Agent.Journal.FileStore.session_dir/2` joins it onto the
  journal base, and a surface's own session store uses it as a filename. Two
  surfaces mint these -- the coding TUI and the ACP agent -- and a key minted
  in one has to be resolvable by the other, so the format cannot live in each
  of them separately.

  ## Why the format is what it is

  `sess-<unix seconds>-<unique integer>`. The timestamp makes keys sort by
  age and stay distinct across VM runs; the unique integer separates two
  sessions opened in the same second. The integer alone is NOT enough, which
  is the bug this module exists to close: `System.unique_integer/1` restarts
  from a fresh sequence in every VM, so a key built from it alone names a
  different session after a restart -- fine for a value that only has to be
  unique in-process, wrong for one a client stores and hands back later to
  resume.

  Nothing here encodes which surface minted a key. A key that tools parse for
  meaning is a coupling paid for later; the originating surface belongs in the
  session record, not in its name.

  ## Validity

  `valid?/1` is the one pattern that decides what may become a path; the
  share token's session-id check delegates here rather than restating it. Use
  it on any key that arrived from outside this VM (a `session/load` request
  names one) BEFORE it reaches `session_dir/2`, which joins without
  sanitizing.
  """

  # Ids ride inside signed share tokens too, so they refuse anything that could
  # not name a journal directory (a `:` would also break the token's
  # `v2:<scope>:<id>:<exp>` framing, so an unvalidated id mints a permanently
  # unverifiable token). `.` and `..` match the charset but are dot segments,
  # not names: the same pair `Raxol.SSH.Server.sanitize_tenant/1` refuses,
  # excluded here so the two id validators cannot disagree.
  @key_re ~r/\A[A-Za-z0-9._-]+\z/
  @dot_segments [".", ".."]

  @doc """
  Mint a fresh session key.

  Always `valid?/1` -- the format is fixed here, so a caller never has to
  check its own output.
  """
  @spec mint() :: String.t()
  def mint do
    "sess-#{System.system_time(:second)}-#{System.unique_integer([:positive])}"
  end

  @doc """
  Whether `key` is a shape safe to use as a journal directory or a store
  filename.

  A single pattern behind every check. Total: any term is answerable, and a
  non-binary is simply invalid.
  """
  @spec valid?(term()) :: boolean()
  def valid?(key),
    do: is_binary(key) and key not in @dot_segments and Regex.match?(@key_re, key)
end
