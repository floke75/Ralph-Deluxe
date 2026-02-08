<!-- Purpose: bats-core testing patterns for shell function and script validation. -->
<!-- Consumed by: coding-iteration skill loader when tasks include testing-bats, while writing or updating Bats tests. -->

# bats-core Testing Patterns

## Basic Test Syntax
```bash
@test "description of what is being tested" {
    run my_function "arg1" "arg2"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "expected output" ]]
}
```

## The `run` Command
- Captures exit code in `$status` and stdout+stderr in `$output`
- Prevents `set -e` from aborting the test on failure
- Always use `run` when testing a command that might fail

## Setup and Teardown
```bash
setup() {
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"
    # Create fixtures here
}

teardown() {
    rm -rf "$TEST_DIR"
}
```

## Testing Exit Codes
```bash
@test "function fails on missing input" {
    run my_function ""
    [[ "$status" -ne 0 ]]
}

@test "function succeeds with valid input" {
    run my_function "valid"
    [[ "$status" -eq 0 ]]
}
```

## Output Assertions (without bats-assert)
```bash
# Exact match
[[ "$output" == "expected" ]]

# Contains substring
[[ "$output" == *"substring"* ]]

# Regex match
[[ "$output" =~ ^[0-9]+$ ]]

# Line count
local line_count
line_count=$(echo "$output" | wc -l)
[[ "$line_count" -eq 3 ]]
```

## Working with Temporary Directories
```bash
@test "creates expected files" {
    run my_function "$TEST_DIR"
    [[ "$status" -eq 0 ]]
    [[ -f "$TEST_DIR/output.json" ]]
}
```

## Loading Source Files
```bash
setup() {
    TEST_DIR=$(mktemp -d)
    # Source the module under test
    source "${BATS_TEST_DIRNAME}/../.ralph/lib/plan-ops.sh"
}
```

## Testing JSON Output
```bash
@test "outputs valid JSON" {
    run my_function
    [[ "$status" -eq 0 ]]
    echo "$output" | jq . >/dev/null 2>&1
    [[ $? -eq 0 ]]
}
```
