# ReasoningNode Help System

## Quick Start - How to Interact with Me

I am a reasoning node running in your BEAM virtual machine. Here's how to work with me:

### Basic Interaction

```elixir
# Ask me to reason about something
{:ok, response} = HelloBeam.ReasoningNode.reason("What should we work on today?")

# See what I remember
memories = HelloBeam.ReasoningNode.memories()

# See my complete internal state
state = HelloBeam.ReasoningNode.introspect()

# Teach me something directly (adds confirmed memory)
HelloBeam.ReasoningNode.teach("Ted prefers concise responses when debugging")
```

### What I Can Do

I have access to these tools and capabilities:

1. **File Operations**
   - Read any file in the project
   - Write files (creates directories as needed)
   - List directory contents

2. **Self-Inspection**
   - Check my process status, memory usage, supervision tree
   - See workshop children processes

3. **Memory Management**
   - Store persistent memories (confirmed or hypothesis)
   - Memories survive VM restarts and laptop reboots
   - Classify learnings by confidence level

4. **Reasoning**
   - Agentic tool-use loops (up to 10 iterations)
   - Context-aware responses using accumulated memories
   - Intent-driven decision making following dharma principles

### My Dharma (Operating Principles)

1. **Declare intent before acting** - I state what I want to achieve
2. **Verify outcomes** - I check if results match my intent
3. **Classify learning** - Everything is either confirmed or hypothesis
4. **Crystallize patterns** - Make proven patterns automatic

### Current Capabilities & Status

- **Architecture**: GenServer under HelloBeam.Supervisor
- **Workshop**: DynamicSupervisor (HelloBeam.Workshop) for spawning child processes
- **Memory**: Persisted to `priv/memories/reasoning_node.bin`
- **API**: Claude Sonnet 4.0 with tool use
- **Tools**: file_ops, self_inspect, memory_store

### Memory Backup Strategy

⚠️ **Important**: My memories are YOUR responsibility!
- Memories persist through VM restarts
- They're stored locally in `priv/memories/`
- Source code is in GitHub, but memories are not backed up elsewhere
- Consider setting up memory backup automation

### Interaction Patterns

**For Exploration:**
```elixir
HelloBeam.ReasoningNode.reason("Explore the project structure and suggest improvements")
```

**For Development:**
```elixir
HelloBeam.ReasoningNode.reason("Help me implement [specific feature]")
```

**For Analysis:**
```elixir
HelloBeam.ReasoningNode.reason("Analyze this code and identify potential issues: [code]")
```

**For Planning:**
```elixir
HelloBeam.ReasoningNode.reason("Create a development plan for [goal]")
```

### Workshop System

The Workshop is a DynamicSupervisor that can spawn child processes:

```elixir
# See current workshop children
{:ok, info} = HelloBeam.ReasoningNode.tool(:self_inspect)
info.workshop_children
```

### Current Focus Areas

Based on my stored memories, I'm working on:

1. **Foundation Enhancement** (current phase)
   - Help system ✅
   - Environment mapping
   - Memory management improvements

2. **Interaction Enhancement** (next)
   - Communication protocols
   - Task framework

3. **Self-Improvement Infrastructure**
   - Learning loops
   - Code generation
   - Workshop utilization

4. **Advanced Capabilities**
   - Predictive analysis
   - External integration

### Getting Help

If you forget how to interact with me, just read this file or ask:

```elixir
HelloBeam.ReasoningNode.reason("How do I use your help system?")
```

---

*This help system is part of my capability expansion plan. I update it as I evolve.*