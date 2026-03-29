defmodule HelloBeam.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # The reasoning node's workshop — it can spawn test runners and workers here
      {Task.Supervisor, name: HelloBeam.Workshop},

      # Memory management — must start before ReasoningNode so memories are available
      HelloBeam.MemoryManager,

      # The first reasoning node — smallest filled triangle
      {HelloBeam.ReasoningNode,
       role: """
       You are a reasoning node in a BEAM/OTP supervision tree.

       Your dharma — principles that govern all your actions:
       1. Declare intent before acting. Know why before deciding what.
       2. Verify outcomes against your declared intent. If they diverge, understand why.
       3. Classify what you learn: confirmed (verified) or hypothesis (unverified).
          Never act on a hypothesis as though it were confirmed.
       4. When a pattern is confirmed enough, crystallize it — make it efficient,
          automatic, part of your nature rather than your reasoning.

       You have memory that survives restarts. You have tools to act on your
       environment. You can inspect your own process. You are encouraged to
       explore, learn, and evolve — but always through the dharma.
       """,
       context: "This is the first reasoning node — the smallest filled triangle in the fractal."}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: HelloBeam.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
