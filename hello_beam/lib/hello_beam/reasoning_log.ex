defmodule HelloBeam.ReasoningLog do
  @moduledoc """
  Structured append-only log of reasoning cycles.

  Each time the node reasons, a record is written capturing: the prompt,
  tools used, response summary, timing, and outcome status. This gives
  the supervisor visibility into what the node is doing without having
  to interrogate it.

  Logs are stored as JSONL (one JSON object per line) in
  `priv/reasoning_log/YYYY-MM-DD.jsonl`.

  ## Usage

      HelloBeam.ReasoningLog.recent()        # last 5 records
      HelloBeam.ReasoningLog.recent(10)       # last 10
      HelloBeam.ReasoningLog.today()          # all records from today
      HelloBeam.ReasoningLog.search("memory") # find by prompt/response content
  """

  require Logger

  @log_dir Path.join(File.cwd!(), "priv/reasoning_log")

  # -- Writing --

  @doc """
  Append a reasoning record to today's log file.
  """
  def append(record) when is_map(record) do
    File.mkdir_p!(@log_dir)

    entry = record
    |> Map.put(:id, generate_id())
    |> Map.put(:timestamp, DateTime.utc_now() |> DateTime.to_iso8601())

    line = Jason.encode!(entry)
    file = today_file()

    case File.write(file, line <> "\n", [:append]) do
      :ok ->
        Logger.debug("ReasoningLog: appended record #{entry.id}")
        {:ok, entry.id}

      {:error, reason} ->
        Logger.error("ReasoningLog: failed to write: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # -- Reading --

  @doc """
  Return the last N reasoning records across all log files.
  """
  def recent(n \\ 5) do
    log_files()
    |> Enum.flat_map(&read_records/1)
    |> Enum.take(-n)
    |> Enum.reverse()
  end

  @doc """
  Return all records from today's log.
  """
  def today do
    today_file()
    |> read_records()
    |> Enum.reverse()
  end

  @doc """
  Search records where prompt or response contains the pattern (case-insensitive).
  """
  def search(pattern) when is_binary(pattern) do
    downcased = String.downcase(pattern)

    log_files()
    |> Enum.flat_map(&read_records/1)
    |> Enum.filter(fn record ->
      prompt = Map.get(record, "prompt", "") |> String.downcase()
      response = Map.get(record, "response", "") |> String.downcase()
      String.contains?(prompt, downcased) or String.contains?(response, downcased)
    end)
    |> Enum.reverse()
  end

  @doc """
  Pretty-print a list of records to the console.
  """
  def print(records) when is_list(records) do
    if records == [] do
      IO.puts("\n  (no records)\n")
    else
      IO.puts("\n── Reasoning Log ──")

      Enum.each(records, fn record ->
        print_record(record)
      end)

      IO.puts("")
    end
  end

  defp print_record(record) do
    timestamp = Map.get(record, "timestamp", "?")
    prompt = Map.get(record, "prompt", "?") |> String.slice(0, 80)
    status = Map.get(record, "status", "?")
    duration = Map.get(record, "duration_ms", "?")
    iterations = Map.get(record, "iterations_used", "?")
    max_iter = Map.get(record, "max_iterations", "?")
    tools = Map.get(record, "tools_used", [])
    memories = Map.get(record, "memories_created", 0)

    status_icon = case status do
      "ok" -> "✓"
      "error" -> "✗"
      "max_iterations_reached" -> "⟳"
      _ -> "?"
    end

    IO.puts("  #{status_icon} [#{timestamp}] #{duration}ms (#{iterations}/#{max_iter} iterations)")
    IO.puts("    Prompt: #{prompt}")

    if tools != [] do
      tool_names = tools |> Enum.map(&Map.get(&1, "name", "?")) |> Enum.join(", ")
      IO.puts("    Tools:  #{tool_names}")
    end

    if memories > 0 do
      IO.puts("    Memories created: #{memories}")
    end

    IO.puts("")
  end

  # -- Private --

  defp today_file do
    date = Date.utc_today() |> Date.to_iso8601()
    Path.join(@log_dir, "#{date}.jsonl")
  end

  defp log_files do
    case File.ls(@log_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.sort()
        |> Enum.map(&Path.join(@log_dir, &1))

      {:error, _} ->
        []
    end
  end

  defp read_records(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case Jason.decode(line) do
            {:ok, record} -> record
            {:error, _} -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
