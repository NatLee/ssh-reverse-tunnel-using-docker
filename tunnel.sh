#!/usr/bin/env bash
# tunnel.sh: set up, run and remove both ends of the SSH reverse tunnel.
#
#   outside server:  ./tunnel.sh install server
#   inside machine:  ./tunnel.sh install client
#   either end:      ./tunnel.sh uninstall
#
# ./tunnel.sh help lists every command. Needs bash 3.2+, Docker with Compose
# 2.24+ and the OpenSSH client tools (ssh, ssh-keygen).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"

# ------------------------------------------------------------------ settings

ENV_FILE=.env
ENV_EXAMPLE=.env.example
REPO_URL=https://github.com/NatLee/ssh-reverse-tunnel-using-docker

# Key files. Their folders are mounted by the compose files: keep both in sync.
TUNNEL_KEY=src/root_ssh_key/id_rsa               # client: autossh logs in to the outside server with it
TUNNEL_KNOWN_HOSTS=src/root_ssh_key/known_hosts  # client: the outside server's host key
LOGIN_KEY=src/user_ssh_key/id_rsa                # client: you log in to the inside machine with it
LOGIN_AUTHORIZED_KEYS=src/user_ssh_key/authorized_keys
SERVER_AUTHORIZED_KEYS=src/server-config/root_ssh_key/authorized_keys
CUSTOM_SCRIPT_DIRS="src/custom_scripts/custom-cont-init.d src/custom_scripts/custom-services.d"
USER_KEY_TYPE=rsa
RSA_BITS=4096
HOST_KEY_TYPES="rsa ecdsa ed25519"  # OpenSSH 10 dropped DSA
CONTAINER_SSH_PORT=2222             # where the image's sshd listens inside the container
WAIT_SECONDS=120                    # how long install waits for sshd and for the tunnel

compose_file() {
    case $1 in
        client) echo docker-compose.yml ;;
        server) echo docker-compose.server.yml ;;
    esac
}

host_key_dir() {
    case $1 in
        client) echo src/ssh_host_keys ;;
        server) echo src/server-config/ssh_host_keys ;;
    esac
}

host_key_comment() {
    case $1 in
        client) echo root@openssh-server ;;
        server) echo root@openssh-outside-server ;;
    esac
}

key_dirs() {
    case $1 in
        client) echo "src/root_ssh_key src/user_ssh_key $(host_key_dir client)" ;;
        server) echo "src/server-config/root_ssh_key $(host_key_dir server)" ;;
    esac
}

log_dir() { echo "logs/$1"; }

# The settings install asks for: KEY --flag question. Every other variable a
# compose file uses is filled in without asking (see value_for).
questions() {
    case $1 in
        client)
            cat <<'EOF'
REVERSE_SERVER_HOST --server-host Address of the outside server (domain or IP)
REVERSE_SERVER_SSH_PORT --server-port SSH port of the outside server
REVERSE_SERVER_USER_NAME --server-user User name on the outside server
REVERSE_TUNNEL_SSH_PORT --tunnel-port Tunnel port on the outside server
USER_NAME --user User name for logging in to this machine through the tunnel
EOF
            ;;
        server)
            cat <<'EOF'
REVERSE_SERVER_SSH_PORT --server-port SSH port of this server (the inside machines connect to it)
REVERSE_TUNNEL_SSH_PORT --tunnel-port Tunnel port (you connect to it to reach the inside machine)
USER_NAME --user User name the inside machines log in as
EOF
            ;;
    esac
}

usage() {
    cat <<'EOF'
Usage: ./tunnel.sh <command> [client|server] [options]

Set up and remove
  install server        On the outside server: settings, host keys, start.
  install client        On the inside machine: settings, keys, put the tunnel key
                        on the outside server, test, start.
  uninstall [ROLE]      Stop and remove the containers and the network. Asks
                        whether to delete more, or use:
                          --images  the openssh-server image
                          --keys    the keys made by keygen/install
                          --env     the .env file
                          --logs    the logs/ folder
                          --all     all of the above
                          --yes     no questions (needed to delete files
                                    when there is no terminal)

Day to day (ROLE defaults to the one install saved in .env)
  start [ROLE]          Start in the background (--foreground: stay attached).
  stop [ROLE]           Stop the container.
  status [ROLE]         Show the containers and how to connect.
  logs [ROLE] [ARGS]    docker compose logs, e.g. ./tunnel.sh logs -f
  keygen [ROLE]         Make new keys (asks first when keys exist; --yes skips).
  pubkey                Print the tunnel public key of this inside machine.
  authorize KEY|FILE|-  On the outside server: accept an inside machine's key, for
                        its tunnel port only (--tunnel-port PORT, default from .env).
  copy-key              Put the tunnel key on a plain SSH server with ssh-copy-id.
  connect-outside       Check that the outside server accepts the tunnel key.
  shell                 Open a shell in the inside container.

Options for install (or set the same name in the environment or .env)
  --server-host HOST    REVERSE_SERVER_HOST       (client)
  --server-port PORT    REVERSE_SERVER_SSH_PORT   (default 22222)
  --server-user NAME    REVERSE_SERVER_USER_NAME  (client, default user)
  --tunnel-port PORT    REVERSE_TUNNEL_SSH_PORT   (default 22224)
  --user NAME           USER_NAME                 (default user)
  --authorize-key KEY   server: accept this key or key file (repeatable)
  --copy-key            client: run ssh-copy-id instead of asking
  -y, --yes             no questions: use options, environment, .env, defaults

Examples
  ./tunnel.sh install server
  ./tunnel.sh install client --server-host example.com --yes
  ./tunnel.sh uninstall --all
EOF
}

# -------------------------------------------------------------------- output

