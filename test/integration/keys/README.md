# Test-only host keys

These private keys identify loopback-only Docker fixtures. Never use them for
any deployed host. Their stability makes TOFU and changed-key tests repeatable;
the user authentication key is generated afresh by `run.sh`.
