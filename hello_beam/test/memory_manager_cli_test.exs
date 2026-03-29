defmodule HelloBeam.MemoryManager.CLITest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  
  alias HelloBeam.MemoryManager
  alias HelloBeam.MemoryManager.CLI
  
  setup do
    # Clean up and setup test environment
    File.rm_rf!("test/tmp")
    File.mkdir_p!("test/tmp/memories")
    File.mkdir_p!("test/tmp/memories/backups")
    File.mkdir_p!("test/tmp/memories/archive")

    # Point at test directories before starting
    Application.put_env(:hello_beam, :memory_dir, "test/tmp/memories")
    Application.put_env(:hello_beam, :backup_dir, "test/tmp/memories/backups")
    Application.put_env(:hello_beam, :archive_dir, "test/tmp/memories/archive")

    # Stop app to prevent supervisor from restarting MemoryManager
    Application.stop(:hello_beam)
    Process.sleep(50)

    # Start a fresh MemoryManager for this test
    {:ok, pid} = MemoryManager.start_link()

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      Application.delete_env(:hello_beam, :memory_dir)
      Application.delete_env(:hello_beam, :backup_dir)
      Application.delete_env(:hello_beam, :archive_dir)
      File.rm_rf!("test/tmp")
    end)

    %{manager_pid: pid}
  end
  
  describe "list command" do
    test "displays empty list when no memories exist" do
      output = capture_io(fn -> CLI.list() end)
      assert output =~ "No memories found"
    end
    
    test "displays memories with proper formatting" do
      MemoryManager.store_memory("Test memory content", :confirmed)
      
      output = capture_io(fn -> CLI.list() end)
      assert output =~ "Memory List"
      assert output =~ "[✓]"  # Confirmed indicator
      assert output =~ "Test memory content"
    end
    
    test "filters by memory type" do
      MemoryManager.store_memory("Confirmed memory", :confirmed)
      MemoryManager.store_memory("Hypothesis memory", :hypothesis)
      
      confirmed_output = capture_io(fn -> CLI.list(:confirmed) end)
      assert confirmed_output =~ "Confirmed memory"
      refute confirmed_output =~ "Hypothesis memory"
      
      hypothesis_output = capture_io(fn -> CLI.list(:hypothesis) end)
      assert hypothesis_output =~ "Hypothesis memory"
      refute hypothesis_output =~ "Confirmed memory"
    end
  end
  
  describe "search command" do
    test "finds matching memories" do
      MemoryManager.store_memory("Machine learning algorithms", :confirmed)
      MemoryManager.store_memory("Database systems", :hypothesis)
      
      output = capture_io(fn -> CLI.search("machine") end)
      assert output =~ "Search Results"
      assert output =~ "Machine learning algorithms"
      refute output =~ "Database systems"
    end
    
    test "shows no results message when nothing found" do
      MemoryManager.store_memory("Some content", :confirmed)
      
      output = capture_io(fn -> CLI.search("nonexistent") end)
      assert output =~ "No matching memories found"
    end
  end
  
  describe "stats command" do
    test "displays memory statistics" do
      MemoryManager.store_memory("Memory 1", :confirmed)
      MemoryManager.store_memory("Memory 2", :hypothesis)
      
      output = capture_io(fn -> CLI.stats() end)
      assert output =~ "Memory Statistics"
      assert output =~ "Confirmed memories: 1"
      assert output =~ "Hypothesis memories: 1"
      assert output =~ "Total memories: 2"
    end
  end
  
  describe "backup command" do
    test "creates backup successfully" do
      MemoryManager.store_memory("Backup test", :confirmed)
      
      output = capture_io(fn -> CLI.backup() end)
      assert output =~ "Backup created successfully"
    end
  end
  
  describe "help command" do
    test "displays help information" do
      output = capture_io(fn -> CLI.help() end)
      assert output =~ "Memory Manager CLI Help"
      assert output =~ "list()"
      assert output =~ "search"
      assert output =~ "backup"
    end
  end
end