if [ -t 1 ]; then
    BOLD=$'\033[1m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RED=$'\033[31m' PLAIN=$'\033[0m'
else
    BOLD='' GREEN='' YELLOW='' RED='' PLAIN=''
fi

step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$PLAIN"; }
ok() { printf '  %sok%s   %s\n' "$GREEN" "$PLAIN" "$*"; }
info() { printf '       %s\n' "$*"; }
warn() { printf '  %swarning:%s %s\n' "$YELLOW" "$PLAIN" "$*" >&2; }
die() {
    printf '%serror:%s %s\n' "$RED" "$PLAIN" "$*" >&2
    exit 1
}

# --------------------------------------------------------------- questions

ASSUME_YES=0

interactive() { [ "$ASSUME_YES" = 0 ] && [ -t 0 ]; }

# ask VAR "question" "default": the answer, or the default on an empty line.
ask() {
    local reply=''
    printf '  %s%s: ' "$2" "${3:+ [$3]}" >&2
    IFS= read -r reply || true
    printf -v "$1" '%s' "${reply:-$3}"
}

# confirm "question": true only for y or yes.
confirm() {
    local reply=''
    printf '  %s [y/N]: ' "$1" >&2
    IFS= read -r reply || true
    case $reply in
        [yY] | [yY][eE][sS]) return 0 ;;
    esac
    return 1
}

# -------------------------------------------------------------- arguments

ROLE=''
FOREGROUND=0
COPY_KEY=0
AUTHORIZE_KEYS=''
REMOVE_IMAGES=0
REMOVE_KEYS=0
REMOVE_ENV=0
REMOVE_LOGS=0

parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --*=*)
                set -- "${1%%=*}" "${1#*=}" "${@:2}"
                continue
                ;;
            client | server) ROLE=$1 ;;
            -y | --yes) ASSUME_YES=1 ;;
            --foreground) FOREGROUND=1 ;;
            --copy-key) COPY_KEY=1 ;;
            --images) REMOVE_IMAGES=1 ;;
            --keys) REMOVE_KEYS=1 ;;
            --env) REMOVE_ENV=1 ;;
            --logs) REMOVE_LOGS=1 ;;
            --all) REMOVE_IMAGES=1 REMOVE_KEYS=1 REMOVE_ENV=1 REMOVE_LOGS=1 ;;
            -h | --help)
                usage
                exit 0
                ;;
            --authorize-key)
                [ $# -ge 2 ] || die "$1 needs a key or a key file"
                AUTHORIZE_KEYS+="$2"$'\n'
                shift
                ;;
            --*)
                [ $# -ge 2 ] || die "$1 needs a value"
                set_option "$1" "$2"
                shift
                ;;
            *) die "unexpected argument: $1 (see ./tunnel.sh help)" ;;
        esac
        shift
    done
}

# set_option --flag VALUE: remember the value for the setting behind --flag.
set_option() {
    local key
    key=$({ questions client; questions server; } | awk -v f="$1" '$2 == f && !n++ { print $1 }')
    [ -n "$key" ] || die "unknown option: $1 (see ./tunnel.sh help)"
    printf -v "OPT_$key" '%s' "$2"
}

# pick_role [ROLE]: the role given, or the one install saved in .env.
pick_role() {
    local role=${1:-}
    if [ -z "$role" ]; then
        role=$(env_get TUNNEL_ROLE)
    fi
    case $role in
        client | server) echo "$role" ;;
        '') die "say which end this is: ./tunnel.sh $COMMAND client (inside machine) or server (outside server)" ;;
        *) die "TUNNEL_ROLE in .env must be client or server, not '$role'" ;;
    esac
}

# roles_or_all [ROLE]: the role given or saved in .env, otherwise both.
roles_or_all() {
    local role=${1:-}
    if [ -z "$role" ]; then
        role=$(env_get TUNNEL_ROLE)
    fi
    echo "${role:-client server}"
}

# ---------------------------------------------------------------- the .env

# env_get KEY [FILE]: the value of KEY (last line wins, quotes removed).
env_get() {
    local file=${2:-$ENV_FILE} value
    if [ ! -f "$file" ]; then
        return 0
    fi
    value=$(K=$1 awk 'index($0, ENVIRON["K"] "=") == 1 { v = substr($0, length(ENVIRON["K"]) + 2) } END { print v }' "$file")
    value=${value%\"} value=${value#\"}
    value=${value%\'} value=${value#\'}
    echo "$value"
}

# env_set KEY VALUE: replace the KEY line in .env, or add it.
env_set() {
    local tmp
    tmp=$(mktemp "$ENV_FILE.XXXXXX")
    K=$1 V=$2 awk '
        index($0, ENVIRON["K"] "=") == 1 { if (!done) print ENVIRON["K"] "=" ENVIRON["V"]; done = 1; next }
        { print }
        END { if (!done) print ENVIRON["K"] "=" ENVIRON["V"] }' "$ENV_FILE" >"$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$ENV_FILE"
}

# role_vars ROLE: every variable the role's compose file uses, in .env.example order.
role_vars() {
    local used
    used=$("${COMPOSE[@]}" -f "$(compose_file "$1")" config --variables | awk 'NR > 1 { print $1 }')
    { sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' "$ENV_EXAMPLE"; echo "$used"; } |
        awk -v used=" $(tr '\n' ' ' <<<"$used") " 'index(used, " " $0 " ") && !seen[$0]++'
}

is_question() { questions "$1" | awk -v k="$2" '$1 == k { found = 1 } END { exit !found }'; }

# derived_value KEY: a default worked out on this machine (empty when there is none).
derived_value() {
    local id
    case $1 in
        PUID | PGID)
            # Your own uid/gid, also under sudo. Never 0: the container user must
            # not be root (sshd refuses root logins), so root keeps .env.example's value.
            if [ "$1" = PUID ]; then id=${SUDO_UID:-$(id -u)}; else id=${SUDO_GID:-$(id -g)}; fi
            if [ "$id" != 0 ]; then echo "$id"; fi
            ;;
        USER_PASSWORD) od -An -tx1 -N16 /dev/urandom | tr -d ' \n' ;;
    esac
}

# value_for KEY [overrides]: what a setting should be. With "overrides" (install),
# an option or an environment variable wins over .env.
value_for() {
    local key=$1 opt="OPT_$1" value=''
    if [ "${2:-}" = overrides ]; then
        value=${!opt:-}
        if [ -z "$value" ]; then value=$(printenv "$key" || true); fi
    fi
    if [ -z "$value" ]; then value=$(env_get "$key"); fi
    if [ -z "$value" ]; then value=$(derived_value "$key"); fi
    if [ -z "$value" ]; then value=$(env_get "$key" "$ENV_EXAMPLE"); fi
    echo "$value"
}

# check_value KEY VALUE: prints what is wrong with VALUE and fails, if anything is.
check_value() {
    case $1 in
        *_PORT)
            if [[ $2 =~ ^[0-9]{1,5}$ ]] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ]; then return 0; fi
            echo "$1 must be a port number from 1 to 65535, not '$2'"
            ;;
        *USER_NAME)
            if [[ $2 =~ ^[a-z_][a-z0-9_-]*$ ]]; then return 0; fi
            echo "$1 must be a lower-case user name (letters, digits, _ or -), not '$2'"
            ;;
        *_HOST)
            if [[ $2 =~ ^[A-Za-z0-9._:-]+$ ]]; then return 0; fi
            echo "$1 must be a domain name or an IP address, not '$2'"
            ;;
        *)
            if [ -n "$2" ]; then return 0; fi
            echo "$1 is empty"
            ;;
    esac
    return 1
}

