# Nimble Storage Plugin Tests

This directory contains tests for the PVE Nimble Storage Plugin.

## Test Structure

- `unit/` - Unit tests for individual functions
- `integration/` - Integration tests requiring actual Nimble array (optional)
- `fixtures/` - Test data and mock responses (optional)
- `scripts/` - Helper scripts for testing (optional)

## Running Tests

Run from the **repository root** (parent of `tests/`). The plugin path must be in `@INC` (e.g. `perl -I.` or use the script below).

```bash
# Run all unit tests (recommended)
./tests/run_tests.sh

# Or run tests manually from repo root
perl -I. tests/unit/test_command_validation.t
perl -I. tests/unit/test_retry_logic.t
perl -I. tests/unit/test_token_cache.t
```

## Test Coverage

- Token caching and expiration
- Command path validation
- API request/response handling (retry logic)
- Error handling
