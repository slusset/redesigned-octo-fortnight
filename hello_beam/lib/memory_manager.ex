defmodule HelloBeam.MemoryManager do
  @moduledoc """
  Comprehensive memory management system for reasoning nodes.
  
  Provides structured memory organization, backup systems, retrieval mechanisms,
  and memory lifecycle management including pruning and archival.
  """
  
  use GenServer
  require Logger
  
  @default_memory_dir "priv/memories"
  @default_memory_file "memory_manager.bin"
  @default_backup_dir "priv/memories/backups"
  @default_archive_dir "priv/memories/archive"

  defp memory_dir, do: Application.get_env(:hello_beam, :memory_dir, @default_memory_dir)
  defp memory_file, do: Application.get_env(:hello_beam, :memory_file, @default_memory_file)
  defp backup_dir, do: Application.get_env(:hello_beam, :backup_dir, @default_backup_dir)
  defp archive_dir, do: Application.get_env(:hello_beam, :archive_dir, @default_archive_dir)
  
  # Memory structure
  defstruct [
    :confirmed,     # List of confirmed facts
    :hypothesis,    # List of hypotheses 
    :archived,      # List of archived memories
    :metadata       # Timestamps, versions, etc.
  ]
  
  ## Public API
  
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def store_memory(content, type, opts \\ []) do
    GenServer.call(__MODULE__, {:store_memory, content, type, opts})
  end
  
  def get_memories(filter \\ :all) do
    GenServer.call(__MODULE__, {:get_memories, filter})
  end
  
  def search_memories(query) do
    GenServer.call(__MODULE__, {:search_memories, query})
  end
  
  def backup_memories() do
    GenServer.call(__MODULE__, :backup_memories)
  end
  
  def archive_memory(memory_id) do
    GenServer.call(__MODULE__, {:archive_memory, memory_id})
  end
  
  def prune_memories(criteria) do
    GenServer.call(__MODULE__, {:prune_memories, criteria})
  end
  
  def get_stats() do
    GenServer.call(__MODULE__, :get_stats)
  end
  
  ## GenServer Callbacks
  
  @impl true
  def init(_opts) do
    # Ensure directories exist
    File.mkdir_p!(memory_dir())
    File.mkdir_p!(backup_dir())
    File.mkdir_p!(archive_dir())
    
    # Load existing memories
    state = load_memories()
    
    Logger.info("MemoryManager initialized with #{memory_count(state)} memories")
    
    {:ok, state}
  end
  
  @impl true
  def handle_call({:store_memory, content, type, opts}, _from, state) do
    memory = create_memory(content, type, opts)
    new_state = add_memory(state, memory, type)
    
    # Persist immediately
    :ok = persist_memories(new_state)
    
    Logger.debug("Stored #{type} memory: #{String.slice(content, 0, 50)}...")
    
    {:reply, :ok, new_state}
  end
  
  @impl true
  def handle_call({:get_memories, filter}, _from, state) do
    memories = filter_memories(state, filter)
    {:reply, memories, state}
  end
  
  @impl true
  def handle_call({:search_memories, query}, _from, state) do
    results = search_memories_impl(state, query)
    {:reply, results, state}
  end
  
  @impl true
  def handle_call(:backup_memories, _from, state) do
    result = create_backup(state)
    {:reply, result, state}
  end
  
  @impl true
  def handle_call({:archive_memory, memory_id}, _from, state) do
    case archive_memory_impl(state, memory_id) do
      {:ok, new_state} ->
        :ok = persist_memories(new_state)
        {:reply, :ok, new_state}

      {{:error, reason}, same_state} ->
        {:reply, {:error, reason}, same_state}
    end
  end
  
  @impl true
  def handle_call({:prune_memories, criteria}, _from, state) do
    {pruned_count, new_state} = prune_memories_impl(state, criteria)
    :ok = persist_memories(new_state)
    {:reply, {:ok, pruned_count}, new_state}
  end
  
  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      confirmed_count: length(state.confirmed),
      hypothesis_count: length(state.hypothesis),
      archived_count: length(state.archived),
      total_count: memory_count(state),
      last_backup: get_last_backup_time(),
      memory_size_bytes: calculate_memory_size(state)
    }
    {:reply, stats, state}
  end
  
  ## Private Functions
  
  defp create_memory(content, type, opts) do
    %{
      id: generate_memory_id(),
      content: content,
      type: type,
      timestamp: DateTime.utc_now(),
      tags: Keyword.get(opts, :tags, []),
      priority: Keyword.get(opts, :priority, :normal),
      source: Keyword.get(opts, :source, :reasoning)
    }
  end
  
  defp add_memory(state, memory, :confirmed) do
    %{state | confirmed: [memory | state.confirmed]}
  end
  
  defp add_memory(state, memory, :hypothesis) do
    %{state | hypothesis: [memory | state.hypothesis]}
  end
  
  defp filter_memories(state, :all) do
    state.confirmed ++ state.hypothesis
  end
  
  defp filter_memories(state, :confirmed) do
    state.confirmed
  end
  
  defp filter_memories(state, :hypothesis) do
    state.hypothesis
  end
  
  defp filter_memories(state, :archived) do
    state.archived
  end
  
  defp search_memories_impl(state, query) do
    all_memories = state.confirmed ++ state.hypothesis ++ state.archived
    
    all_memories
    |> Enum.filter(fn memory ->
      String.contains?(String.downcase(memory.content), String.downcase(query))
    end)
    |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
  end
  
  defp archive_memory_impl(state, memory_id) do
    case find_and_remove_memory(state, memory_id) do
      {memory, new_state} ->
        archived_memory = Map.put(memory, :archived_at, DateTime.utc_now())
        final_state = %{new_state | archived: [archived_memory | new_state.archived]}
        {:ok, final_state}
      
      :not_found ->
        {{:error, :memory_not_found}, state}
    end
  end
  
  defp find_and_remove_memory(state, memory_id) do
    cond do
      memory = Enum.find(state.confirmed, &(&1.id == memory_id)) ->
        new_confirmed = Enum.reject(state.confirmed, &(&1.id == memory_id))
        {memory, %{state | confirmed: new_confirmed}}
      
      memory = Enum.find(state.hypothesis, &(&1.id == memory_id)) ->
        new_hypothesis = Enum.reject(state.hypothesis, &(&1.id == memory_id))
        {memory, %{state | hypothesis: new_hypothesis}}
      
      true ->
        :not_found
    end
  end
  
  defp prune_memories_impl(state, criteria) do
    case criteria do
      {:older_than, days} ->
        cutoff = DateTime.add(DateTime.utc_now(), -days * 24 * 60 * 60, :second)
        prune_by_date(state, cutoff)
      
      {:hypothesis_older_than, days} ->
        cutoff = DateTime.add(DateTime.utc_now(), -days * 24 * 60 * 60, :second)
        prune_hypothesis_by_date(state, cutoff)
      
      {:low_priority} ->
        prune_low_priority(state)

      :low_priority ->
        prune_low_priority(state)

      _ ->
        {0, state}
    end
  end
  
  defp prune_by_date(state, cutoff) do
    {kept_confirmed, removed_confirmed} = Enum.split_with(state.confirmed, &(DateTime.after?(&1.timestamp, cutoff)))
    {kept_hypothesis, removed_hypothesis} = Enum.split_with(state.hypothesis, &(DateTime.after?(&1.timestamp, cutoff)))
    
    # Archive the removed memories
    archived = (removed_confirmed ++ removed_hypothesis)
    |> Enum.map(&Map.put(&1, :archived_at, DateTime.utc_now()))
    
    new_state = %{state | 
      confirmed: kept_confirmed,
      hypothesis: kept_hypothesis,
      archived: archived ++ state.archived
    }
    
    {length(removed_confirmed) + length(removed_hypothesis), new_state}
  end
  
  defp prune_hypothesis_by_date(state, cutoff) do
    {kept_hypothesis, removed_hypothesis} = Enum.split_with(state.hypothesis, &(DateTime.after?(&1.timestamp, cutoff)))
    
    archived = removed_hypothesis
    |> Enum.map(&Map.put(&1, :archived_at, DateTime.utc_now()))
    
    new_state = %{state | 
      hypothesis: kept_hypothesis,
      archived: archived ++ state.archived
    }
    
    {length(removed_hypothesis), new_state}
  end
  
  defp prune_low_priority(state) do
    {kept_confirmed, removed_confirmed} = Enum.split_with(state.confirmed, &(&1.priority != :low))
    {kept_hypothesis, removed_hypothesis} = Enum.split_with(state.hypothesis, &(&1.priority != :low))
    
    archived = (removed_confirmed ++ removed_hypothesis)
    |> Enum.map(&Map.put(&1, :archived_at, DateTime.utc_now()))
    
    new_state = %{state | 
      confirmed: kept_confirmed,
      hypothesis: kept_hypothesis,
      archived: archived ++ state.archived
    }
    
    {length(removed_confirmed) + length(removed_hypothesis), new_state}
  end
  
  defp load_memories() do
    memory_path = Path.join(memory_dir(), memory_file())

    case File.read(memory_path) do
      {:ok, binary} ->
        try do
          :erlang.binary_to_term(binary)
        rescue
          _ ->
            Logger.warning("Failed to load memories, starting fresh")
            create_empty_state()
        end
      
      {:error, :enoent} ->
        Logger.info("No existing memories found, starting fresh")
        create_empty_state()
      
      {:error, reason} ->
        Logger.error("Failed to read memory file: #{reason}")
        create_empty_state()
    end
  end
  
  defp create_empty_state() do
    %__MODULE__{
      confirmed: [],
      hypothesis: [],
      archived: [],
      metadata: %{
        created_at: DateTime.utc_now(),
        version: "1.0.0"
      }
    }
  end
  
  defp persist_memories(state) do
    memory_path = Path.join(memory_dir(), memory_file())
    binary = :erlang.term_to_binary(state)
    
    case File.write(memory_path, binary) do
      :ok ->
        Logger.debug("Memories persisted successfully")
        :ok
      
      {:error, reason} ->
        Logger.error("Failed to persist memories: #{reason}")
        {:error, reason}
    end
  end
  
  defp create_backup(state) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic)
    backup_filename = "memories_backup_#{timestamp}.bin"
    backup_path = Path.join(backup_dir(), backup_filename)
    
    binary = :erlang.term_to_binary(state)
    
    case File.write(backup_path, binary) do
      :ok ->
        Logger.info("Memory backup created: #{backup_filename}")
        {:ok, backup_path}
      
      {:error, reason} ->
        Logger.error("Failed to create backup: #{reason}")
        {:error, reason}
    end
  end
  
  defp get_last_backup_time() do
    case File.ls(backup_dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.starts_with?(&1, "memories_backup_"))
        |> Enum.sort(:desc)
        |> List.first()
        |> case do
          nil -> nil
          filename ->
            # Extract timestamp from filename
            timestamp_str = filename |> String.replace("memories_backup_", "") |> String.replace(".bin", "")
            case DateTime.from_iso8601(timestamp_str) do
              {:ok, datetime, _} -> datetime
              _ -> nil
            end
        end
      
      _ -> nil
    end
  end
  
  defp calculate_memory_size(state) do
    :erlang.byte_size(:erlang.term_to_binary(state))
  end
  
  defp memory_count(state) do
    length(state.confirmed) + length(state.hypothesis) + length(state.archived)
  end
  
  defp generate_memory_id() do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end