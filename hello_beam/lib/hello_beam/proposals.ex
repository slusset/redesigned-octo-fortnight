defmodule HelloBeam.Proposals do
  @moduledoc """
  Human-facing interface for reviewing and graduating node-proposed modules.

  The reasoning node proposes modules via the `propose_module` tool.
  Proposals land in `priv/workspace/proposals/<name>/` with source code
  and an intent declaration. This module lets the supervisor review,
  accept, or reject them.

  ## Usage from iex

      HelloBeam.Proposals.list()
      HelloBeam.Proposals.review("beam_shell")
      HelloBeam.Proposals.accept("beam_shell")
      HelloBeam.Proposals.reject("beam_shell", "needs error handling")
  """

  @proposals_dir Path.join(File.cwd!(), "priv/workspace/proposals")
  @project_lib Path.join(File.cwd!(), "lib")

  @doc """
  List all pending proposals.
  """
  def list do
    File.mkdir_p!(@proposals_dir)

    entries =
      @proposals_dir
      |> File.ls!()
      |> Enum.filter(&proposal_pending?/1)
      |> Enum.sort()

    if entries == [] do
      IO.puts("\n  No pending proposals.\n")
      []
    else
      IO.puts("\n── Pending Proposals ──")

      Enum.each(entries, fn name ->
        intent_preview = read_intent_preview(name)
        IO.puts("  • #{name} — #{intent_preview}")
      end)

      IO.puts("\n  Use Proposals.review(\"name\") to see full details.\n")
      entries
    end
  end

  @doc """
  Review a specific proposal — show intent and full source code.
  """
  def review(name) when is_binary(name) do
    proposal_dir = Path.join(@proposals_dir, name)

    cond do
      not File.dir?(proposal_dir) ->
        IO.puts("\n  Proposal '#{name}' not found.\n")
        {:error, :not_found}

      true ->
        intent = read_file(proposal_dir, "intent.md")
        code = read_file(proposal_dir, "module.ex")

        IO.puts("""

        ╔══════════════════════════════════════════════════╗
        ║  Proposal: #{String.pad_trailing(name, 37)}║
        ╚══════════════════════════════════════════════════╝

        #{intent}
        ── Source Code ──────────────────────────────────

        #{code}
        ─────────────────────────────────────────────────

        To accept: Proposals.accept("#{name}")
        To reject: Proposals.reject("#{name}", "reason")
        """)

        {:ok, %{name: name, intent: intent, code: code}}
    end
  end

  @doc """
  Accept a proposal — copy source to lib/, compile, teach the node.
  """
  def accept(name) when is_binary(name) do
    proposal_dir = Path.join(@proposals_dir, name)

    cond do
      not File.dir?(proposal_dir) ->
        IO.puts("\n  Proposal '#{name}' not found.\n")
        {:error, :not_found}

      true ->
        intent = read_file(proposal_dir, "intent.md")
        code = read_file(proposal_dir, "module.ex")
        target_path = extract_target_path(intent)

        if is_nil(target_path) do
          IO.puts("\n  Could not determine target path from intent.md.")
          IO.puts("  Specify manually: Proposals.accept(\"#{name}\", target_path: \"hello_beam/my_module.ex\")\n")
          {:error, :no_target_path}
        else
          do_accept(name, proposal_dir, code, target_path)
        end
    end
  end

  def accept(name, opts) when is_binary(name) and is_list(opts) do
    proposal_dir = Path.join(@proposals_dir, name)
    code = read_file(proposal_dir, "module.ex")
    target_path = Keyword.fetch!(opts, :target_path)
    do_accept(name, proposal_dir, code, target_path)
  end

  defp do_accept(name, proposal_dir, code, target_path) do
    dest = Path.join(@project_lib, target_path)
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, code)

    # Hot-load the module into the running VM
    compiled = Code.compile_file(dest)
    module_names = Enum.map(compiled, fn {mod, _binary} -> inspect(mod) end)

    # Archive the proposal
    File.rename!(proposal_dir, proposal_dir <> ".accepted")

    # Teach the node
    HelloBeam.ReasoningNode.teach(
      "Module '#{name}' was accepted and loaded into the live system at lib/#{target_path}. " <>
      "Modules loaded: #{Enum.join(module_names, ", ")}."
    )

    IO.puts("""

    ✓ Proposal '#{name}' accepted.
      Installed to: lib/#{target_path}
      Compiled modules: #{Enum.join(module_names, ", ")}
      Node has been notified.
    """)

    {:ok, %{name: name, path: dest, modules: module_names}}
  end

  @doc """
  Reject a proposal — archive it and teach the node why.
  """
  def reject(name, reason) when is_binary(name) and is_binary(reason) do
    proposal_dir = Path.join(@proposals_dir, name)

    cond do
      not File.dir?(proposal_dir) ->
        IO.puts("\n  Proposal '#{name}' not found.\n")
        {:error, :not_found}

      true ->
        # Write rejection reason
        File.write!(Path.join(proposal_dir, "rejection.md"), """
        # Rejection: #{name}

        ## Reason
        #{reason}

        ## Rejected At
        #{DateTime.utc_now()}
        """)

        # Archive the proposal
        File.rename!(proposal_dir, proposal_dir <> ".rejected")

        # Teach the node
        HelloBeam.ReasoningNode.teach(
          "Module '#{name}' was rejected by the supervisor. Reason: #{reason}. " <>
          "Consider the feedback and you may propose a revised version."
        )

        IO.puts("""

        ✗ Proposal '#{name}' rejected.
          Reason: #{reason}
          Node has been notified with feedback.
        """)

        {:ok, %{name: name, reason: reason}}
    end
  end

  @doc """
  Show history of accepted and rejected proposals.
  """
  def history do
    File.mkdir_p!(@proposals_dir)

    entries = File.ls!(@proposals_dir)

    accepted = entries |> Enum.filter(&String.ends_with?(&1, ".accepted")) |> Enum.sort()
    rejected = entries |> Enum.filter(&String.ends_with?(&1, ".rejected")) |> Enum.sort()

    IO.puts("\n── Proposal History ──")

    if accepted != [] do
      IO.puts("  Accepted:")
      Enum.each(accepted, fn name ->
        IO.puts("    ✓ #{String.replace_suffix(name, ".accepted", "")}")
      end)
    end

    if rejected != [] do
      IO.puts("  Rejected:")
      Enum.each(rejected, fn name ->
        IO.puts("    ✗ #{String.replace_suffix(name, ".rejected", "")}")
      end)
    end

    if accepted == [] and rejected == [] do
      IO.puts("  No history yet.")
    end

    IO.puts("")
  end

  # -- Private --

  defp proposal_pending?(name) do
    dir = Path.join(@proposals_dir, name)
    File.dir?(dir) and
      not String.ends_with?(name, ".accepted") and
      not String.ends_with?(name, ".rejected")
  end

  defp read_intent_preview(name) do
    intent_path = Path.join([@proposals_dir, name, "intent.md"])

    case File.read(intent_path) do
      {:ok, content} ->
        # Extract the Intent section for a short preview
        case Regex.run(~r/## Intent\n(.+?)(?:\n\n|\n##|\z)/s, content) do
          [_, intent_text] -> String.slice(String.trim(intent_text), 0, 80)
          _ -> "(no intent found)"
        end

      {:error, _} ->
        "(no intent.md)"
    end
  end

  defp read_file(dir, filename) do
    case File.read(Path.join(dir, filename)) do
      {:ok, content} -> content
      {:error, _} -> "(file not found: #{filename})"
    end
  end

  defp extract_target_path(intent_text) do
    case Regex.run(~r/## Target Path\nlib\/(.+?)(?:\n|\z)/, intent_text) do
      [_, path] -> String.trim(path)
      _ -> nil
    end
  end
end