# configure ROLE: ask for (or take) every setting the role needs, then write .env.
configure() {
    local role=$1 key flag question value problem lines=''
    while read -r key flag question <&3; do
        value=$(value_for "$key" overrides)
        if interactive; then
            while :; do
                ask value "$question" "$value"
                problem=$(check_value "$key" "$value") && break
                warn "$problem"
            done
        elif ! problem=$(check_value "$key" "$value"); then
            die "$problem. Pass $flag, or set $key in the environment or in .env."
        fi
        lines+="$key=$value"$'\n'
    done 3< <(questions "$role")

    for key in $(role_vars "$role"); do
        if is_question "$role" "$key"; then continue; fi
        value=$(value_for "$key" overrides)
        problem=$(check_value "$key" "$value") || die "$problem (set $key in .env)"
        lines+="$key=$value"$'\n'
    done

    if [ ! -f "$ENV_FILE" ]; then cp "$ENV_EXAMPLE" "$ENV_FILE"; fi
    chmod 600 "$ENV_FILE"
    while IFS='=' read -r key value; do
        if [ -n "$key" ]; then env_set "$key" "$value"; fi
    done <<<"TUNNEL_ROLE=$role"$'\n'"$lines"
    show_settings "$role"
}

# ensure_env ROLE: fill in settings that are still missing (e.g. a .env from an
# older version), without asking. Fails when one has no default.
ensure_env() {
    local role=$1 key value problem
    [ -f "$ENV_FILE" ] || die "there is no .env yet: run ./tunnel.sh install $role"
    for key in $(role_vars "$role"); do
        if [ -n "$(env_get "$key")" ]; then continue; fi
        value=$(value_for "$key")
        problem=$(check_value "$key" "$value") || die "$problem: run ./tunnel.sh install $role, or set $key in .env"
        env_set "$key" "$value"
        info "added $key to .env"
    done
}

show_settings() {
    local key value
    ok "settings saved in .env"
    for key in $(role_vars "$1"); do
        value=$(env_get "$key")
        if [ "$key" = USER_PASSWORD ]; then value='(random, see .env)'; fi
        info "$(printf '%-26s %s' "$key" "$value")"
    done
}

# -------------------------------------------------------------------- docker

COMPOSE=()

need_docker() {
    local help
    command -v docker >/dev/null 2>&1 ||
        die "Docker is not installed. See https://docs.docker.com/engine/install/ (Windows: Docker Desktop with WSL 2)."
    docker info >/dev/null 2>&1 ||
        die "cannot reach Docker. Start it, or add yourself to the docker group: sudo usermod -aG docker \$USER (then log in again)."
    if docker compose version >/dev/null 2>&1; then
        COMPOSE=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE=(docker-compose)
    else
        die "Docker Compose is missing. Install the docker compose plugin (Compose v2)."
    fi
    # role_vars needs "config --variables" (Compose 2.24+).
    help=$("${COMPOSE[@]}" config --help 2>/dev/null || true)
    [[ $help == *--variables* ]] ||
        die "Docker Compose is too old: this needs 2.24 or newer ($("${COMPOSE[@]}" version --short 2>/dev/null || echo unknown) found)."
}

need_ssh() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 ||
            die "$tool is missing. Install the OpenSSH client (Debian/Ubuntu: sudo apt install openssh-client)."
    done
}

project_name() { sed -n 's/^name: *//p' "$(compose_file "$1")"; }
container_name() { sed -n 's/^ *container_name: *//p' "$(compose_file "$1")"; }

# compose_cmd ROLE ARGS: docker compose with the role's file (reads .env).
compose_cmd() { "${COMPOSE[@]}" -f "$(compose_file "$1")" "${@:2}"; }

# project_cmd ROLE ARGS: docker compose by project name only, so it works even
# when .env is gone or incomplete (down, stop, logs).
project_cmd() {
    local project
    project=$(project_name "$1")
    (cd / && "${COMPOSE[@]}" -p "$project" "${@:2}")
}

project_containers() { docker ps -a --filter "label=com.docker.compose.project=$(project_name "$1")" --format '{{.Names}}'; }
project_networks() { docker network ls --filter "label=com.docker.compose.project=$(project_name "$1")" --format '{{.Name}}'; }

