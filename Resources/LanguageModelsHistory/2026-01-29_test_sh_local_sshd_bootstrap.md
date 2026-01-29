# 2026-01-29 - test.sh local sshd bootstrap

## Summary
- Reverted Swift test helper changes; SSH tests remain environment-driven.
- Added a repository-root `test.sh` script that:
  - Creates a temporary OpenSSH `sshd` config + host/client keys
  - Starts `sshd` on an ephemeral high port bound to `127.0.0.1`
  - Exports `NSREMOTE_SSH_*` env vars for the test suite
  - Runs `swift test` and cleans up the temporary daemon/files

## Notes
- Script fails fast if `sshd` or `ssh-keygen` are missing, or if `sshd` does not start listening within the timeout.
