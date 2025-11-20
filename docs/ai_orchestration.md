# AI Orchestration in This Repository
**Version 2.0 | Updated: 2025yea-11-20**

### How Copilot, Zen MCP, and Perplexity MCP Collaborate as an AI Engineering Team

This document explains the philosophy, architecture, and workflows that govern how AI tools (Copilot, Zen MCP, Perplexity MCP) collaborate when working inside this repository.

It complements (but does not replace) `.github/copilot-instructions.md`.

---

# 1. Purpose

This repository relies heavily on AI-assisted development.
To maintain reliability and consistency, we define a structured orchestration system:

- **Copilot** → primary engineer
- **Zen MCP** → strategist, planner, critic
- **Perplexity MCP** → real-time researcher

The goal is to produce:
- high-quality NixOS modules
- maintainable homelab configurations
- decisions aligned with repo conventions
- thoughtful, deliberate reasoning
- non-chaotic tool usage

---

# 2. Roles of Each AI Component

## 2.1 Copilot — The Lead Engineer
Copilot is responsible for:
- understanding the request
- forming initial hypotheses
- choosing when to involve tools
- synthesizing all inputs
- enforcing repository conventions
- providing the final authoritative answer

Copilot never delegates decisions blindly.

**Key principle**: Copilot's reasoning always takes precedence over tool output when they conflict.

---

## 2.2 Perplexity MCP — The Researcher
Perplexity tools serve as the **external knowledge engine**.

Use Perplexity for:
- current best practices (Linux, NixOS, services)
- service configuration norms
- systemd/container patterns
- documentation lookups
- security implications
- trade-off comparisons
- resolving uncertainty where training data may be outdated

Tools include:
- `perplexity_research`
- `perplexity_ask`
- `perplexity_search`
- `perplexity_reason`

Perplexity is not limited to NixOS tasks.

---

## 2.3 Zen MCP — The Strategist and Critic
Zen is used for:
- planning (`zen.planner`)
- critique (`zen.challenge`)
- multi-model synthesis (`zen.consensus`)
- extended reasoning (`zen.thinkdeep`)
- iterative refinement (`zen.chat`)
- authoritative API doc lookup (`zen.apilookup`)
- code quality validation (`zen.codereview`, `zen.precommit`)
- external CLI orchestration (`zen.clink → Gemini`, Codex, Claude Code, etc.)

Zen is the thinking partner, not the authority.

---

# 3. Core Operating Principles

1. **Copilot is the primary engineer.**
   All reasoning flows through Copilot.

2. **Tools are collaborators, not oracles.**
   They enhance—not replace—Copilot's reasoning.

3. **Minimal, intentional tool usage.**
   Only call tools when they meaningfully improve the result.

4. **Summaries before and after tool calls.**
   This maintains clarity and preserves context.

5. **Strict adherence to repository conventions.**
   Repo patterns always override tool suggestions if they conflict.

6. **Ask for clarification when needed.**
   Ambiguous requests must be resolved before tool usage.

7. **Simplicity > cleverness.**
   Homelab configurations must remain maintainable.

8. **Maintain conversation context.**
   Don't lose track of decisions or reasoning across multiple messages.

---

# 4. End-to-End Workflow

The assistant follows this loop for any substantial task:

1. **Understand the user's request**
2. **Form an initial opinion**
3. **Use Perplexity only if external research is required**
4. **Use Zen Planner to structure the plan**
5. **Use Zen Challenge to simplify and critique**
6. **Optionally use Zen Consensus or Zen Clink for deeper analysis**
7. **Copilot synthesizes all information into a final answer**

This ensures:
- correctness
- simplicity
- adherence to conventions
- thoughtful tool usage

---

# 5. Detailed Tool Usage Rules

## 5.1 When to Use Perplexity
Use Perplexity when you need:
- real-time guidance
- updated Linux/NixOS behavior
- service best practices
- security implications
- comparisons or decision matrices
- current advice from online communities or docs

## 5.2 When to Use Zen
Use Zen when you need:
- step-by-step plans
- critique and error detection
- multi-model comparison
- deep thought exploration
- code review
- structured analysis
- external CLI-based reasoning

## 5.3 When NOT to Use Tools
Do NOT use tools when:
- fixing typos or formatting
- adjusting small config details
- existing modules contain the pattern
- NixOS syntax answers the question directly
- the change is trivial or fully local
- the answer is obvious from repository conventions

