# Next Steps: Comprehensive Quality Gate

**Status:** Library is production-ready and deployed to api-tests
**Date:** 2026-03-13
**Current Version:** v1.0.0 (with cross-subscription APIM support)

## What's Done (Option A - Quick Fix & Ship)

✅ Azure provider (Key Vault, APIM subscription keys, APIM named values)
✅ 3 output generators (Postman JSON, Bruno .bru, dotenv)
✅ YAML manifest parser (python3)
✅ Main CLI with 6 commands (validate, plan, fetch, generate, sync, status)
✅ Installer with dependency check
✅ README documentation
✅ Example manifest for TD project
✅ **BONUS:** Per-secret Azure subscription override for cross-subscription APIM
✅ Successfully synced SIT and UAT environments with zero failures

## Option B: Comprehensive Quality Gate

### Goal
Run full test suite, validate all code paths, test error handling, and establish CI/CD for ongoing quality.

### Tasks

#### 1. Run All Test Suites
```bash
cd ~/repos/secrets-bridge
for test in tests/test_*.sh; do
    echo "=== Running $test ==="
    bash "$test" || echo "FAILED: $test"
done
```

**Expected:** All tests pass (manifest parser, Azure provider mocks, output generators).

#### 2. Test All CLI Commands

**validate:**
```bash
cd ~/repos/td/api-tests
secrets-bridge validate
# Should: PASS with 3 environments, provider check OK
```

**plan:**
```bash
secrets-bridge plan sit
secrets-bridge plan uat
secrets-bridge plan pre
# Should: Show all secrets to be fetched, no errors
```

**status:**
```bash
secrets-bridge status sit
secrets-bridge status uat
# Should: Show which secrets are cached vs missing
```

**fetch (idempotent test):**
```bash
secrets-bridge fetch sit
secrets-bridge fetch sit  # Run again
# Should: Both succeed, second run should be faster (cached in keychain)
```

**generate (regeneration test):**
```bash
secrets-bridge generate sit
secrets-bridge generate sit
# Should: Both succeed, files should be identical
```

**sync (end-to-end):**
```bash
secrets-bridge sync sit
# Should: Fetch + generate in one step, all 3 output files created
```

#### 3. Error Handling Validation

**Missing Azure login:**
```bash
az logout
secrets-bridge fetch sit
# Should: Fail with clear error message about az login
az login  # Log back in
```

**Invalid manifest:**
```bash
# Create test manifest with syntax error
echo "invalid: [yaml" > /tmp/bad-manifest.yml
SECRETS_MANIFEST=/tmp/bad-manifest.yml secrets-bridge validate
# Should: Fail with parse error
```

**Missing Key Vault:**
```bash
# Edit manifest to reference non-existent vault
secrets-bridge fetch sit
# Should: Fail with clear error on specific secret
```

**Permission denied:**
```bash
# Test with account lacking RBAC on Key Vault/APIM
# Should: Fail with clear permission error
```

#### 4. Output Format Validation

**Postman JSON:**
```bash
# Validate against Postman schema
jq . postman/environments/SIT.postman_environment.json > /dev/null
# Check required fields
jq '.id, .name, .values' postman/environments/SIT.postman_environment.json
# Import into Postman GUI and verify
```

**Bruno .bru:**
```bash
# Validate syntax
grep -q '^vars {' bruno/NZTD/environments/NZTD-SIT.bru
# Run bruno CLI with the environment
cd bruno/NZTD
bru run --env NZTD-SIT "Health/healthmonitor.bru"
# Should: Pass using the generated environment
```

**dotenv:**
```bash
# Source and verify
set -a
source .env.sit
set +a
echo $client_secret_td  # Should not be empty
echo $baseurl          # Should match manifest
```

#### 5. Cross-Subscription APIM Testing

**Verify subscription switching works:**
```bash
# Check current subscription before fetch
az account show --query name
# Fetch secrets that use different subscriptions
secrets-bridge fetch sit -v  # Verbose mode to see subscription changes
# Verify final subscription matches starting subscription (restore)
```

**Test all APIM subscription patterns:**
- Default subscription (from environment level)
- Per-secret override (azure_subscription field)
- Primary vs secondary keys

#### 6. Manifest Coverage Testing

