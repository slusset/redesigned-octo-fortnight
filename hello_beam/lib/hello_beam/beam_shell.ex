defmodule HelloBeam.BeamShell do
  @moduledoc """
  Direct BEAM interface for communicating with the reasoning node.

  Bypasses HTTP entirely — uses native Elixir message passing to talk
  to the ReasoningNode GenServer. This is the human's conversational
  interface to the node from iex.

  ## Usage

      iex> HelloBeam.BeamShell.ask("What tools do you have?")
      iex> HelloBeam.BeamShell.chat()       # interactive mode
      iex> HelloBeam.BeamShell.status()      # quick process inspection
      iex> HelloBeam.BeamShell.memories()    # see what it remembers
  """

  @doc """
  Send a prompt through the full reasoning loop and return the response.
  This triggers the same agentic loop as GenServer.call — tool use, memory
  extraction, the whole dharma cycle.
  """
  def ask(prompt, opts \\ []) when is_binary(prompt) do
    _timeout = Keyword.get(opts, :timeout, :infinity)

    case GenServer.whereis(HelloBeam.ReasoningNode) do
      nil ->
        {:error, :node_not_running}

      _pid ->
        case HelloBeam.ReasoningNode.reason(prompt) do
          {:ok, response} ->
            IO.puts("\n#{response}\n")
            :ok

          {:error, reason} ->
            IO.puts("\n[error] #{inspect(reason)}\n")
            {:error, reason}
        end
    end
  rescue
    e ->
      IO.puts("\n[exception] #{Exception.message(e)}\n")
      {:error, e}
  end

  @doc """
  Interactive chat mode. Keeps prompting until you type `exit`.
  Each input runs through the full reasoning loop.
  """
  def chat do
    IO.puts("\n╔═══════════════════════════════════════════════════╗")
    IO.puts("║  BeamShell — direct line to the reasoning node      ║")
    IO.puts("║  Commands: status, memories, proposals, history, exit║")
    IO.puts("╚═══════════════════════════════════════════════════╝\n")

    chat_loop()
  end

  defp chat_loop do
    case IO.gets("you> ") do
      :eof ->
        IO.puts("EOF — goodbye.")

      input ->
        input = String.trim(input)

        case input do
          "" ->
            chat_loop()

          "exit" ->
            IO.puts("Goodbye.")

          "status" ->
            IO.puts(status_text())
            chat_loop()

          "memories" ->
            show_memories()
            chat_loop()

          "proposals" ->
            HelloBeam.Proposals.list()
            chat_loop()

          "history" ->
            HelloBeam.Proposals.history()
            chat_loop()

          prompt ->
            ask(prompt)
            chat_loop()
        end
    end
  end

  @doc """
  Quick process-level inspection of the reasoning node.
  Does NOT trigger reasoning — just reads process info directly.
  """
  def status do
    IO.puts(status_text())
  end

  defp status_text do
    case GenServer.whereis(HelloBeam.ReasoningNode) do
      nil ->
        "ReasoningNode is not running."

      pid ->
        info = Process.info(pid, [:memory, :reductions, :message_queue_len, :status])
        state = HelloBeam.ReasoningNode.introspect()

        """

        ── ReasoningNode Status ──
        PID:            #{inspect(pid)}
        Status:         #{info[:status]}
        Memory:         #{format_bytes(info[:memory])}
        Reductions:     #{info[:reductions]}
        Message Queue:  #{info[:message_queue_len]}
        Memories:       #{length(state.memories)}
        Reasoning Runs: #{state.reasoning_count}
        Active Tests:   #{map_size(state.test_runs)}
        """
    end
  end

  @doc """
  Show the node's memories without triggering reasoning.
  Reads directly from GenServer state.
  """
  def memories do
    show_memories()
  end

  defp show_memories do
    mems = HelloBeam.ReasoningNode.memories()

    if mems == [] do
      IO.puts("\n  (no memories)\n")
    else
      IO.puts("\n── Memories (#{length(mems)}) ──")

      mems
      |> Enum.with_index(1)
      |> Enum.each(fn {m, i} ->
        tag = if m.type == :confirmed, do: "✓", else: "?"
        source = Map.get(m, :source, :unknown)
        IO.puts("  #{i}. [#{tag}] #{m.content}")
        IO.puts("       source: #{source}  at: #{Map.get(m, :at, "?")}")
      end)

      IO.puts("")
    end
  end

  @doc """
  Teach the node something directly — shortcut for ReasoningNode.teach/2.
  """
  def teach(content) when is_binary(content) do
    HelloBeam.ReasoningNode.teach(content)
    IO.puts("Taught: #{content}")
    :ok
  end

  @doc """
  List pending module proposals from the node.
  """
  def proposals do
    HelloBeam.Proposals.list()
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end
