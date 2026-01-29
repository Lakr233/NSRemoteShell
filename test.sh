#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SSHD_BIN="/usr/sbin/sshd"
SSH_KEYGEN_BIN="/usr/bin/ssh-keygen"

if [[ ! -x "$SSHD_BIN" ]]; then
	echo "error: sshd not found or not executable at $SSHD_BIN" >&2
	exit 1
fi

if [[ ! -x "$SSH_KEYGEN_BIN" ]]; then
	echo "error: ssh-keygen not found or not executable at $SSH_KEYGEN_BIN" >&2
	exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nsremoteshell-sshd.XXXXXX")"
cleanup() {
	if [[ -n "${SSHD_PID:-}" ]] && kill -0 "$SSHD_PID" 2>/dev/null; then
		kill "$SSHD_PID" 2>/dev/null || true
		sleep 0.2 || true
		kill -9 "$SSHD_PID" 2>/dev/null || true
	fi
	rm -rf "$TMP_DIR" || true
}
trap cleanup EXIT

USERNAME="$(id -un)"

# Pick an ephemeral port by asking python to bind :0.
PORT=""
if command -v python3 >/dev/null 2>&1; then
	PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
)"
elif command -v python >/dev/null 2>&1; then
	PORT="$(python - <<'PY'
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()
PY
)"
else
	echo "error: python3/python is required to select an ephemeral port" >&2
	exit 1
fi

HOST_KEY="$TMP_DIR/ssh_host_ed25519_key"
CLIENT_KEY="$TMP_DIR/client_ed25519_key"
AUTHORIZED_KEYS="$TMP_DIR/authorized_keys"
SSHD_CONFIG="$TMP_DIR/sshd_config"
PID_FILE="$TMP_DIR/sshd.pid"
LOG_FILE="$TMP_DIR/sshd.stderr.log"

"$SSH_KEYGEN_BIN" -t ed25519 -f "$HOST_KEY" -N "" >/dev/null
"$SSH_KEYGEN_BIN" -t ed25519 -f "$CLIENT_KEY" -N "" >/dev/null
cat "${CLIENT_KEY}.pub" > "$AUTHORIZED_KEYS"

# Notes:
# - StrictModes no: avoids permission edge cases in temporary dirs
# - internal-sftp: avoids external subsystem dependency
cat > "$SSHD_CONFIG" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $HOST_KEY
PidFile $PID_FILE
AuthorizedKeysFile $AUTHORIZED_KEYS
AllowUsers $USERNAME
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM no
PermitRootLogin no
PermitEmptyPasswords no
StrictModes no
UseDNS no
LogLevel VERBOSE
Subsystem sftp internal-sftp
EOF

"$SSHD_BIN" -D -e -f "$SSHD_CONFIG" 2>"$LOG_FILE" &
SSHD_PID=$!

# Wait until it listens.
DEADLINE=$((SECONDS + 8))
while (( SECONDS < DEADLINE )); do
	if ! kill -0 "$SSHD_PID" 2>/dev/null; then
		echo "error: sshd exited early" >&2
		echo "---- sshd stderr ----" >&2
		cat "$LOG_FILE" >&2 || true
		exit 1
	fi

	if command -v nc >/dev/null 2>&1; then
		if nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
			break
		fi
	else
		if (echo >"/dev/tcp/127.0.0.1/$PORT") >/dev/null 2>&1; then
			break
		fi
	fi

	sleep 0.1
done

if (( SECONDS >= DEADLINE )); then
	echo "error: timed out waiting for sshd to listen on 127.0.0.1:$PORT" >&2
	echo "---- sshd stderr ----" >&2
	cat "$LOG_FILE" >&2 || true
	exit 1
fi

echo "sshd started: 127.0.0.1:$PORT user=$USERNAME pid=$SSHD_PID"

export NSREMOTE_SSH_HOST="127.0.0.1"
export NSREMOTE_SSH_PORT="$PORT"
export NSREMOTE_SSH_USERNAME="$USERNAME"
export NSREMOTE_SSH_TIMEOUT="8"
export NSREMOTE_SSH_PRIVATE_KEY="$CLIENT_KEY"
export NSREMOTE_SSH_PUBLIC_KEY="${CLIENT_KEY}.pub"

cd "$ROOT_DIR"
exec swift test
