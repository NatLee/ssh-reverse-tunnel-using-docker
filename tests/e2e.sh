#!/usr/bin/env bash
# End-to-end test of tunnel.sh with five containers on two Docker networks:
#
#   wan 203.0.113.0/24:   laptop .50   outside .10   router .2
#   lan 192.168.50.0/24:                             router .254   inside .10   nas .20
#
# outside and inside each run their own Docker (docker:dind) and get a copy of
# this repo, like two real hosts. Docker keeps the two networks apart, and
# inside sends everything through router, which NATs lan -> wan and drops new
# connections the other way. So inside can reach outside, but nothing on wan
# can reach inside or nas: the situation the reverse tunnel is for. The
# addresses come from the documentation ranges and match the README examples.
#
# The test installs both ends without questions (as in the README), logs in
# from laptop through the tunnel and reaches nas through it, restarts and
# recreates containers, runs both installs again on a terminal, then uninstalls
# both ends and checks that no container, network, image or file is left behind.
#
# Usage: tests/e2e.sh   (needs a Docker that can run --privileged containers)
#   KEEP=1 tests/e2e.sh keeps the machines running afterwards, to look around.
set -euo pipefail
export MSYS_NO_PATHCONV=1 # Git Bash on Windows: leave /paths alone

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCKER_ROOT=$(cd "$ROOT" && { pwd -W 2>/dev/null || pwd; }) # the same folder, as the docker CLI sees it (Git Bash: C:/...)
PREFIX=sshrt-e2e
MACHINE_IMAGE=$PREFIX-machine
OPENSSH_IMAGE=$(sed -n 's/^OPENSSH_IMAGE=//p' "$ROOT/.env.example")
SSH_PORT=$(sed -n 's/^REVERSE_SERVER_SSH_PORT=//p' "$ROOT/.env.example")
TUNNEL_PORT=$(sed -n 's/^REVERSE_TUNNEL_SSH_PORT=//p' "$ROOT/.env.example")
CLIENT_CONTAINER=$(sed -n 's/^ *container_name: *//p' "$ROOT/docker-compose.yml")
SERVER_CONTAINER=$(sed -n 's/^ *container_name: *//p' "$ROOT/docker-compose.server.yml")
CLIENT_HOSTNAME=$(sed -n 's/^ *hostname: *//p' "$ROOT/docker-compose.yml")
SERVER_HOSTNAME=$(sed -n 's/^ *hostname: *//p' "$ROOT/docker-compose.server.yml")
SERVER_PROJECT=$(sed -n 's/^name: *//p' "$ROOT/docker-compose.server.yml")
WAN_SUBNET=203.0.113.0/24 OUTSIDE_IP=203.0.113.10 ROUTER_WAN_IP=203.0.113.2 LAPTOP_IP=203.0.113.50
LAN_SUBNET=192.168.50.0/24 INSIDE_IP=192.168.50.10 NAS_IP=192.168.50.20 ROUTER_LAN_IP=192.168.50.254
TESTER=tester
REPO=/home/$TESTER/ssh-reverse-tunnel-using-docker
DEFAULT_USER=$(sed -n 's/^USER_NAME=//p' "$ROOT/.env.example")
OTHER_USER=alice # answered on a terminal, to test changing a setting
WAIT=180          # seconds, for anything that has to come up
WORK=$(mktemp -d) # logs and fingerprints of this run

step() { printf '\n\033[1m### %s\033[0m\n' "$*"; }
pass() { printf '    PASS %s\n' "$*"; }
fail() {
    printf '    FAIL %s\n' "$*" >&2
    exit 1
}

