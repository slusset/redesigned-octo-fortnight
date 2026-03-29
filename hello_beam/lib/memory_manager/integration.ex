defmodule HelloBeam.MemoryManager.Integration do
  @moduledoc """
  Integration layer between ReasoningNode and MemoryManager.
  
  Provides seamless migration from the old memory system to the new one,
  with enhanced capabilities while maintaining backward compatibility.
  """
  
  require Logger
  
  @doc """
  Migrate memories from the old ReasoningNode format to the new MemoryManager format.
  """
  def migrate_memories() do
    old_memories = load_old_memories()
    
    if length(old_memories) > 0 do
      Logger.info("Migrating #{length(old_memories)} memories from old format...")
      
      # Start MemoryManager if not already started
      case GenServer.whereis(HelloBeam.MemoryManager) do
        nil -> HelloBeam.MemoryManager.start_link()
        _ -> :ok
      end
      
      # Migrate each memory
      Enum.each(old_memories, &migrate_single_memory/1)
      
      # Create backup of old memories before clearing
      backup_old_memories(old_memories)
      
      Logger.info("Memory migration completed successfully")
      :ok
    else
      Logger.info("No old memories found to migrate")
      :ok
    end
  end
  
  @doc """
  Extract and store memories from reasoning response using the new system.
  """
  def extract_and_store_memories(response) do
    # Extract MEMORY: prefixed lines
    memory_lines = extract_memory_lines(response)
    
    # Extract [CONFIRMED] and [HYPOTHESIS] tagged lines  
    tagged_memories = extract_tagged_memories(response)
    
    all_memories = memory_lines ++ tagged_memories
    
    # Store each memory using the new system
    Enum.each(all_memories, fn {content, type, metadata} ->
      HelloBeam.MemoryManager.store_memory(content, type, metadata)
    end)
    
    case length(all_memories) do
      0 -> :no_memories_found
      count -> {:memories_stored, count}
    end
  end
  
  @doc """
  Get formatted memories for inclusion in reasoning context.
  """
  def get_context_memories(filter \\ :all) do
    case HelloBeam.MemoryManager.get_memories(filter) do
      memories when is_list(memories) ->
        memories
        |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
        |> Enum.take(50) # Limit to most recent 50 memories for context
        |> Enum.map(&format_memory_for_context/1)
        |> Enum.join("\n")
        
      _ -> ""
    end
  end
  
  @doc """
  Enhanced tool dispatch that includes memory management operations.
  """
  def dispatch_enhanced_tool("store_memory", %{"content" => content, "type" => type} = params) do
    # Parse additional parameters
    opts = [
      tags: Map.get(params, "tags", []),
      priority: String.to_existing_atom(Map.get(params, "priority", "normal")),
      source: :tool_call
    ]
    
    type_atom = String.to_existing_atom(type)
    
    case HelloBeam.MemoryManager.store_memory(content, type_atom, opts) do
      :ok ->
        Logger.info("Enhanced memory stored: #{type} - #{String.slice(content, 0, 50)}...")
        {"Memory stored successfully.", :ok}
        
      {:error, reason} ->
        Logger.error("Failed to store memory: #{reason}")
        {"Failed to store memory: #{reason}", :error}
    end
  end
  
  def dispatch_enhanced_tool("search_memories", %{"query" => query}) do
    case HelloBeam.MemoryManager.search_memories(query) do
      results when is_list(results) ->
        formatted_results = results
        |> Enum.take(10) # Limit results
        |> Enum.map(&format_search_result/1)
        |> Enum.join("\n\n")
        
        response = if Enum.empty?(results) do
          "No memories found matching '#{query}'"
        else
          "Found #{length(results)} memories matching '#{query}':\n\n#{formatted_results}"
        end
        
        {response, :ok}
        
      {:error, reason} ->
        {"Search failed: #{reason}", :error}
    end
  end
  
  def dispatch_enhanced_tool("memory_stats", _params) do
    case HelloBeam.MemoryManager.get_stats() do
      stats when is_map(stats) ->
        response = """
        Memory Statistics:
        - Confirmed: #{stats.confirmed_count}
        - Hypothesis: #{stats.hypothesis_count}  
        - Archived: #{stats.archived_count}
        - Total: #{stats.total_count}
        - Size: #{format_bytes(stats.memory_size_bytes)}
        - Last backup: #{format_backup_time(stats.last_backup)}
        """
        {response, :ok}
        
      {:error, reason} ->
        {"Failed to get stats: #{reason}", :error}
    end
  end
  
  def dispatch_enhanced_tool("backup_memories", _params) do
    case HelloBeam.MemoryManager.backup_memories() do
      {:ok, backup_path} ->
        {"Memory backup created: #{backup_path}", :ok}
        
      {:error, reason} ->
        {"Backup failed: #{reason}", :error}
    end
  end
  
  # Fallback for unknown tools
  def dispatch_enhanced_tool(tool_name, params) do
    {"Unknown enhanced tool: #{tool_name} with params: #{inspect(params)}", :error}
  end
  
  ## Private Functions
  
  defp load_old_memories() do
    old_memory_file = Path.join([File.cwd!(), "priv/memories", "reasoning_node.bin"])
    
    case File.read(old_memory_file) do
      {:ok, binary} ->
        :erlang.binary_to_term(binary)
        
      {:error, :enoent} ->
        []
        
      {:error, reason} ->
        Logger.warning("Failed to load old memories: #{reason}")
        []
    end
  end
  
  defp migrate_single_memory(old_memory) do
    # Convert old memory format to new format
    content = old_memory.content
    type = old_memory.type
    
    opts = [
      source: Map.get(old_memory, :source, :migration),
      tags: [:migrated],
      priority: :normal
    ]
    
    HelloBeam.MemoryManager.store_memory(content, type, opts)
  end
  
  defp backup_old_memories(old_memories) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic)
    backup_file = "old_memories_backup_#{timestamp}.bin"
    backup_path = Path.join([File.cwd!(), "priv/memories", backup_file])
    
    binary = :erlang.term_to_binary(old_memories)
    File.write!(backup_path, binary)
    
    Logger.info("Old memories backed up to: #{backup_file}")
  end
  
  defp extract_memory_lines(text) do
    Regex.scan(~r/MEMORY:\s*(.+?)(?:\n|$)/i, text)
    |> Enum.map(fn [_, content] ->
      {String.trim(content), :hypothesis, [source: :extracted, tags: [:auto_extracted]]}
    end)
  end
  
  defp extract_tagged_memories(text) do
    # Extract [CONFIRMED] and [HYPOTHESIS] tagged lines
    confirmed = Regex.scan(~r/\[CONFIRMED\]\s*(.+?)(?:\n|$)/i, text)
    |> Enum.map(fn [_, content] ->
      {String.trim(content), :confirmed, [source: :tagged, tags: [:confirmed_tag]]}
    end)
    
    hypothesis = Regex.scan(~r/\[HYPOTHESIS\]\s*(.+?)(?:\n|$)/i, text)
    |> Enum.map(fn [_, content] ->
      {String.trim(content), :hypothesis, [source: :tagged, tags: [:hypothesis_tag]]}
    end)
    
    confirmed ++ hypothesis
  end
  
  defp format_memory_for_context(memory) do
    type_tag = case memory.type do
      :confirmed -> "[CONFIRMED]"
      :hypothesis -> "[HYPOTHESIS]"
      _ -> "[UNKNOWN]"
    end
    
    "#{type_tag} #{memory.content}"
  end
  
  defp format_search_result(memory) do
    timestamp = memory.timestamp |> DateTime.to_date() |> Date.to_string()
    type_indicator = case memory.type do
      :confirmed -> "✓"
      :hypothesis -> "?"
      _ -> "-"
    end
    
    """
    [#{type_indicator}] #{timestamp} - #{memory.content}
    ID: #{memory.id}
    """
  end
  
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} bytes"
  defp format_bytes(bytes) when bytes < 1024 * 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end
  defp format_bytes(bytes) do
    "#{Float.round(bytes / (1024 * 1024), 1)} MB"
  end
  
  defp format_backup_time(nil), do: "Never"
  defp format_backup_time(datetime), do: DateTime.to_string(datetime)
end