# Compatibility (2026-11): before tunnel.sh, the compose project was named after
# the folder, and the container kept the same fixed container_name. Compose
# cannot create our container while that one exists, so this removes it (and
# its network, if nothing else uses it). It can go once no setup from before
# 2026-11 is left.
old_container() {
    local name project
    name=$(container_name "$1")
    project=$(docker container inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$name" 2>/dev/null || true)
    if [ -n "$project" ] && [ "$project" != "$(project_name "$1")" ]; then echo "$name $project"; fi
}

retire_old_container() {
    local name project
    read -r name project <<<"$(old_container "$1")"
    if [ -z "${name:-}" ]; then return 0; fi
    info "removing $name, left over from before tunnel.sh (project $project)"
    docker rm -f "$name" >/dev/null
    docker network rm "${project}_default" >/dev/null 2>&1 || true
}

# wait_ready ROLE: until sshd answers inside the container.
wait_ready() {
    local name deadline=$((SECONDS + WAIT_SECONDS))
    name=$(container_name "$1")
    while [ $SECONDS -lt $deadline ]; do
        if docker exec "$name" nc -z localhost "$CONTAINER_SSH_PORT" >/dev/null 2>&1; then
            ok "sshd is up in $name"
            return 0
        fi
        sleep 2
    done
    warn "sshd in $name did not answer within ${WAIT_SECONDS}s. See ./tunnel.sh logs $1"
    return 1
}

# --------------------------------------------------------------------- keys

# make_key FILE TYPE COMMENT: a new key pair without a passphrase.
make_key() {
    rm -f "$1" "$1.pub"
    if [ "$2" = rsa ]; then
        ssh-keygen -q -t rsa -b "$RSA_BITS" -N '' -C "$3" -f "$1"
    else
        ssh-keygen -q -t "$2" -N '' -C "$3" -f "$1"
    fi
    chmod 600 "$1"
    chmod 644 "$1.pub"
    ok "made $1"
}

# keep_key FILE TYPE COMMENT: keep a key that is there, make one that is not.
keep_key() {
    if [ -f "$1" ] && [ -f "$1.pub" ]; then
        info "kept $1"
    else
        make_key "$@"
    fi
}

# A public key line is "[options] type data [comment]". The awk snippets below
# find the key by its type (ssh-..., ecdsa-..., sk-...) and work from there.
# shellcheck disable=SC2016 # awk code, expanded by awk
KEY_TYPE_AWK='function key_at() { for (i = 1; i < NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) return i; return 0 }'

# key_id LINE: the key type and data of a public key line (options and comment dropped).
key_id() { awk "$KEY_TYPE_AWK"' { i = key_at(); if (i) print $i, $(i + 1) }' <<<"$1"; }

# key_part LINE: the line without its options: "type data [comment]".
key_part() { awk "$KEY_TYPE_AWK"' { i = key_at(); if (i) print substr($0, index($0, $i " " $(i + 1))) }' <<<"$1"; }

# key_line FILE ID: the line of FILE that holds the key ID (see key_id).
key_line() { ID=$2 awk "$KEY_TYPE_AWK"' { i = key_at(); if (i && $i " " $(i + 1) == ENVIRON["ID"]) { print; exit } }' "$1"; }

# set_key_line FILE ID LINE: replace the line that holds the key ID with LINE.
set_key_line() {
    local tmp
    tmp=$(mktemp "$1.XXXXXX")
    ID=$2 NEW=$3 awk "$KEY_TYPE_AWK"'
        { i = key_at() }
        i && $i " " $(i + 1) == ENVIRON["ID"] { if (!done) print ENVIRON["NEW"]; done = 1; next }
        { print }' "$1" >"$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$1"
}

# fingerprint LINE: what ssh-keygen -l says about a public key line; fails if it is none.
fingerprint() {
    local file
    file=$(mktemp)
    printf '%s\n' "$1" >"$file"
    if ssh-keygen -l -f "$file" 2>/dev/null; then
        rm -f "$file"
    else
        rm -f "$file"
        return 1
    fi
}

# add_keys FILE OPTIONS KEY_OR_FILE...: make FILE accept these public keys,
# each with OPTIONS in front (may be empty). A key that is there already gets
# its line updated when the options differ. "-" reads the keys from stdin.
add_keys() {
    local file=$1 options=$2 source text line id print wanted existing
    shift 2
    touch "$file"
    chmod 600 "$file"
    for source in "$@"; do
        if [ "$source" = - ]; then
            text=$(cat)
        elif [ -f "$source" ]; then
            text=$(cat "$source")
        else
            text=$source
        fi
        while IFS= read -r line; do
            case $line in '' | '#'*) continue ;; esac
            print=$(fingerprint "$line") || die "not an SSH public key: ${line:0:50}..."
            id=$(key_id "$line")
            wanted="${options:+$options }$(key_part "$line")"
            existing=$(key_line "$file" "$id")
            if [ -z "$existing" ]; then
                printf '%s\n' "$wanted" >>"$file"
                ok "accepted $print"
            elif [ "$existing" = "$wanted" ]; then
                info "already accepted: $print"
            else
                set_key_line "$file" "$id" "$wanted"
                ok "updated $print"
            fi
        done <<<"$text"
    done
}

# What a tunnel key may do on the outside server: open its reverse tunnel port
# (ssh -R) and nothing else. restrict turns off everything (forwarding, agent,
# X11, terminal), port-forwarding turns forwarding back on, permitlisten allows
# only the tunnel port, and command answers any request for a shell or command.
# The outside server's sshd settings say the same for every key (see
# src/server-config/sshd_config.d/tunnel.conf), in case a key is added by hand.
NO_SHELL_MESSAGE="This key only opens a reverse tunnel. There is no shell on this server."

