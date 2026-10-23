# Sourced by the deploy scripts. Defines HOST, PASS, PY and:
#   atv_ssh <command>        run a command on the Apple TV as root
#   atv_ssh_script <file>    run a local shell script on the Apple TV
#   atv_scp [-r] <files...> root@$HOST:<dir>/
# Git Bash on Windows uses PuTTY's plink/pscp. WSL and Linux use ssh/scp with sshpass (toolchain/setup.sh installs it).
# Env: ATV_HOST (default 192.168.0.101), ATV_PASS (default alpine)
HOST=${ATV_HOST:-192.168.0.101}; PASS=${ATV_PASS:-alpine}
PY=$(command -v python3 || command -v python)
if command -v plink >/dev/null; then
    atv_ssh() { plink -batch -ssh -pw "$PASS" root@$HOST "$@"; }
    atv_ssh_script() { plink -batch -ssh -pw "$PASS" root@$HOST -m "$(cygpath -w "$1")"; }
    atv_scp() { pscp -batch -q -pw "$PASS" -scp "$@"; }
else
    command -v sshpass >/dev/null || { echo "needs sshpass (sudo apt-get install sshpass)" >&2; exit 1; }
    # the Apple TVs' OpenSSH (5.x-6.x) only has ssh-rsa host keys, which current ssh turns off
    SSHOPT=(-o HostKeyAlgorithms=+ssh-rsa -o StrictHostKeyChecking=accept-new)
    # they also have no sftp-server, so newer scp must be told to use the old protocol (-O)
    scp -O 2>&1 | grep -q 'illegal option\|unknown option' || SSHOPT_SCP=(-O)
    atv_ssh() { sshpass -p "$PASS" ssh "${SSHOPT[@]}" root@$HOST "$@"; }
    atv_ssh_script() { sshpass -p "$PASS" ssh "${SSHOPT[@]}" root@$HOST sh -s < "$1"; }
    atv_scp() { sshpass -p "$PASS" scp -q "${SSHOPT_SCP[@]}" "${SSHOPT[@]}" "$@"; }
fi