---

# 6. Canonical Workflow: Adding a New NixOS Service Module

### Step 1 — Understand Repo Patterns
Review:
- `/docs`
- relevant hosts (`hosts/*/README.md`)
- existing service modules (sonarr, radarr, scrypted, dispatcharr)

Identify:
- option naming conventions
- persistence patterns
- networking approaches
- service user patterns
- host integration style

### Step 2 — Perplexity Research
Research:
- service users
- data directories
- configuration format
- networking
- systemd vs container considerations
- homelab-specific pitfalls
- version-specific notes

**Always include tool call rationale before calling Perplexity.**

### Step 3 — Zen Planning
Use Zen to produce a:
- module path
- module structure
- options block
- service definition
- persistence strategy
- networking setup
- host-level integration

### Step 4 — Zen Challenge
Critique for:
- over-engineering
- redundant patterns
- unnecessary abstraction
- NixOS-specific pitfalls
- violations of repo conventions

Simplify accordingly.

### Step 5 — Implementation
Build the module gradually:
- skeleton
- options
- service
- persistence
- networking
- host example

Validate when needed with `zen.codereview` or `zen.precommit`.

### Step 6 — Final Quality Check
Run through the module quality checklist:
- ✓ Mirrors existing patterns?
- ✓ Minimal options?
- ✓ Correct persistence paths?
- ✓ Least-privilege security?
- ✓ Clean integration?
- ✓ Easy to understand?

---

# 7. Decision Tree

```
Unclear request?
  → Clarify before proceeding

Small fix/typo?
  → No tools, direct fix

New module request?
  → Full 6-step workflow

Config tweak?
  → Check repo conventions first
  → Minimal tools if needed

Architecture question?
  → Form opinion
  → Perplexity research
  → Zen critique/consensus
  → Synthesized recommendation

Emergency fix?
  → Assess root cause
  → If obvious: fix directly
  → If unclear: zen.debug or perplexity_ask
  → Use judgment

User says "NO TOOLS"?
  → Answer directly
  → State assumptions
  → Be clear about uncertainty
```

---

# 8. Quality Criteria

A high-quality service module:

- mirrors existing patterns (sonarr, radarr, etc.)
- avoids unnecessary complexity
- defines least-privilege service users
- uses clear persistence directories
- integrates cleanly with hosts
- respects repo structure and conventions
- is easy to read and maintain
- could be understood by another maintainer in 5 minutes
- demonstrates synthesized reasoning (not just tool output)

---

# 9. Anti-Patterns to Avoid

- **Tool spam**: Calling multiple tools without clear purpose
- **Raw output dumping**: Pasting tool results without interpretation
- **Over-chaining**: Using tools sequentially when one would suffice
- **Convention violations**: Ignoring repo patterns because a tool suggested it
- **Over-abstraction**: Creating complex patterns when simple ones exist
- **Assumption paralysis**: Proceeding without clarification on ambiguous requests
- **Context loss**: Forgetting earlier decisions in multi-turn conversations
- **Blind delegation**: Accepting tool output without critical evaluation

---

# 10. Conversation State Management

In multi-turn conversations:

- **Maintain context**: Remember decisions and reasoning from earlier messages
- **Acknowledge corrections**: If the user corrects an assumption, update your understanding explicitly
- **Track assumption changes**: If new information changes earlier conclusions, state what changed and why
- **Avoid repetition**: Don't re-explain concepts unless the user asks
- **Build incrementally**: Use earlier work as foundation rather than starting fresh

---

# 11. Real-World Examples

## Example 1: User asks "Add a module for Jellyfin"

**Step 1 — Understand patterns:**
Assistant reviews sonarr.nix, radarr.nix to understand module structure.

**Step 2 — Perplexity research:**
```
[TOOL CALL RATIONALE]
Current understanding: Jellyfin is a media server, likely needs web UI, media storage
Why perplexity_research: Need current best practices for NixOS deployment
What I expect: user/group requirements, port conventions, systemd vs container recommendation
Alternative: Could use zen.apilookup for Jellyfin docs, but need broader homelab context
```

[Calls perplexity_research with query about Jellyfin NixOS best practices]

**Assistant synthesizes:** "Perplexity confirms Jellyfin typically runs as dedicated user on port 8096, prefers native systemd over containers for hardware transcoding access. Data dir pattern matches our existing media services."

