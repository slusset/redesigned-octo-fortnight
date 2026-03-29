defmodule HelloBeam.MemoryManager.CLI do
  @moduledoc """
  Command-line interface for memory management operations.
  
  Provides human-readable commands for inspecting, managing, and maintaining
  the reasoning node's memory system.
  """
  
  @doc """
  Display all memories with optional filtering.
  
  ## Examples
      iex> HelloBeam.MemoryManager.CLI.list()
      iex> HelloBeam.MemoryManager.CLI.list(:confirmed)
      iex> HelloBeam.MemoryManager.CLI.list(:hypothesis)
  """
  def list(filter \\ :all) do
    case HelloBeam.MemoryManager.get_memories(filter) do
      memories when is_list(memories) ->
        IO.puts("\n=== Memory List (#{filter}) ===")
        
        if Enum.empty?(memories) do
          IO.puts("No memories found.")
        else
          memories
          |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})
          |> Enum.with_index(1)
          |> Enum.each(&format_memory_item/1)
        end
        
      {:error, reason} ->
        IO.puts("Error retrieving memories: #{reason}")
    end
  end
  
  @doc """
  Search memories by content.
  
  ## Examples
      iex> HelloBeam.MemoryManager.CLI.search("BEAM")
      iex> HelloBeam.MemoryManager.CLI.search("supervision")
  """
  def search(query) do
    case HelloBeam.MemoryManager.search_memories(query) do
      results when is_list(results) ->
        IO.puts("\n=== Search Results: \"#{query}\" ===")
        
        if Enum.empty?(results) do
          IO.puts("No matching memories found.")
        else
          results
          |> Enum.with_index(1)
          |> Enum.each(&format_memory_item/1)
        end
        
      {:error, reason} ->
        IO.puts("Search error: #{reason}")
    end
  end
  
  @doc """
  Display memory system statistics.
  """
  def stats() do
    case HelloBeam.MemoryManager.get_stats() do
      stats when is_map(stats) ->
        IO.puts("\n=== Memory Statistics ===")
        IO.puts("Confirmed memories: #{stats.confirmed_count}")
        IO.puts("Hypothesis memories: #{stats.hypothesis_count}")
        IO.puts("Archived memories: #{stats.archived_count}")
        IO.puts("Total memories: #{stats.total_count}")
        IO.puts("Memory size: #{format_bytes(stats.memory_size_bytes)}")
        
        case stats.last_backup do
          nil -> IO.puts("Last backup: Never")
          datetime -> IO.puts("Last backup: #{DateTime.to_string(datetime)}")
        end
        
      {:error, reason} ->
        IO.puts("Error retrieving stats: #{reason}")
    end
  end
  
  @doc """
  Create a backup of current memories.
  """
  def backup() do
    IO.puts("Creating memory backup...")
    
    case HelloBeam.MemoryManager.backup_memories() do
      {:ok, backup_path} ->
        IO.puts("Backup created successfully: #{backup_path}")
        
      {:error, reason} ->
        IO.puts("Backup failed: #{reason}")
    end
  end
  
  @doc """
  Archive a specific memory by ID.
  """
  def archive(memory_id) do
    case HelloBeam.MemoryManager.archive_memory(memory_id) do
      :ok ->
        IO.puts("Memory #{memory_id} archived successfully.")
        
      {:error, :memory_not_found} ->
        IO.puts("Memory with ID #{memory_id} not found.")
        
      {:error, reason} ->
        IO.puts("Archive failed: #{reason}")
    end
  end
  
  @doc """
  Prune memories based on criteria.
  
  ## Examples
      iex> HelloBeam.MemoryManager.CLI.prune({:older_than, 30})
      iex> HelloBeam.MemoryManager.CLI.prune({:hypothesis_older_than, 7})
      iex> HelloBeam.MemoryManager.CLI.prune(:low_priority)
  """
  def prune(criteria) do
    IO.puts("Pruning memories with criteria: #{inspect(criteria)}...")
    
    case HelloBeam.MemoryManager.prune_memories(criteria) do
      {:ok, count} ->
        IO.puts("Successfully pruned #{count} memories.")
        
      {:error, reason} ->
        IO.puts("Pruning failed: #{reason}")
    end
  end
  
  @doc """
  Show detailed information about a specific memory.
  """
  def show(memory_id) do
    all_memories = HelloBeam.MemoryManager.get_memories(:all)
    
    case Enum.find(all_memories, &(&1.id == memory_id)) do
      nil ->
        IO.puts("Memory with ID #{memory_id} not found.")
        
      memory ->
        IO.puts("\n=== Memory Details ===")
        IO.puts("ID: #{memory.id}")
        IO.puts("Type: #{memory.type}")
        IO.puts("Timestamp: #{DateTime.to_string(memory.timestamp)}")
        IO.puts("Priority: #{memory.priority}")
        IO.puts("Source: #{memory.source}")
        
        unless Enum.empty?(memory.tags) do
          IO.puts("Tags: #{Enum.join(memory.tags, ", ")}")
        end
        
        if Map.has_key?(memory, :archived_at) do
          IO.puts("Archived at: #{DateTime.to_string(memory.archived_at)}")
        end
        
        IO.puts("\nContent:")
        IO.puts("#{memory.content}")
    end
  end
  
  @doc """
  Interactive help for CLI commands.
  """
  def help() do
    IO.puts("""
    
    === Memory Manager CLI Help ===
    
    Available commands:
    
    list()                    - List all memories
    list(:confirmed)          - List only confirmed memories  
    list(:hypothesis)         - List only hypothesis memories
    list(:archived)           - List archived memories
    
    search("query")           - Search memories by content
    
    stats()                   - Show memory statistics
    
    backup()                  - Create a backup of memories
    
    archive("memory_id")      - Archive a specific memory
    
    prune(criteria)           - Prune memories by criteria:
      {:older_than, days}        - Archive memories older than N days
      {:hypothesis_older_than, days} - Archive hypotheses older than N days  
      :low_priority             - Archive low priority memories
    
    show("memory_id")         - Show detailed memory information
    
    help()                    - Show this help message
    
    Examples:
      HelloBeam.MemoryManager.CLI.list()
      HelloBeam.MemoryManager.CLI.search("BEAM")
      HelloBeam.MemoryManager.CLI.prune({:hypothesis_older_than, 7})
    """)
  end
  
  # Private helper functions
  
  defp format_memory_item({memory, index}) do
    type_indicator = case memory.type do
      :confirmed -> "[✓]"
      :hypothesis -> "[?]"
      _ -> "[ ]"
    end
    
    timestamp = memory.timestamp |> DateTime.to_date() |> Date.to_string()
    content_preview = String.slice(memory.content, 0, 80)
    content_preview = if String.length(memory.content) > 80 do
      content_preview <> "..."
    else
      content_preview
    end
    
    IO.puts("#{index}. #{type_indicator} [#{timestamp}] #{content_preview}")
    IO.puts("   ID: #{memory.id}")
    
    unless Enum.empty?(memory.tags) do
      IO.puts("   Tags: #{Enum.join(memory.tags, ", ")}")
    end
    
    IO.puts("")
  end
  
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} bytes"
  defp format_bytes(bytes) when bytes < 1024 * 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end
  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024 do
    "#{Float.round(bytes / (1024 * 1024), 1)} MB"  
  end
  defp format_bytes(bytes) do
    "#{Float.round(bytes / (1024 * 1024 * 1024), 1)} GB"
  end
end