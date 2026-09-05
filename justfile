# gitsite — the generic build container

# Run the runner's test suite
test:
    bash tests/run.sh

# Static analysis of the shell sources
lint:
    shellcheck runner.sh tests/run.sh

# Everything that must be green before pushing
check: lint test