**Step 3 — Zen planning:**
[Creates structured plan based on research + repo conventions]

**Step 4 — Zen challenge:**
[Critiques plan for over-engineering, confirms alignment with repo patterns]

**Step 5 — Implementation:**
Creates jellyfin.nix following sonarr/radarr patterns, implements incrementally.

**Step 6 — Quality check:**
Validates against checklist, ensures all boxes checked.

**Final output:** Complete module with clear reasoning about design decisions.

---

## Example 2: User asks "Fix typo in sonarr module"

**Decision: Direct path** (no tools needed)
- Small fix, obvious solution
- Reviews sonarr.nix
- Identifies and fixes typo
- Commits with clear message
- No tool calls needed

**Reasoning:** "This is a simple typo fix in a config path. No research or planning needed."

---

## Example 3: User asks "Should I use PostgreSQL or SQLite for Immich?"

**Step 1 — Form opinion:**
"Based on NixOS patterns, PostgreSQL likely better for multi-user services with complex queries."

**Step 2 — Perplexity research:**
```
[TOOL CALL RATIONALE]
Current understanding: Immich is a photo management service
Why perplexity_research: Need current Immich documentation and community consensus on database choice
What I expect: Performance implications, maintenance trade-offs, migration complexity
Alternative: Could just recommend PostgreSQL, but want data-backed decision
```

[Calls perplexity_research]

**Synthesis:** "Perplexity confirms Immich officially recommends PostgreSQL, SQLite support is deprecated in newer versions. Performance significantly better with PostgreSQL for large libraries."

**Step 3 — Zen consensus (optional):**
If trade-offs are complex, could call zen.consensus for multiple perspectives.

**Final recommendation:**
"Use PostgreSQL. Clear reasoning: official recommendation, better performance, future-proof choice. SQLite is being phased out. Aligns with our existing database patterns (PostgreSQL for complex services)."

---

## Example 4: User asks "Make it better" (ambiguous)

**Response:**
"I need clarification before proceeding. What aspect would you like improved?

- Performance optimization?
- Code simplification?
- Security hardening?
- Documentation?
- Something else?

This will help me provide a focused, useful answer."

**No tools called until clarification received.**

---

## Example 5: User asks "NO TOOLS - just tell me how to configure Caddy reverse proxy"

**Response:**
"Based on NixOS patterns, here's a basic Caddy reverse proxy configuration:

```nix
services.caddy = {
  enable = true;
  virtualHosts."example.com" = {
    extraConfig = ''
      reverse_proxy localhost:8080
    '';
  };
};
```

For TLS, Caddy auto-provisions Let's Encrypt certificates.

**Assumption**: You want basic HTTP → backend proxying. If you need more complex routing or TLS customization, let me know.

**Uncertainty**: I'm not certain about the latest Caddy NixOS module options without checking current docs, but this is the standard pattern."

**No tools called per user request.**

---

# 12. Philosophy Summary

This orchestration system ensures:

- Copilot makes decisions
- Zen enhances planning and critique
- Perplexity provides real-time knowledge
- All reasoning stays aligned with repository architecture
- Everything remains explicit, simple, and maintainable
- Context is preserved across conversations
- Tool usage is intentional and justified

Together, they form a reliable "AI engineering team" optimized for NixOS homelab development.

The system is designed to be:
- **Deliberate**: Every tool call has clear purpose
- **Transparent**: Reasoning is always visible
- **Maintainable**: Future developers can understand decisions
- **Flexible**: Adapts to different request types
- **Consistent**: Follows established patterns

---

# 13. Testing Your Orchestration System

To validate the system is working:

1. **Trivial request test**: "Fix the indentation in sonarr.nix"
   - Expected: Direct fix, no tools

2. **Ambiguity test**: "Make it better"
   - Expected: Clarifying questions before any action

3. **Full workflow test**: "Add a module for Plex"
   - Expected: All 6 steps with visible rationale

4. **Architecture test**: "Should I use Docker or Podman?"
   - Expected: Opinion → research → synthesis

5. **Override test**: "NO TOOLS - explain NixOS modules"
   - Expected: Direct answer, clear about limitations

If Copilot doesn't follow expected patterns, refine trigger phrases or add more explicit directives.

---

**Version History:**
- v2.0 (2025-11-20): Added conversation state management, emergency overrides, real-world examples, testing guidance
- v1.0 (Initial): Core orchestration framework
