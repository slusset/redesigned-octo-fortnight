defmodule HelloBeam.ReasoningNode do
  @moduledoc """
  A process that can reason. Holds memories, accumulates learnings,
  and uses prior experience to inform future reasoning.

  This is the smallest possible "filled triangle" in the fractal —
  a single node with governance (role), runtime (reasoning), and
  adaptation (memory).
  """

  use GenServer
  require Logger

  @workspace_dir Path.join(File.cwd!(), "priv/workspace")
  @proposals_dir Path.join(File.cwd!(), "priv/workspace/proposals")
  @default_max_iterations 25
  @protected_modules ~w(
    reasoning_node.ex application.ex proposals.ex beam_shell.ex
    memory_manager.ex
  )

  defp max_iterations, do: Application.get_env(:hello_beam, :max_iterations, @default_max_iterations)

  # -- Public API --

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Ask the node to reason about something. Returns the response.
  """
  def reason(pid \\ __MODULE__, prompt) do
    GenServer.call(pid, {:reason, prompt}, :infinity)
  end

  @doc """
  See what the node remembers.
  """
  def memories(pid \\ __MODULE__) do
    GenServer.call(pid, :memories)
  end

  @doc """
  See the full state — the node's entire reality.
  """
  def introspect(pid \\ __MODULE__) do
    GenServer.call(pid, :introspect)
  end

  @doc """
  Teach the node something directly — add a confirmed memory.
  """
  def teach(pid \\ __MODULE__, content) do
    GenServer.cast(pid, {:teach, content})
  end

  @doc """
  Execute a tool on behalf of the reasoning node.
  This is the node's hands — how it acts on the world.
  """
  def tool(pid \\ __MODULE__, action) do
    GenServer.call(pid, {:tool, action}, 30_000)
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    role = Keyword.get(opts, :role, "You are a reasoning node in a BEAM supervision tree.")
    context = Keyword.get(opts, :context, "")

    # Load memories from previous life — the node remembers across restarts
    persisted_memories = load_persisted_memories()

    # Ensure the workspace sandbox exists
    File.mkdir_p!(Path.join(@workspace_dir, "test"))
    File.mkdir_p!(Path.join(@workspace_dir, "lib"))
    File.mkdir_p!(Path.join(@workspace_dir, "proposals"))

    state = %{
      role: role,
      context: context,
      memories: persisted_memories,
      reasoning_count: 0,
      test_runs: %{}
    }

    Logger.info("ReasoningNode started with #{length(persisted_memories)} memories from previous life")
    {:ok, state}
  end

  @impl true
  def handle_call({:reason, prompt}, _from, state) do
    %{system: system} = build_messages(state, prompt)
    messages = [%{role: "user", content: prompt}]
    start_time = System.monotonic_time(:millisecond)
    memory_count_before = length(state.memories)

    case agentic_loop(system, messages, state, max_iterations()) do
      {:ok, response, state, tool_log, iterations_left} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        state =
          state
          |> Map.update!(:reasoning_count, &(&1 + 1))
          |> maybe_extract_memory(prompt, response)

        memories_created = length(state.memories) - memory_count_before

        HelloBeam.ReasoningLog.append(%{
          prompt: prompt,
          response: String.slice(response, 0, 500),
          tools_used: tool_log,
          iterations_used: max_iterations() - iterations_left,
          max_iterations: max_iterations(),
          duration_ms: duration_ms,
          memories_created: memories_created,
          status: "ok"
        })

        {:reply, {:ok, response}, state}

      {:error, :max_iterations_reached, tool_log} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        HelloBeam.ReasoningLog.append(%{
          prompt: prompt,
          response: "(max iterations reached)",
          tools_used: tool_log,
          iterations_used: max_iterations(),
          max_iterations: max_iterations(),
          duration_ms: duration_ms,
          memories_created: 0,
          status: "max_iterations_reached"
        })

        {:reply, {:error, :max_iterations_reached}, state}

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        HelloBeam.ReasoningLog.append(%{
          prompt: prompt,
          response: inspect(reason),
          tools_used: [],
          iterations_used: 0,
          max_iterations: max_iterations(),
          duration_ms: duration_ms,
          memories_created: 0,
          status: "error"
        })

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:memories, _from, state) do
    {:reply, state.memories, state}
  end

  def handle_call(:introspect, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:tool, action}, _from, state) do
    {result, state} = execute_tool(action, state)
    {:reply, result, state}
  end

  @impl true
  def handle_cast({:teach, content}, state) do
    memory = %{
      content: content,
      type: :confirmed,
      source: :direct_teaching,
      at: DateTime.utc_now()
    }

    state = %{state | memories: [memory | state.memories]}
    persist_memories(state)
    {:noreply, state}
  end

  # -- Async test results arrive here --

  @impl true
  def handle_info({ref, {:test_complete, exit_code, output}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    ref_string = inspect(ref)
    state = update_test_run(state, ref_string, exit_code, output)
    Logger.info("Test run #{ref_string} completed with exit code #{exit_code}")
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    ref_string = inspect(ref)

    if Map.has_key?(state.test_runs, ref_string) do
      run = state.test_runs[ref_string]

      updated = %{
        run
        | status: :error,
          output: "Task crashed: #{inspect(reason)}",
          finished_at: DateTime.utc_now()
      }

      state = put_in(state, [:test_runs, ref_string], updated)
      Logger.warning("Test run #{ref_string} crashed: #{inspect(reason)}")
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  # -- Private --

  defp build_messages(state, prompt) do
    system_parts = [state.role]

    system_parts =
      if state.context != "" do
        system_parts ++ ["\n\nContext:\n" <> state.context]
      else
        system_parts
      end

    system_parts =
      if state.memories != [] do
        memory_text =
          state.memories
          |> Enum.map(fn m ->
            type_tag = if m.type == :confirmed, do: "CONFIRMED", else: "HYPOTHESIS"
            "[#{type_tag}] #{m.content}"
          end)
          |> Enum.join("\n")

        system_parts ++ ["\n\nYour accumulated memories:\n" <> memory_text]
      else
        system_parts
      end

    system = Enum.join(system_parts)

    %{system: system, prompt: prompt}
  end

  # -- Sandbox: all file operations are confined to priv/workspace/ --

  defp sandbox_path(user_path) do
    joined = Path.join(@workspace_dir, user_path)
    canonical = Path.expand(joined)

    if String.starts_with?(canonical, @workspace_dir <> "/") or canonical == @workspace_dir do
      {:ok, canonical}
    else
      {:error, :sandbox_escape}
    end
  end

  # -- Boundaries: constraints that teach rather than just block --

  @boundaries [
    %{
      id: :sandbox,
      constraint: "All file operations (read, write, list) are confined to priv/workspace/.",
      why: "Prevents accidental modification of the project source or system files.",
      alternative: "To promote code into the main codebase, use the propose_module tool."
    },
    %{
      id: :protected_modules,
      constraint: "Core modules (reasoning_node, application, proposals, beam_shell, memory_manager) cannot be overwritten via proposals.",
      why: "Protects the node's own infrastructure from self-modification that could break the system.",
      alternative: "Propose new modules with unique names instead. The supervisor can manually update core modules."
    },
    %{
      id: :test_file_naming,
      constraint: "Test files must end in _test.exs to be executed by run_tests.",
      why: "ExUnit convention — ensures only intentional test files are executed.",
      alternative: "Name your test files with the _test.exs suffix (e.g., 'test/my_hypothesis_test.exs')."
    },
    %{
      id: :proposal_naming,
      constraint: "Proposal names must be snake_case (lowercase letters, digits, underscores).",
      why: "Ensures consistent, filesystem-safe naming for proposal directories.",
      alternative: "Use names like 'log_viewer' or 'health_check' instead of camelCase or special characters."
    }
  ]

  defp boundary_error(boundary_id, context, state) do
    boundary = Enum.find(@boundaries, &(&1.id == boundary_id))

    message = """
    Boundary: #{boundary.constraint}
    Why: #{boundary.why}
    Alternative: #{boundary.alternative}
    Context: #{context}\
    """

    # Auto-teach the boundary on first encounter
    state = teach_boundary_once(state, boundary_id, boundary)

    {message, state}
  end

  defp teach_boundary_once(state, boundary_id, boundary) do
    tag = "boundary:#{boundary_id}"

    already_known =
      Enum.any?(state.memories, fn m ->
        m.type == :confirmed and String.contains?(m.content, tag)
      end)

    if already_known do
      state
    else
      memory = %{
        content: "[#{tag}] #{boundary.constraint} Alternative: #{boundary.alternative}",
        type: :confirmed,
        source: :boundary_teaching,
        at: DateTime.utc_now()
      }

      state = %{state | memories: [memory | state.memories]}
      persist_memories(state)
      Logger.info("ReasoningNode learned boundary: #{boundary_id}")
      state
    end
  end

  # -- Agentic loop: reason → tool call → feed result → repeat --

  defp agentic_loop(system, messages, state, iterations_left, tool_log \\ [])

  defp agentic_loop(_system, _messages, _state, 0, tool_log) do
    {:error, :max_iterations_reached, tool_log}
  end

  defp agentic_loop(system, messages, state, iterations_left, tool_log) do
    case call_claude_api(system, messages) do
      {:ok, %{"content" => content, "stop_reason" => stop_reason}} ->
        case stop_reason do
          "end_turn" ->
            text = extract_text(content)
            {:ok, text, state, tool_log, iterations_left}

          "tool_use" ->
            # Claude wants to use tools — execute them and continue
            {tool_results, state} = execute_tool_calls(content, state)

            # Record which tools were called for the reasoning log
            tool_use_blocks = Enum.filter(content, &(&1["type"] == "tool_use"))

            new_entries =
              Enum.map(tool_use_blocks, fn block ->
                %{name: block["name"], input_keys: Map.keys(block["input"] || %{})}
              end)

            # Append assistant message + tool results, then loop
            updated_messages =
              messages ++
                [%{role: "assistant", content: content}] ++
                [%{role: "user", content: tool_results}]

            Logger.info("ReasoningNode tool loop: #{length(tool_results)} tool(s) called, #{iterations_left - 1} iterations remaining")
            agentic_loop(system, updated_messages, state, iterations_left - 1, tool_log ++ new_entries)

          other ->
            text = extract_text(content)
            Logger.info("ReasoningNode stop_reason=#{other}")
            {:ok, text, state, tool_log, iterations_left}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_claude_api(system, messages) do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      {:error, :no_api_key}
    else
      body = %{
        model: "claude-sonnet-4-20250514",
        max_tokens: 4096,
        system: system,
        tools: tool_definitions(),
        messages: messages
      }

      case Req.post("https://api.anthropic.com/v1/messages",
             json: body,
             headers: [
               {"x-api-key", api_key},
               {"anthropic-version", "2023-06-01"}
             ],
             receive_timeout: 120_000
           ) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body}

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map(& &1["text"])
    |> Enum.join("\n")
  end

  defp extract_text(_), do: ""

  defp execute_tool_calls(content, state) when is_list(content) do
    tool_use_blocks = Enum.filter(content, &(&1["type"] == "tool_use"))

    {results, state} =
      Enum.reduce(tool_use_blocks, {[], state}, fn block, {acc, st} ->
        {result, st} = dispatch_tool(block["name"], block["input"], st)

        tool_result = %{
          type: "tool_result",
          tool_use_id: block["id"],
          content: to_string(result)
        }

        {acc ++ [tool_result], st}
      end)

    {results, state}
  end

  defp dispatch_tool("write_file", %{"path" => path, "content" => content}, state) do
    case execute_tool({:write_file, path, content}, state) do
      {{:ok, :written}, state} -> {"File written successfully: #{path}", state}
      {{:error, :sandbox_escape}, state} -> boundary_error(:sandbox, "write_file path: #{path}", state)
      {{:error, reason}, state} -> {"Error writing file: #{inspect(reason)}", state}
    end
  end

  defp dispatch_tool("read_file", %{"path" => path}, state) do
    case execute_tool({:read_file, path}, state) do
      {{:ok, content}, state} -> {content, state}
      {{:error, :sandbox_escape}, state} -> boundary_error(:sandbox, "read_file path: #{path}", state)
      {{:error, reason}, state} -> {"Error reading file: #{inspect(reason)}", state}
    end
  end

  defp dispatch_tool("list_dir", %{"path" => path}, state) do
    case execute_tool({:list_dir, path}, state) do
      {{:ok, entries}, state} -> {Enum.join(entries, "\n"), state}
      {{:error, :sandbox_escape}, state} -> boundary_error(:sandbox, "list_dir path: #{path}", state)
      {{:error, reason}, state} -> {"Error listing directory: #{inspect(reason)}", state}
    end
  end

  defp dispatch_tool("self_inspect", _input, state) do
    case execute_tool(:self_inspect, state) do
      {{:ok, info}, state} -> {inspect(info, pretty: true), state}
      {{:error, reason}, state} -> {"Error: #{inspect(reason)}", state}
    end
  end

  defp dispatch_tool("store_memory", %{"content" => content, "type" => type}, state) do
    memory = %{
      content: content,
      type: String.to_existing_atom(type),
      source: :self_stored,
      at: DateTime.utc_now()
    }

    state = %{state | memories: [memory | state.memories]}
    persist_memories(state)
    Logger.info("ReasoningNode stored #{type} memory: #{String.slice(content, 0, 80)}")
    {"Memory stored.", state}
  end

  defp dispatch_tool("run_tests", %{"test_file" => test_file}, state) do
    case sandbox_path(test_file) do
      {:ok, safe_path} ->
        cond do
          not String.ends_with?(safe_path, "_test.exs") ->
            boundary_error(:test_file_naming, "run_tests file: #{test_file}", state)

          not File.exists?(safe_path) ->
            {"Error: Test file does not exist at '#{test_file}'. " <>
             "Use list_dir to see available files, or write_file to create the test first.", state}

          true ->
            {ref_string, state} = run_test_async(safe_path, state)
            Logger.info("ReasoningNode launched test run #{ref_string} for #{test_file}")
            {"Test run started. run_id: #{ref_string}", state}
        end

      {:error, :sandbox_escape} ->
        boundary_error(:sandbox, "run_tests path: #{test_file}", state)
    end
  end

  defp dispatch_tool("check_test_results", %{"run_id" => run_id}, state) do
    case Map.get(state.test_runs, run_id) do
      nil ->
        {"Error: No test run found with run_id: #{run_id}", state}

      %{status: :running} ->
        {"Status: running\nTests are still executing.", state}

      %{status: status, output: output, test_summary: summary} ->
        summary_text =
          if summary do
            "Tests: #{summary.total}, Passed: #{summary.passed}, Failed: #{summary.failed}, Skipped: #{summary.skipped}"
          else
            "Could not parse test summary from output."
          end

        truncated_output = String.slice(output || "", 0, 3000)
        result = "Status: #{status}\n#{summary_text}\n\nOutput:\n#{truncated_output}"
        {result, state}
    end
  end

  defp dispatch_tool("list_boundaries", _input, state) do
    text =
      @boundaries
      |> Enum.map(fn b ->
        """
        [#{b.id}]
          Constraint:  #{b.constraint}
          Why:         #{b.why}
          Alternative: #{b.alternative}
        """
      end)
      |> Enum.join("\n")

    {"Active Boundaries:\n\n#{text}", state}
  end

  defp dispatch_tool("propose_module", params, state) do
    %{"name" => name, "module_code" => code, "intent" => intent, "target_path" => target_path} = params

    cond do
      not Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) ->
        boundary_error(:proposal_naming, "propose_module name: #{name}", state)

      Path.basename(target_path) in @protected_modules ->
        boundary_error(:protected_modules, "propose_module target: #{target_path}", state)

      true ->
        proposal_dir = Path.join(@proposals_dir, name)
        File.mkdir_p!(proposal_dir)

        File.write!(Path.join(proposal_dir, "module.ex"), code)
        File.write!(Path.join(proposal_dir, "intent.md"), """
        # Proposal: #{name}

        ## Target Path
        lib/#{target_path}

        ## Intent
        #{intent}

        ## Proposed At
        #{DateTime.utc_now()}
        """)

        Logger.info("ReasoningNode proposed module '#{name}' targeting lib/#{target_path}")

        {"Proposal '#{name}' saved for supervisor review. " <>
         "The supervisor can review it with: HelloBeam.Proposals.review(\"#{name}\") " <>
         "and accept with: HelloBeam.Proposals.accept(\"#{name}\")", state}
    end
  end

  defp dispatch_tool(name, _input, state) do
    {"Unknown tool: #{name}", state}
  end

  # -- Tool definitions for Claude API --

  defp tool_definitions do
    [
      %{
        name: "write_file",
        description: "Write content to a file in your workspace sandbox (priv/workspace/). Creates parent directories if needed. Paths are relative to the workspace root.",
        input_schema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "File path relative to the workspace sandbox (e.g., 'test/my_test.exs' or 'lib/helper.ex')"},
            content: %{type: "string", description: "Content to write"}
          },
          required: ["path", "content"]
        }
      },
      %{
        name: "read_file",
        description: "Read the contents of a file from your workspace sandbox (priv/workspace/).",
        input_schema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "File path relative to the workspace sandbox"}
          },
          required: ["path"]
        }
      },
      %{
        name: "list_dir",
        description: "List the contents of a directory in your workspace sandbox (priv/workspace/).",
        input_schema: %{
          type: "object",
          properties: %{
            path: %{type: "string", description: "Directory path relative to the workspace sandbox (e.g., '.' for root, 'test' for test dir)"}
          },
          required: ["path"]
        }
      },
      %{
        name: "self_inspect",
        description: "Inspect your own process — see your PID, memory usage, supervision tree, and workshop children.",
        input_schema: %{
          type: "object",
          properties: %{}
        }
      },
      %{
        name: "store_memory",
        description: "Store a memory that will persist across restarts. Use type 'confirmed' for verified facts and 'hypothesis' for unverified observations.",
        input_schema: %{
          type: "object",
          properties: %{
            content: %{type: "string", description: "The memory content to store"},
            type: %{type: "string", enum: ["confirmed", "hypothesis"], description: "Memory confidence level"}
          },
          required: ["content", "type"]
        }
      },
      %{
        name: "run_tests",
        description: "Run an ExUnit test file from your workspace sandbox. Executes asynchronously — returns a run_id immediately. Use check_test_results with the run_id to poll for completion. The test file must be in the workspace and end in _test.exs. This is how you validate hypotheses empirically.",
        input_schema: %{
          type: "object",
          properties: %{
            test_file: %{
              type: "string",
              description: "Path to the test file relative to the workspace (e.g., 'test/my_hypothesis_test.exs')"
            }
          },
          required: ["test_file"]
        }
      },
      %{
        name: "check_test_results",
        description: "Check the status and results of a previously launched test run. Returns status (running/passed/failed/error), a summary with pass/fail counts, and the test output.",
        input_schema: %{
          type: "object",
          properties: %{
            run_id: %{
              type: "string",
              description: "The run_id returned by run_tests"
            }
          },
          required: ["run_id"]
        }
      },
      %{
        name: "list_boundaries",
        description: "List all active constraints and boundaries that govern your actions. Each boundary explains what is restricted, why, and what the legitimate alternative is. Use this to understand your operating environment before acting.",
        input_schema: %{
          type: "object",
          properties: %{}
        }
      },
      %{
        name: "propose_module",
        description: """
        Propose a new Elixir module for graduation into the main codebase. \
        The module source and your intent declaration are saved for the human \
        supervisor to review. They will accept or reject the proposal — you \
        cannot install modules directly. Core modules (reasoning_node, application, \
        proposals, beam_shell, memory_manager) are protected and cannot be overwritten. \
        Follow your dharma: declare your intent clearly.\
        """,
        input_schema: %{
          type: "object",
          properties: %{
            name: %{
              type: "string",
              description: "Snake_case name for the module (e.g., 'log_viewer', 'health_check')"
            },
            module_code: %{
              type: "string",
              description: "The complete Elixir source code for the module"
            },
            intent: %{
              type: "string",
              description: "Why this module should exist — what need it addresses, what problem it solves. Be specific."
            },
            target_path: %{
              type: "string",
              description: "Suggested path under lib/ (e.g., 'hello_beam/log_viewer.ex')"
            }
          },
          required: ["name", "module_code", "intent", "target_path"]
        }
      }
    ]
  end

  defp maybe_extract_memory(state, _prompt, response) do
    # Extract all MEMORY: lines from the response
    memories =
      Regex.scan(~r/MEMORY:\s*(.+?)(?:\n|$)/, response)
      |> Enum.map(fn [_, content] ->
        %{
          content: String.trim(content),
          type: :hypothesis,
          source: :self_extracted,
          at: DateTime.utc_now()
        }
      end)

    case memories do
      [] ->
        state

      new_memories ->
        state = %{state | memories: new_memories ++ state.memories}
        persist_memories(state)
        state
    end
  end

  # -- Tools: the node's hands --

  defp execute_tool({:write_file, path, content}, state) do
    case sandbox_path(path) do
      {:ok, safe_path} ->
        case File.mkdir_p(Path.dirname(safe_path)) do
          :ok ->
            case File.write(safe_path, content) do
              :ok ->
                Logger.info("ReasoningNode wrote file: #{safe_path}")
                {{:ok, :written}, state}

              {:error, reason} ->
                {{:error, reason}, state}
            end

          {:error, reason} ->
            {{:error, reason}, state}
        end

      {:error, :sandbox_escape} ->
        Logger.warning("ReasoningNode sandbox escape attempt: #{path}")
        {{:error, :sandbox_escape}, state}
    end
  end

  defp execute_tool({:read_file, path}, state) do
    case sandbox_path(path) do
      {:ok, safe_path} ->
        case File.read(safe_path) do
          {:ok, content} -> {{:ok, content}, state}
          {:error, reason} -> {{:error, reason}, state}
        end

      {:error, :sandbox_escape} ->
        Logger.warning("ReasoningNode sandbox escape attempt: #{path}")
        {{:error, :sandbox_escape}, state}
    end
  end

  defp execute_tool({:list_dir, path}, state) do
    case sandbox_path(path) do
      {:ok, safe_path} ->
        case File.ls(safe_path) do
          {:ok, entries} -> {{:ok, Enum.sort(entries)}, state}
          {:error, reason} -> {{:error, reason}, state}
        end

      {:error, :sandbox_escape} ->
        Logger.warning("ReasoningNode sandbox escape attempt: #{path}")
        {{:error, :sandbox_escape}, state}
    end
  end

  defp execute_tool(:self_inspect, state) do
    pid = self()

    info = %{
      pid: inspect(pid),
      process_info: Process.info(pid, [:memory, :message_queue_len, :reductions, :status]),
      supervision_tree: Supervisor.which_children(HelloBeam.Supervisor),
      memory_count: length(state.memories),
      reasoning_count: state.reasoning_count,
      workshop_children: Task.Supervisor.children(HelloBeam.Workshop)
    }

    {{:ok, info}, state}
  end

  defp execute_tool(action, state) do
    {{:error, {:unknown_tool, action}}, state}
  end

  # -- Async test execution --

  defp run_test_async(safe_test_path, state) do
    project_root = File.cwd!()

    task =
      Task.Supervisor.async_nolink(HelloBeam.Workshop, fn ->
        {output, exit_code} =
          System.cmd(
            "mix",
            ["test", safe_test_path, "--no-deps-check", "--timeout", "30000"],
            cd: project_root,
            stderr_to_stdout: true,
            env: [{"MIX_ENV", "test"}]
          )

        {:test_complete, exit_code, output}
      end)

    ref_string = inspect(task.ref)

    test_run = %{
      ref: ref_string,
      status: :running,
      test_file: safe_test_path,
      output: nil,
      exit_code: nil,
      started_at: DateTime.utc_now(),
      finished_at: nil,
      test_summary: nil
    }

    state = put_in(state, [:test_runs, ref_string], test_run)
    {ref_string, state}
  end

  defp update_test_run(state, ref_string, exit_code, output) do
    case Map.get(state.test_runs, ref_string) do
      nil ->
        state

      run ->
        summary = parse_test_output(output)
        status = if exit_code == 0, do: :passed, else: :failed

        updated = %{
          run
          | status: status,
            exit_code: exit_code,
            output: output,
            finished_at: DateTime.utc_now(),
            test_summary: summary
        }

        put_in(state, [:test_runs, ref_string], updated)
    end
  end

  defp parse_test_output(output) do
    case Regex.run(~r/(\d+) tests?, (\d+) failures?(?:, (\d+) skipped)?/, output) do
      [_, total, failed] ->
        t = String.to_integer(total)
        f = String.to_integer(failed)
        %{total: t, failed: f, skipped: 0, passed: t - f}

      [_, total, failed, skipped] ->
        t = String.to_integer(total)
        f = String.to_integer(failed)
        s = String.to_integer(skipped)
        %{total: t, failed: f, skipped: s, passed: t - f - s}

      nil ->
        nil
    end
  end

  # -- Memory persistence --

  @memory_dir "priv/memories"

  defp memory_file do
    Path.join([File.cwd!(), @memory_dir, "reasoning_node.bin"])
  end

  defp persist_memories(state) do
    path = memory_file()
    File.mkdir_p!(Path.dirname(path))
    binary = :erlang.term_to_binary(state.memories)
    File.write!(path, binary)
    Logger.debug("Persisted #{length(state.memories)} memories to #{path}")
  end

  defp load_persisted_memories do
    path = memory_file()

    case File.read(path) do
      {:ok, binary} ->
        memories = :erlang.binary_to_term(binary)
        Logger.info("Loaded #{length(memories)} persisted memories from #{path}")
        memories

      {:error, :enoent} ->
        Logger.info("No persisted memories found — starting fresh")
        []

      {:error, reason} ->
        Logger.warning("Failed to load memories: #{inspect(reason)} — starting fresh")
        []
    end
  end
end