# tunnel_key_options PORT: the authorized_keys options for a tunnel key.
tunnel_key_options() { printf 'restrict,port-forwarding,permitlisten="*:%s",command="echo '\''%s'\'' >&2; exit 1"' "$1" "$NO_SHELL_MESSAGE"; }

# restrict_server_keys: give every key on the outside server the tunnel-only
# options. Keys added before 2026-11 (or by hand) have none and get them for
# REVERSE_TUNNEL_SSH_PORT. Lines that start with "restrict," already have
# their limits and stay as they are, so a key keeps its own tunnel port.
restrict_server_keys() {
    local file=$SERVER_AUTHORIZED_KEYS port line
    if [ ! -s "$file" ]; then return 0; fi
    port=$(value_for REVERSE_TUNNEL_SSH_PORT)
    while IFS= read -r line; do
        case $line in '' | '#'* | restrict,*) continue ;; esac
        if [ -z "$(key_id "$line")" ]; then continue; fi
        set_key_line "$file" "$(key_id "$line")" "$(tunnel_key_options "$port") $(key_part "$line")"
        ok "limited to the tunnel on port $port: $(fingerprint "$line" || echo "${line:0:40}...")"
    done <<<"$(cat "$file")"
}

# make_keys ROLE keep|new: every key the role needs. "new" replaces them all,
# like the old keygen.sh / keygen-server.sh.
make_keys() {
    local role=$1 maker=keep_key dir type pub
    if [ "$2" = new ]; then maker=make_key; fi
    for dir in $(key_dirs "$role"); do
        mkdir -p "$dir"
    done
    dir=$(host_key_dir "$role")
    for type in $HOST_KEY_TYPES; do
        $maker "$dir/ssh_host_${type}_key" "$type" "$(host_key_comment "$role")"
    done
    case $role in
        client)
            $maker "$TUNNEL_KEY" "$USER_KEY_TYPE" "reverse-tunnel@${HOSTNAME:-$(uname -n)}"
            $maker "$LOGIN_KEY" "$USER_KEY_TYPE" "inside-login@${HOSTNAME:-$(uname -n)}"
            if [ "$2" = new ]; then : >"$LOGIN_AUTHORIZED_KEYS"; fi
            # Who may log in to the inside container: the login key, plus your own keys.
            add_keys "$LOGIN_AUTHORIZED_KEYS" '' "$LOGIN_KEY.pub"
            for pub in "$HOME"/.ssh/id_*.pub; do
                if [ -f "$pub" ]; then add_keys "$LOGIN_AUTHORIZED_KEYS" '' "$pub"; fi
            done
            ;;
        server)
            if [ "$2" = new ]; then : >"$SERVER_AUTHORIZED_KEYS"; fi
            touch "$SERVER_AUTHORIZED_KEYS"
            chmod 600 "$SERVER_AUTHORIZED_KEYS"
            ;;
    esac
}

# key_files ROLE: every file in the role's key folders (what --keys deletes).
key_files() {
    local dir
    for dir in $(key_dirs "$1"); do
        if [ -d "$dir" ]; then find "$dir" -mindepth 1 -maxdepth 1 ! -name .gitkeep | sort; fi
    done
}

# private_keys ROLE: the private keys the role uses.
private_keys() {
    local type
    for type in $HOST_KEY_TYPES; do
        echo "$(host_key_dir "$1")/ssh_host_${type}_key"
    done
    if [ "$1" = client ]; then echo "$TUNNEL_KEY $LOGIN_KEY"; fi
}

# authorized_keys_file ROLE: who may log in to the role's container.
authorized_keys_file() {
    case $1 in
        client) echo "$LOGIN_AUTHORIZED_KEYS" ;;
        server) echo "$SERVER_AUTHORIZED_KEYS" ;;
    esac
}

check_keys() {
    local missing='' file
    for file in $(private_keys "$1") "$(authorized_keys_file "$1")"; do
        if [ ! -f "$file" ]; then missing+=" $file"; fi
    done
    [ -z "$missing" ] || die "missing key files:$missing. Make them with ./tunnel.sh keygen $1"
}

