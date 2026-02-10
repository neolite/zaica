---
name: code-review
---

## scout
tools: read_file, search_files, list_files
max_iterations: 5

Analyze the codebase for {task}. Document all relevant files, functions, and patterns you find. Be thorough — the planner depends on your analysis.

## planner
max_iterations: 3

Based on the analysis:
{previous}

The original task was: {task}

Create a step-by-step implementation plan. Number each step. Identify files to modify and potential risks.

## coder
tools: read_file, write_file, execute_bash, search_files

Implement the plan:
{previous}

Write clean, idiomatic code. Run any necessary build/test commands to verify your changes.

## reviewer
tools: read_file, search_files, execute_bash
max_iterations: 5

Review the implementation. The original request was: {task}
Previous step output: {previous}

Check for bugs, edge cases, code style issues, and missing error handling. Run tests if available.