**Test all source types:**
```bash
# Create test manifest with all source types
cat > /tmp/test-manifest.yml <<'EOF'
project: test
default_provider: azure
environments:
  test:
    azure:
      subscription: INZ_TDS_SIT
    secrets:
      - name: kv-test
        source: keyvault
        vault: inz-tds-ae-td-kv-sit
        secret: some-secret
      - name: apim-sub-test
        source: apim-subscription
        resource_group: test-rg
        service: test-apim
        subscription_id: test-sub
        key: primary
      - name: apim-nv-test
        source: apim-named-value
        resource_group: test-rg
        service: test-apim
        named_value_id: test-nv
      - name: static-test
        value: static-value
        secret: false
    outputs:
      - format: dotenv
        file: /tmp/test.env
EOF
SECRETS_MANIFEST=/tmp/test-manifest.yml secrets-bridge plan test
# Should: Show all 4 source types correctly parsed
```

#### 7. Integration Testing with api-tests

**Full workflow test:**
```bash
cd ~/repos/td/api-tests
# Clean state
rm -f postman/environments/{SIT,UAT}.postman_environment.json
rm -f bruno/NZTD/environments/NZTD-{SIT,UAT}.bru
rm -f .env.{sit,uat}
# Sync both environments
secrets-bridge sync sit
secrets-bridge sync uat
# Run tests with generated environments
just test NZTD sit
just test NZTD uat
# Should: Tests pass using the fetched secrets
```

**Verify no secrets leaked to git:**
```bash
git status --short
# Should: Show untracked generated files, but they should be gitignored
git check-ignore postman/environments/SIT.postman_environment.json
# Should: Return 0 (file is ignored)
```

#### 8. Performance Testing

**Large manifest:**
```bash
# Test with 50+ secrets
# Measure fetch time
time secrets-bridge fetch sit
# Should: Complete in < 30s for 50 secrets
```

**Concurrent access:**
```bash
# Test multiple environments in parallel
(secrets-bridge sync sit &)
(secrets-bridge sync uat &)
wait
# Should: Both succeed without race conditions
```

#### 9. Documentation Testing

**README examples:**
```bash
# Run every command example in the README
# Verify output matches documented behavior
```

**Manifest reference:**
```bash
# Verify every field in .secrets-manifest.yml is documented
# Check for undocumented fields
```

#### 10. CI/CD Setup

**GitHub Actions workflow:**
```yaml
name: Test
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get install -y python3
      - run: bash tests/test_manifest_parser.sh
      - run: bash tests/test_azure_provider.sh  # Uses mocked az
      - run: bash tests/test_postman_output.sh
      - run: bash tests/test_bruno_output.sh
      - run: bash tests/test_dotenv_output.sh
```

#### 11. Security Audit

**Secrets handling:**
- Verify no secrets logged to stdout/stderr
- Check temp file usage (should be none)
- Verify keychain permissions (user-scoped only)
- Test secret deletion leaves no traces

**Azure token security:**
- Verify no Azure tokens stored locally
- Check az CLI credential caching is respected
- Test token expiration handling

#### 12. Provider Extension Testing

**Document provider interface:**
```bash
# Create example provider (e.g., AWS)
# providers/aws.sh with documented function signatures
# Verify new provider can be added without modifying core CLI
```

#### 13. Version Tagging

Once all tests pass:
```bash
cd ~/repos/secrets-bridge
git tag -a v1.0.1 -m "v1.0.1: Full test suite validated + cross-subscription APIM support confirmed"
git push origin main --tags
```

### Success Criteria

- [ ] All test suites pass
- [ ] All CLI commands tested with happy path and error cases
- [ ] All 3 output formats validated against their respective tools
- [ ] Cross-subscription APIM switching works correctly
- [ ] Integration tests with api-tests pass for SIT and UAT
- [ ] Performance benchmarks met (50 secrets in < 30s)
- [ ] Security audit shows no plaintext leakage or credential exposure
- [ ] CI passes on GitHub Actions
- [ ] Documentation examples all work as written

### Estimated Time

**2-3 hours** for comprehensive testing and validation.

### Priority

**Medium** - The library is already production-ready for the TD project (SIT + UAT confirmed working). Comprehensive testing ensures long-term maintainability and catches edge cases.

---

## Related

- **secrets NEXT_STEPS.md** - Comprehensive testing for the base secrets library
- **api-tests** - Real-world integration and usage
- **Azure RBAC** - Document required permissions for all Azure operations