# fix_modes ROLE: private keys 600, public keys 644, container scripts 755.
fix_modes() {
    local file
    for file in $(private_keys "$1"); do
        if [ -f "$file" ]; then chmod 600 "$file"; fi
        if [ -f "$file.pub" ]; then chmod 644 "$file.pub"; fi
    done
    if [ "$1" = client ]; then
        for file in $CUSTOM_SCRIPT_DIRS; do
            chmod 755 "$file"/*
        done
    fi
}

# ------------------------------------------------------ the outside server

# outside_ssh [SSH OPTIONS] [-- COMMAND]: ssh to the outside server the way autossh does.
outside_ssh() {
    local options=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do
        options+=("$1")
        shift
    done
    if [ $# -gt 0 ]; then shift; fi
    ssh -i "$TUNNEL_KEY" -o IdentitiesOnly=yes -o UserKnownHostsFile="$ROOT/$TUNNEL_KNOWN_HOSTS" \
        -p "$(env_get REVERSE_SERVER_SSH_PORT)" ${options[@]+"${options[@]}"} \
        "$(env_get REVERSE_SERVER_USER_NAME)@$(env_get REVERSE_SERVER_HOST)" "$@"
}

# test_outside: does the outside server accept the tunnel key? The key has no
# shell there, so this asks to run "true" and reads ssh's exit status: 255 means
# it could not log in; 0 means "true" really ran, so the key still has a shell
# (a warning); anything else is the server's refusal to run it, which is right.
# The first time, the server's host key goes into TUNNEL_KNOWN_HOSTS (you
# confirm it on a terminal).
test_outside() {
    local mode=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new) status=0 errors
    if interactive; then mode=(-o StrictHostKeyChecking=ask); fi
    errors=$(mktemp)
    outside_ssh "${mode[@]}" -o PreferredAuthentications=publickey -o ConnectTimeout=10 -T -- true 2>"$errors" || status=$?
    case $status in
        255)
            sed 's/^/       /' "$errors" >&2
            rm -f "$errors"
            return 1
            ;;
        0) warn "the outside server accepts the tunnel key, but lets it run commands. Limit it to the tunnel: see \"A plain SSH server\" in the README." ;;
        *) ok "the outside server accepts the tunnel key, for the tunnel only (no shell)" ;;
    esac
    rm -f "$errors"
}

# server_key_line: the line the outside server's authorized_keys needs for this
# machine's tunnel key (what ./tunnel.sh authorize writes there).
server_key_line() { echo "$(tunnel_key_options "$(env_get REVERSE_TUNNEL_SSH_PORT)") $(cat "$TUNNEL_KEY.pub")"; }

# copy_key: append server_key_line to authorized_keys on a plain SSH server.
# ssh-copy-id -f copies the line as it is, options included.
copy_key() {
    local dir status=0
    dir=$(mktemp -d)
    server_key_line >"$dir/tunnel.pub"
    ssh-copy-id -f -i "$dir/tunnel.pub" -o UserKnownHostsFile="$ROOT/$TUNNEL_KNOWN_HOSTS" \
        -p "$(env_get REVERSE_SERVER_SSH_PORT)" "$(env_get REVERSE_SERVER_USER_NAME)@$(env_get REVERSE_SERVER_HOST)" || status=$?
    rm -rf "$dir"
    return $status
}

# get_key_onto_server: show the tunnel key, put it on the outside server or wait
# until you did, then test the login.
get_key_onto_server() {
    local pub choice=1
    pub=$(cat "$TUNNEL_KEY.pub")
    info "The outside server has to accept this machine's tunnel key:"
    printf '\n    %s\n\n' "$pub"
    info "On the outside server, in its copy of this repo, run:"
    printf '\n    ./tunnel.sh authorize '\''%s'\''\n\n' "$pub"
    info "A plain SSH server: add this line to ~$(env_get REVERSE_SERVER_USER_NAME)/.ssh/authorized_keys there"
    info "(it limits the key to the tunnel port), see \"A plain SSH server\" in the README:"
    printf '\n    %s\n\n' "$(server_key_line)"
    if [ "$COPY_KEY" = 1 ]; then
        choice=2
    elif interactive; then
        info "1) I did that (or will now): test the login   [default]"
        info "2) copy it now with ssh-copy-id (needs your password or another key there)"
        info "3) skip the test"
        ask choice "Choose" 1
    fi
    case $choice in
        2) copy_key || warn "ssh-copy-id did not work" ;;
        3) return 0 ;;
    esac
    while ! test_outside; do
        if interactive && confirm "The outside server did not accept the key. Try again?"; then continue; fi
        warn "the outside server does not accept the tunnel key yet. autossh keeps trying, so the tunnel comes up once it does."
        return 0
    done
}

# ------------------------------------------------------------ the tunnel

# known_hosts_lines HOST PORT: known_hosts lines for the inside container's host keys.
known_hosts_lines() {
    local name=$1 pub
    if [ "$2" != 22 ]; then name="[$1]:$2"; fi
    for pub in "$(host_key_dir client)"/ssh_host_*_key.pub; do
        if [ -f "$pub" ]; then awk -v n="$name" '{ print n, $1, $2 }' "$pub"; fi
    done
}

# check_tunnel: log in to the inside container from here, through the outside
# server, the way you will from your computer.
check_tunnel() {
    local host port user known deadline=$((SECONDS + WAIT_SECONDS))
    host=$(env_get REVERSE_SERVER_HOST) port=$(env_get REVERSE_TUNNEL_SSH_PORT) user=$(env_get USER_NAME)
    known=$(mktemp)
    known_hosts_lines "$host" "$port" >"$known"
    while [ $SECONDS -lt $deadline ]; do
        if ssh -q -i "$LOGIN_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
            -o UserKnownHostsFile="$known" -o ConnectTimeout=5 -p "$port" "$user@$host" true 2>/dev/null; then
            rm -f "$known"
            ok "the tunnel works: $host:$port leads to this machine"
            return 0
        fi
        sleep 3
    done
    rm -f "$known"
    warn "could not log in through $host:$port within ${WAIT_SECONDS}s."
    info "Is the key accepted on the outside server? Is port $port open in its firewall? See ./tunnel.sh logs"
    return 1
}

print_connect_help() {
    local host port user
    host=$(env_get REVERSE_SERVER_HOST) port=$(env_get REVERSE_TUNNEL_SSH_PORT) user=$(env_get USER_NAME)
    cat <<EOF

  From your computer, through the outside server:

      ssh -p $port -i <copy of $LOGIN_KEY> $user@$host

  Copy $ROOT/$LOGIN_KEY to your computer and keep it private (chmod 600).
  Or put this in ~/.ssh/config on your computer and run "ssh inside-tunnel":

      Host inside-tunnel
          HostName $host
          Port $port
          User $user
          IdentityFile ~/.ssh/inside-tunnel_id_rsa

  So that your computer can check it really reached this machine, add these
  lines to its ~/.ssh/known_hosts:

$(known_hosts_lines "$host" "$port" | sed 's/^/      /')
EOF
}

print_server_help() {
    local ssh_port tunnel_port user pub accepted
    ssh_port=$(env_get REVERSE_SERVER_SSH_PORT) tunnel_port=$(env_get REVERSE_TUNNEL_SSH_PORT) user=$(env_get USER_NAME)
    accepted=$(grep -c . "$SERVER_AUTHORIZED_KEYS" || true)
    info "Open these ports in the firewall: $ssh_port (inside machines connect) and $tunnel_port (you connect)."
    info "Tunnel keys accepted: $accepted, each only for its tunnel port. Add one with ./tunnel.sh authorize '<key>'."
    info "The inside machine sees one of these host keys the first time:"
    for pub in "$(host_key_dir server)"/ssh_host_*_key.pub; do
        info "  $(ssh-keygen -l -f "$pub")"
    done
    info "Next, on the inside machine (in a copy of $REPO_URL):"
    printf '\n    ./tunnel.sh install client --server-host <address of this server> --server-port %s --server-user %s --tunnel-port %s\n' \
        "$ssh_port" "$user" "$tunnel_port"
}

# ----------------------------------------------------------------- commands

cmd_install() {
    parse_args "$@"
    local role pasted='' options
    role=$(pick_role "$ROLE")
    need_docker
    if [ "$role" = client ]; then need_ssh ssh ssh-keygen; else need_ssh ssh-keygen; fi
    ok "Docker $(docker version --format '{{.Server.Version}}'), Compose $("${COMPOSE[@]}" version --short)"

    step "Settings"
    configure "$role"

    step "Keys"
    make_keys "$role" keep

    if [ "$role" = client ]; then
        step "Put the tunnel key on the outside server"
        get_key_onto_server
    else
        step "Inside machines this server accepts (tunnel port $(env_get REVERSE_TUNNEL_SSH_PORT) only)"
        options=$(tunnel_key_options "$(env_get REVERSE_TUNNEL_SSH_PORT)")
        while IFS= read -r pasted; do
            if [ -n "$pasted" ]; then add_keys "$SERVER_AUTHORIZED_KEYS" "$options" "$pasted"; fi
        done <<<"$AUTHORIZE_KEYS"
        if interactive && [ -z "$AUTHORIZE_KEYS" ]; then
            ask pasted "Paste an inside machine's tunnel key (./tunnel.sh pubkey there), or press Enter to add it later" ''
            if [ -n "$pasted" ]; then add_keys "$SERVER_AUTHORIZED_KEYS" "$options" "$pasted"; fi
        fi
    fi

    step "Start"
    start_role "$role"
    wait_ready "$role" || die "the $role did not start. See ./tunnel.sh logs $role"

    if [ "$role" = client ]; then
        step "Check the tunnel"
        check_tunnel || true
        step "Done"
        print_connect_help
    else
        step "Done"
        print_server_help
    fi
}

# start_role ROLE: complete .env, check the keys and start the container.
start_role() {
    local role=$1
    ensure_env "$role"
    check_keys "$role"
    mkdir -p "$(log_dir "$role")"
    fix_modes "$role"
    retire_old_container "$role"
    if [ "$role" = client ]; then info "autossh logs in with: $(cat "$TUNNEL_KEY.pub")"; fi
    if [ "$role" = server ]; then restrict_server_keys; fi
    if [ "$FOREGROUND" = 1 ]; then
        compose_cmd "$role" up
    else
        compose_cmd "$role" up -d --quiet-pull
    fi
}

cmd_start() {
    parse_args "$@"
    local role
    role=$(pick_role "$ROLE")
    need_docker
    start_role "$role"
}

cmd_stop() {
    parse_args "$@"
    local role
    role=$(pick_role "$ROLE")
    need_docker
    project_cmd "$role" stop
}

cmd_status() {
    parse_args "$@"
    local role
    need_docker
    for role in $(roles_or_all "$ROLE"); do
        step "$role ($(compose_file "$role"))"
        docker ps -a --filter "label=com.docker.compose.project=$(project_name "$role")" \
            --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
        if [ "$role" = client ] && [ -n "$(env_get REVERSE_SERVER_HOST)" ]; then print_connect_help; fi
    done
}

cmd_logs() {
    local role=''
    case ${1:-} in client | server) role=$1 && shift ;; esac
    role=$(pick_role "$role")
    need_docker
    project_cmd "$role" logs "$@"
}

cmd_keygen() {
    parse_args "$@"
    local role existing file
    role=$(pick_role "$ROLE")
    need_ssh ssh-keygen
    existing=$(key_files "$role")
    if [ -n "$existing" ]; then
        info "These files will be replaced:"
        while IFS= read -r file; do info "  $file"; done <<<"$existing"
        if [ "$role" = client ]; then
            warn "the outside server has to accept the new tunnel key afterwards (./tunnel.sh pubkey)."
        else
            warn "every inside machine has to be accepted again, and they will see a new host key."
        fi
        if [ "$ASSUME_YES" = 0 ]; then
            interactive || die "keys exist already. Add --yes to replace them."
            confirm "Make new keys?" || die "nothing changed"
        fi
    fi
    make_keys "$role" new
    if [ "$role" = client ]; then
        info "Tunnel key for the outside server (./tunnel.sh authorize '<key>' there):"
        printf '\n    %s\n' "$(cat "$TUNNEL_KEY.pub")"
    fi
}

cmd_pubkey() {
    [ -f "$TUNNEL_KEY.pub" ] || die "no tunnel key yet: run ./tunnel.sh keygen client"
    cat "$TUNNEL_KEY.pub"
}

# authorize [--tunnel-port PORT] KEY|FILE|-...: accept inside machines' tunnel
# keys, each only for PORT (default: REVERSE_TUNNEL_SSH_PORT from .env).
cmd_authorize() {
    local port='' keys=() problem
    while [ $# -gt 0 ]; do
        case $1 in
            --tunnel-port=*) port=${1#*=} ;;
            --tunnel-port)
                [ $# -ge 2 ] || die "$1 needs a value"
                port=$2
                shift
                ;;
            *) keys+=("$1") ;;
        esac
        shift
    done
    [ ${#keys[@]} -gt 0 ] || die "usage: ./tunnel.sh authorize [--tunnel-port PORT] 'ssh-rsa AAAA... comment' | KEY_FILE | -"
    port=${port:-$(value_for REVERSE_TUNNEL_SSH_PORT)}
    problem=$(check_value REVERSE_TUNNEL_SSH_PORT "$port") || die "$problem"
    need_ssh ssh-keygen
    mkdir -p "$(dirname "$SERVER_AUTHORIZED_KEYS")"
    add_keys "$SERVER_AUTHORIZED_KEYS" "$(tunnel_key_options "$port")" "${keys[@]}"
    restrict_server_keys
    info "Each key may only open its tunnel port (this one: $port), with no shell."
    info "sshd reads $SERVER_AUTHORIZED_KEYS at every login: no restart needed."
}

need_client_env() {
    [ -f "$TUNNEL_KEY.pub" ] || die "no tunnel key yet: run ./tunnel.sh install client"
    [ -n "$(env_get REVERSE_SERVER_HOST)" ] || die "REVERSE_SERVER_HOST is not set: run ./tunnel.sh install client"
}

cmd_copy_key() {
    need_ssh ssh-copy-id
    need_client_env
    copy_key
}

cmd_connect_outside() {
    [ $# -eq 0 ] || die "connect-outside takes no command: the tunnel key has no shell on the outside server"
    need_ssh ssh
    need_client_env
    echo "---- Public key used by autossh"
    cat "$TUNNEL_KEY.pub"
    echo "---- Outside server (from .env)"
    echo "Host: $(env_get REVERSE_SERVER_HOST)  User: $(env_get REVERSE_SERVER_USER_NAME)  SSH port: $(env_get REVERSE_SERVER_SSH_PORT)"
    echo "---- Logging in with the tunnel key (the outside server gives it no shell)"
    test_outside || die "the outside server does not accept the tunnel key"
}

cmd_shell() {
    need_docker
    docker exec -it "$(container_name client)" /bin/bash
}

cmd_uninstall() {
    parse_args "$@"
    need_docker
    local roles role item containers='' networks='' images='' files='' image old old_key=''
    roles=$(roles_or_all "$ROLE")

    # Ask about the optional parts when nothing was chosen on the command line.
    if interactive && [ $((REMOVE_IMAGES + REMOVE_KEYS + REMOVE_ENV + REMOVE_LOGS)) = 0 ]; then
        step "What to remove besides the containers and the network"
        if confirm "Also remove the openssh-server image?"; then REMOVE_IMAGES=1; fi
        if confirm "Also delete the keys? (cannot be undone)"; then REMOVE_KEYS=1; fi
        if confirm "Also delete .env? (cannot be undone)"; then REMOVE_ENV=1; fi
        if confirm "Also delete the logs?"; then REMOVE_LOGS=1; fi
    fi

    for role in $roles; do
        containers+=" $(project_containers "$role")"
        old=$(old_container "$role")
        if [ -n "$old" ]; then containers+=" ${old%% *}"; fi
        networks+=" $(project_networks "$role")"
        if [ "$REMOVE_IMAGES" = 1 ]; then
            image=$(value_for OPENSSH_IMAGE)
            if docker image inspect "$image" >/dev/null 2>&1 && [[ " $images " != *" $image "* ]]; then images+=" $image"; fi
        fi
        if [ "$REMOVE_KEYS" = 1 ]; then files+=" $(key_files "$role")"; fi
        if [ "$REMOVE_LOGS" = 1 ] && [ -d "$(log_dir "$role")" ]; then files+=" $(log_dir "$role")"; fi
    done
    if [ "$REMOVE_ENV" = 1 ] && [ -f "$ENV_FILE" ]; then files+=" $ENV_FILE"; fi
    containers=$(words "$containers") networks=$(words "$networks") images=$(words "$images") files=$(words "$files")

    step "Remove ($roles)"
    if [ -z "$containers$networks$images$files" ]; then
        ok "nothing to remove"
        return 0
    fi
    for item in $containers; do info "container  $item"; done
    for item in $networks; do info "network    $item"; done
    for item in $images; do info "image      $item"; done
    for item in $files; do info "delete     $ROOT/$item"; done

    if [ "$ASSUME_YES" = 0 ]; then
        if interactive; then
            confirm "Go ahead?" || die "nothing removed"
        elif [ -n "$files" ]; then
            die "this deletes files for good. Add --yes to go ahead (nothing removed)."
        fi
    fi

    for role in $roles; do
        retire_old_container "$role"
        if [ -n "$(project_containers "$role")$(project_networks "$role")" ]; then
            project_cmd "$role" down
        fi
    done
    for item in $images; do
        if docker image rm "$item" >/dev/null; then
            ok "removed image $item"
        else
            warn "kept image $item: another container still uses it"
        fi
    done
    if [[ " $files " == *" $TUNNEL_KEY.pub "* ]]; then old_key=$(awk '{ print $NF }' "$TUNNEL_KEY.pub"); fi
    for item in $files; do
        rm -rf "$item" || warn "could not delete $ROOT/$item (owned by another user?): sudo rm -rf '$ROOT/$item'"
    done
    if [ -d logs ]; then rmdir logs 2>/dev/null || true; fi

    if [ -n "$old_key" ]; then
        warn "the outside server still accepts the deleted tunnel key ($old_key). Delete that line from $SERVER_AUTHORIZED_KEYS there."
    fi
    verify_removed "$roles" "$files"
}

# words TEXT: the words of TEXT on one line, with single spaces.
words() {
    local word out=''
    for word in $1; do out+="${out:+ }$word"; done
    echo "$out"
}

# verify_removed ROLES FILES: fail if a container, network or file is still there.
verify_removed() {
    local role item left=''
    for role in $1; do
        left+=" $(project_containers "$role") $(project_networks "$role")"
    done
    for item in $2; do
        if [ -e "$item" ]; then left+=" $item"; fi
    done
    left=$(words "$left")
    if [ -n "$left" ]; then die "still there: $left"; fi
    ok "removed. The folder $ROOT itself stays; delete it when you no longer need it."
}

# --------------------------------------------------------------------- main

COMMAND=${1:-help}
if [ $# -gt 0 ]; then shift; fi
case $COMMAND in
    install) cmd_install "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    status) cmd_status "$@" ;;
    logs) cmd_logs "$@" ;;
    keygen) cmd_keygen "$@" ;;
    pubkey) cmd_pubkey ;;
    authorize) cmd_authorize "$@" ;;
    copy-key) cmd_copy_key ;;
    connect-outside) cmd_connect_outside "$@" ;;
    shell) cmd_shell ;;
    help | -h | --help) usage ;;
    *)
        usage >&2
        die "unknown command: $COMMAND"
        ;;
esac