# on MACHINE CMD...: run as the normal user, in the machine's copy of the repo.
on() { docker exec -u "$TESTER" -w "$REPO" "$PREFIX-$1" "${@:2}"; }
# as_root MACHINE CMD...: run as root on the machine.
as_root() { docker exec "$PREFIX-$1" "${@:2}"; }
# into MACHINE CMD...: like as_root, with stdin passed on.
into() { docker exec -i "$PREFIX-$1" "${@:2}"; }
# on_tty MACHINE ANSWERS CMD...: like "on", but on a terminal, typing ANSWERS.
# "<wait>" in ANSWERS pauses the typing: ssh empties the terminal's input before
# it asks about a host key, so that answer has to come after the question.
on_tty() {
    local quoted answers=$2
    printf -v quoted '%q ' "${@:3}"
    {
        while [[ $answers == *'<wait>'* ]]; do
            printf '%b' "${answers%%<wait>*}"
            answers=${answers#*<wait>}
            sleep 15
        done
        printf '%b' "$answers"
    } | timeout 300 docker exec -i -u "$TESTER" -w "$REPO" "$PREFIX-$1" script -qec "$quoted" /dev/null
}
# has FILE TEXT: FILE contains TEXT.
has() { grep -qF -- "$2" "$1"; }

# eventually SECONDS CMD...: retry CMD until it works.
eventually() {
    local deadline=$((SECONDS + $1))
    shift
    until "$@" >/dev/null 2>&1; do
        [ $SECONDS -lt $deadline ] || return 1
        sleep 3
    done
}

cleanup() {
    local status=$?
    if [ $status -ne 0 ]; then
        step "failed, last logs"
        for m in outside inside; do
            for c in "$SERVER_CONTAINER" "$CLIENT_CONTAINER"; do
                as_root "$m" docker logs --tail 40 "$c" 2>/dev/null | sed "s/^/    [$m $c] /" || true
            done
        done
    fi
    if [ "${KEEP:-0}" = 1 ]; then return; fi
    docker rm -f "$PREFIX-laptop" "$PREFIX-outside" "$PREFIX-inside" "$PREFIX-router" "$PREFIX-nas" >/dev/null 2>&1 || true
    docker network rm "$PREFIX-wan" "$PREFIX-lan" >/dev/null 2>&1 || true
    docker image rm "$MACHINE_IMAGE" >/dev/null 2>&1 || true
    rm -rf "$WORK"
    exit $status
}
trap cleanup EXIT

step "machines and networks"
docker build -q -t "$MACHINE_IMAGE" -f "$DOCKER_ROOT/tests/machine.Dockerfile" "$DOCKER_ROOT/tests" >/dev/null
docker network create --subnet "$WAN_SUBNET" "$PREFIX-wan" >/dev/null
docker network create --subnet "$LAN_SUBNET" "$PREFIX-lan" >/dev/null
docker run -d --rm --name "$PREFIX-outside" --hostname outside --privileged --memory 1g \
    --network "$PREFIX-wan" --ip "$OUTSIDE_IP" "$MACHINE_IMAGE" >/dev/null
docker run -d --rm --name "$PREFIX-inside" --hostname inside --privileged --memory 1g \
    --network "$PREFIX-lan" --ip "$INSIDE_IP" "$MACHINE_IMAGE" >/dev/null
docker run -d --rm --name "$PREFIX-router" --hostname router --cap-add NET_ADMIN --memory 128m \
    --sysctl net.ipv4.ip_forward=1 --network "$PREFIX-wan" --ip "$ROUTER_WAN_IP" \
    --entrypoint sleep "$MACHINE_IMAGE" infinity >/dev/null
docker network connect --ip "$ROUTER_LAN_IP" "$PREFIX-lan" "$PREFIX-router"
docker run -d --rm --name "$PREFIX-laptop" --hostname laptop --memory 256m \
    --network "$PREFIX-wan" --ip "$LAPTOP_IP" --entrypoint sleep "$MACHINE_IMAGE" infinity >/dev/null
# Another machine on the inside network, with a web page only the inside can see.
docker run -d --rm --name "$PREFIX-nas" --hostname nas --memory 64m \
    --network "$PREFIX-lan" --ip "$NAS_IP" --entrypoint sh "$MACHINE_IMAGE" \
    -c 'mkdir -p /srv && echo "hello from the inside network" >/srv/index.html && exec httpd -f -p 80 -h /srv' >/dev/null

WAN_IF=$(as_root router ip -o -4 addr show | awk -v ip="$ROUTER_WAN_IP" 'index($4, ip "/") == 1 { print $2 }')
# router: NAT from lan to wan, nothing from wan to lan unless it answers a lan connection.
as_root router iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE
as_root router iptables -A FORWARD -i "$WAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
as_root router iptables -A FORWARD -i "$WAN_IF" -j DROP
as_root inside ip route replace default via "$ROUTER_LAN_IP"

for m in outside inside; do
    eventually 60 as_root "$m" docker info || fail "Docker did not start on $m"
done
step "copy the repo and the $OPENSSH_IMAGE image onto both machines"
docker image inspect "$OPENSSH_IMAGE" >/dev/null 2>&1 || docker pull -q "$OPENSSH_IMAGE" >/dev/null
for m in outside inside; do
    docker save "$OPENSSH_IMAGE" | into "$m" docker load -q >/dev/null
    (cd "$ROOT" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) |
        docker exec -i -u "$TESTER" "$PREFIX-$m" sh -c "mkdir -p $REPO && tar -xf - -C $REPO"
    # Fingerprint of the copy as cloned: uninstall --all must bring it back to exactly this.
    on "$m" sh -c 'find . -type f -exec sha256sum {} + | sort -k2' >"$WORK/$m-before.txt"
done

step "nothing on the outside can reach the inside network, but inside reaches out"
if as_root laptop ping -c 1 -W 2 "$INSIDE_IP" >/dev/null 2>&1; then fail "laptop reaches inside directly"; fi
if as_root outside ping -c 1 -W 2 "$INSIDE_IP" >/dev/null 2>&1; then fail "outside reaches inside directly"; fi
if as_root laptop wget -q -T 3 -O- "http://$NAS_IP/" >/dev/null 2>&1; then fail "laptop reaches nas directly"; fi
as_root inside ping -c 1 -W 2 "$OUTSIDE_IP" >/dev/null || fail "inside cannot reach outside"
eventually 30 as_root inside wget -q -T 3 -O- "http://$NAS_IP/" || fail "inside cannot reach nas"
pass "laptop and outside cannot reach $INSIDE_IP or $NAS_IP; inside reaches $OUTSIDE_IP (through router) and $NAS_IP"

step "README 'No questions': keygen on inside, install server --yes --authorize-key, install client --yes"
on inside sh -c 'mkdir -p ~/.ssh && ssh-keygen -q -t ed25519 -N "" -C tester@inside -f ~/.ssh/id_ed25519'
on inside ./tunnel.sh keygen client
on inside sh -c './tunnel.sh pubkey > ~/tunnel.pub'
on inside cat "/home/$TESTER/tunnel.pub" | docker exec -i -u "$TESTER" "$PREFIX-outside" sh -c 'cat > ~/tunnel.pub'
TUNNEL_PUB=$(on inside cat "/home/$TESTER/tunnel.pub")
on outside sh -c './tunnel.sh install server --yes --authorize-key ~/tunnel.pub' | tee "$WORK/install-server.log"
has "$WORK/install-server.log" "reverse-tunnel@inside (RSA)" || fail "the tunnel key was not accepted"
GOT=$(on outside grep -E '^(TUNNEL_ROLE|USER_NAME|REVERSE_SERVER_SSH_PORT|REVERSE_TUNNEL_SSH_PORT)=' .env | sort | tr '\n' ' ')
[ "$GOT" = "REVERSE_SERVER_SSH_PORT=$SSH_PORT REVERSE_TUNNEL_SSH_PORT=$TUNNEL_PORT TUNNEL_ROLE=server USER_NAME=$DEFAULT_USER " ] ||
    fail "the server's .env is not the defaults: $GOT"
pass "server installed without questions, with the defaults and the tunnel key"
# A container left by the old scripts: same fixed name, but a compose project
# named after the folder. install must clear it out of the way.
as_root inside docker run -d --name "$CLIENT_CONTAINER" --label com.docker.compose.project=old-checkout \
    --entrypoint sleep "$OPENSSH_IMAGE" infinity >/dev/null
on inside ./tunnel.sh install client --yes --server-host "$OUTSIDE_IP" | tee "$WORK/install-client.log"
has "$WORK/install-client.log" "the outside server accepts the tunnel key" || fail "client could not log in to the server"
has "$WORK/install-client.log" "the tunnel works" || fail "client's own tunnel check failed"
has "$WORK/install-client.log" "left over from before tunnel.sh (project old-checkout)" ||
    fail "the container left by the old scripts was not cleared"
pass "client installed (old container cleared), its own check went through the tunnel"
GOT=$(on inside bash ./connect-outside-use-client-key.sh hostname 2>/dev/null | tail -n 1)
[ "$GOT" = "$SERVER_HOSTNAME" ] || fail "connect-outside-use-client-key.sh landed on '$GOT'"
pass "the old connect-outside-use-client-key.sh still logs in to the outside server"

step "laptop: set up as the install output says (key, ~/.ssh/config, known_hosts)"
on inside cat src/user_ssh_key/id_rsa | into laptop sh -c 'umask 077; mkdir -p ~/.ssh; cat >~/.ssh/inside-tunnel_id_rsa'
sed -n '/Host inside-tunnel/,/IdentityFile/p' "$WORK/install-client.log" | sed 's/^      //' | into laptop sh -c 'cat >~/.ssh/config'
grep -F "[$OUTSIDE_IP]:$TUNNEL_PORT " "$WORK/install-client.log" | sed 's/^ *//' | into laptop sh -c 'cat >~/.ssh/known_hosts'
login_from_laptop() {
    # shellcheck disable=SC2016 # the $(...) runs on the inside container
    as_root laptop ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5 inside-tunnel 'echo "$(hostname) $(id -un)"'
}
GOT=$(login_from_laptop) || fail "ssh inside-tunnel from laptop"
[ "$GOT" = "$CLIENT_HOSTNAME $DEFAULT_USER" ] || fail "landed on '$GOT', expected '$CLIENT_HOSTNAME $DEFAULT_USER'"
pass "laptop: ssh inside-tunnel -> $OUTSIDE_IP:$TUNNEL_PORT -> '$GOT', host key checked against the printed lines"
GOT=$(as_root laptop ssh -o BatchMode=yes -p "$TUNNEL_PORT" -i /root/.ssh/inside-tunnel_id_rsa "$DEFAULT_USER@$OUTSIDE_IP" hostname) ||
    fail "the plain ssh -p command"
[ "$GOT" = "$CLIENT_HOSTNAME" ] || fail "ssh -p landed on '$GOT'"
pass "laptop: ssh -p $TUNNEL_PORT -i ~/.ssh/inside-tunnel_id_rsa $DEFAULT_USER@$OUTSIDE_IP works too"
as_root laptop ssh -o BatchMode=yes -f -N -L "8080:$NAS_IP:80" inside-tunnel || fail "ssh -f -N -L through the tunnel"
GOT=$(as_root laptop wget -q -T 5 -O- http://localhost:8080/) || fail "nas through ssh -L"
as_root laptop pkill -f "8080:$NAS_IP:80" || true
[ "$GOT" = "hello from the inside network" ] || fail "nas through ssh -L said '$GOT'"
pass "laptop: ssh -f -N -L 8080:$NAS_IP:80 inside-tunnel reaches the nas on the inside network"
GOT=$(on inside ssh -i "/home/$TESTER/.ssh/id_ed25519" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -p "$TUNNEL_PORT" "$DEFAULT_USER@$OUTSIDE_IP" hostname 2>/dev/null) || fail "login with the inside user's own key"
[ "$GOT" = "$CLIENT_HOSTNAME" ] || fail "own key landed on '$GOT'"
pass "the inside user's own ~/.ssh/id_ed25519 may log in too"

# sshd_value MACHINE CONTAINER KEY: what sshd really uses for KEY.
sshd_value() {
    as_root "$1" docker exec "$2" sh -c '/usr/sbin/sshd.pam -T -f /config/sshd/sshd_config -h /config/ssh_host_keys/ssh_host_ed25519_key' |
        awk -v k="$3" '$1 == k { print $2 }'
}
check_sshd() { # check_sshd MACHINE CONTAINER key=value...
    local m=$1 c=$2 pair got
    shift 2
    for pair in "$@"; do
        got=$(sshd_value "$m" "$c" "${pair%%=*}")
        [ "$got" = "${pair#*=}" ] || fail "$c: ${pair%%=*} is '$got', expected '${pair#*=}'"
    done
    pass "$c: $*"
}
step "sshd settings in force"
check_sshd outside "$SERVER_CONTAINER" permitrootlogin=no passwordauthentication=no kbdinteractiveauthentication=no \
    allowtcpforwarding=yes gatewayports=clientspecified clientaliveinterval=15
check_sshd inside "$CLIENT_CONTAINER" permitrootlogin=no passwordauthentication=no kbdinteractiveauthentication=no \
    allowtcpforwarding=yes gatewayports=no

step "outside: recreate the server container; settings and tunnel must come back"
on outside docker compose -p "$SERVER_PROJECT" down >/dev/null 2>&1
on outside ./tunnel.sh start >/dev/null 2>&1
eventually "$WAIT" login_from_laptop || fail "the tunnel did not come back after the server was recreated"
check_sshd outside "$SERVER_CONTAINER" allowtcpforwarding=yes gatewayports=clientspecified
on outside test -f src/server-config/sshd_config.d/tunnel.conf || fail "the server's sshd settings file disappeared"
pass "recreated server: same settings, tunnel back, repo files untouched"

step "inside: stop, start, logs, status, shell"
on inside ./tunnel.sh stop >/dev/null 2>&1
if login_from_laptop; then fail "still reachable after ./tunnel.sh stop"; fi
on inside ./tunnel.sh start >/dev/null 2>&1
eventually "$WAIT" login_from_laptop || fail "the tunnel did not come back after stop / start"
on inside ./tunnel.sh logs --tail 200 >"$WORK/logs.txt" 2>&1
has "$WORK/logs.txt" "Start AutoSSH" || fail "logs do not show autossh"
# The two warnings the README's troubleshooting section calls expected.
has "$WORK/logs.txt" "Permissions could not be set" || fail "no read-only warning in the logs (README says there is one)"
has "$WORK/logs.txt" "are not owned by root" || fail "no custom script banner in the logs (README says there is one)"
on inside ./tunnel.sh status >"$WORK/status.txt"
grep -q "^$CLIENT_CONTAINER .*Up" "$WORK/status.txt" || fail "status does not show $CLIENT_CONTAINER running"
has "$WORK/status.txt" "ssh -p $TUNNEL_PORT " || fail "status does not say how to connect"
on_tty inside "hostname\nexit\n" ./tunnel.sh shell >"$WORK/shell.txt" || fail "shell"
has "$WORK/shell.txt" "$CLIENT_HOSTNAME" || fail "shell did not open in $CLIENT_CONTAINER"
pass "stop takes the tunnel down, start brings it back; logs, status and shell work"

step "outside: install server again on a terminal (Enter for every default), authorize the same key again"
on_tty outside "\n\n\n\n" ./tunnel.sh install server >"$WORK/install-server-again.log" || fail "second install server"
has "$WORK/install-server-again.log" "kept src/server-config/ssh_host_keys/ssh_host_ed25519_key" || fail "a second install replaced the host keys"
on outside ./tunnel.sh authorize "$TUNNEL_PUB" >"$WORK/authorize.log"
has "$WORK/authorize.log" "already accepted" || fail "authorize added the same key twice"
[ "$(on outside grep -c . src/server-config/root_ssh_key/authorized_keys)" = 1 ] || fail "the key is listed more than once"
pass "a second install keeps the host keys; authorize keeps one copy of the key"

step "inside: install client again on a terminal, as the first time (confirm the host key), now as $OTHER_USER"
on inside rm src/root_ssh_key/known_hosts
on_tty inside "\n\n\n\n$OTHER_USER\n1\n<wait>yes\n" ./tunnel.sh install client >"$WORK/install-client-again.log" || fail "second install client"
has "$WORK/install-client-again.log" "Are you sure you want to continue connecting" || fail "no host key question"
has "$WORK/install-client-again.log" "kept src/root_ssh_key/id_rsa" || fail "a second install replaced the tunnel key"
has "$WORK/install-client-again.log" "the tunnel works" || fail "tunnel check after the second install"
GOT=$(as_root laptop ssh -o BatchMode=yes -p "$TUNNEL_PORT" -i /root/.ssh/inside-tunnel_id_rsa "$OTHER_USER@$OUTSIDE_IP" 'id -un') ||
    fail "login as $OTHER_USER"
[ "$GOT" = "$OTHER_USER" ] || fail "logged in as '$GOT'"
pass "questions answered on a terminal: host key confirmed, keys kept, now logging in as $OTHER_USER"

step "old scripts: bash ./keygen.sh --yes makes new client keys"
on inside bash ./keygen.sh --yes >"$WORK/keygen-again.log" 2>&1
has "$WORK/keygen-again.log" "keygen.sh is now: ./tunnel.sh keygen client" || fail "keygen.sh did not say where it moved"
[ "$(on inside ./tunnel.sh pubkey)" != "$TUNNEL_PUB" ] || fail "keygen.sh did not make a new tunnel key"
pass "keygen.sh runs ./tunnel.sh keygen client and replaces the keys"

step "README troubleshooting: forget the outside server's host key"
on inside ssh-keygen -R "[$OUTSIDE_IP]:$SSH_PORT" -f src/root_ssh_key/known_hosts >"$WORK/forget.log" 2>&1
has "$WORK/forget.log" "[$OUTSIDE_IP]:$SSH_PORT found" || fail "ssh-keygen -R did not find the host key"
pass "ssh-keygen -R \"[$OUTSIDE_IP]:$SSH_PORT\" -f src/root_ssh_key/known_hosts removes it"

# no_trace MACHINE: no container, no extra network, no openssh image, files as cloned.
no_trace() {
    local m=$1 left
    left=$(as_root "$m" docker ps -aq)
    [ -z "$left" ] || fail "$m: containers left: $(as_root "$m" docker ps -a --format '{{.Names}}')"
    left=$(as_root "$m" docker network ls --format '{{.Name}}' | grep -vxE 'bridge|host|none' || true)
    [ -z "$left" ] || fail "$m: networks left: $left"
    if as_root "$m" docker image inspect "$OPENSSH_IMAGE" >/dev/null 2>&1; then fail "$m: $OPENSSH_IMAGE is still there"; fi
    on "$m" sh -c 'find . -type f -exec sha256sum {} + | sort -k2' | diff -u "$WORK/$m-before.txt" - ||
        fail "$m: the folder differs from the fresh copy"
    pass "$m: no container, network or image left; every file is back to the fresh copy"
}


step "inside: uninstall --all without --yes and without a terminal must refuse"
if on inside ./tunnel.sh uninstall --all >/dev/null 2>&1; then fail "it deleted files without --yes"; fi
on inside test -f src/root_ssh_key/id_rsa || fail "a key is gone"
[ -n "$(as_root inside docker ps -q --filter "name=^$CLIENT_CONTAINER\$")" ] || fail "the container is gone"
pass "refused, nothing touched"

step "inside: uninstall (default: containers and network only)"
on inside ./tunnel.sh uninstall
[ -z "$(as_root inside docker ps -aq)" ] || fail "inside: a container is left"
on inside test -f src/root_ssh_key/id_rsa || fail "uninstall without --keys deleted a key"
on inside test -f .env || fail "uninstall without --env deleted .env"
pass "containers and network gone, keys and .env kept"

step "inside: uninstall --all --yes"
on inside ./tunnel.sh uninstall --all --yes 2>&1 | tee "$WORK/uninstall-client.log"
has "$WORK/uninstall-client.log" "still accepts the deleted tunnel key (reverse-tunnel@inside)" ||
    fail "uninstall did not say that the server still accepts the deleted key"
no_trace inside

step "outside: uninstall on a terminal, saying yes to everything"
on_tty outside "y\ny\ny\ny\ny\n" ./tunnel.sh uninstall || fail "interactive uninstall"
no_trace outside

step "all good"
