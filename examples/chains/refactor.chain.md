---
name: refactor
---

## analyze
tools: read_file, search_files, list_files
max_iterations: 5

Analyze the code related to: {task}

Identify code smells, duplication, tight coupling, and improvement opportunities. List specific files and line ranges.

## plan
max_iterations: 3

Based on the analysis:
{previous}

Create a refactoring plan for: {task}

Prioritize changes by impact. Ensure backward compatibility. Identify which changes can be made safely and which need careful testing.

## implement
tools: read_file, write_file, search_files, execute_bash

Execute the refactoring plan:
{previous}

Make changes incrementally. After each significant change, verify the build still passes.

## test
tools: read_file, execute_bash, search_files
max_iterations: 5

Verify the refactoring for: {task}
Changes made: {previous}

Run all relevant tests. Check that no functionality was broken. Report any issues found.
