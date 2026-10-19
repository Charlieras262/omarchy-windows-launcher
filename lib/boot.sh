#!/bin/bash
# Real boot progress for the Windows VM (spec US5, plan D6), from signals anyone on the host can read:
#
#  1. The container publishes its current startup step as a text fragment on the web port
#     (`/msg.html`, the same file its own web page polls): "Initializing disks...",
#     "Initializing network...", "Configuring boot...", and so on, in a fixed order. Once QEMU is up the
#     file is removed and the URL answers 404. The web port is protected with the VM's own credentials,
#     which the launcher already keeps (0600) for RDP; they are handed to curl on stdin so they never
#     appear in a process list, a log or the state file.
#  2. After that Windows itself boots inside QEMU with no message at all, so progress creeps along a
#     curve that never stalls and never reaches the end by itself.
#  3. The RDP port is probed with a real X.224 connection request; an answer means Windows is up.
#
# Sourced; no side effects at source time. Requires curl, jq-free; od, timeout (coreutils).

OWL_WEB_BASE=${OWL_WEB_BASE:-http://127.0.0.1:8006}
OWL_CREDENTIALS_FILE=${OWL_CREDENTIALS_FILE:-$HOME/.config/windows/credentials}
OWL_RDP_HOST=${OWL_RDP_HOST:-127.0.0.1}
OWL_RDP_PORT=${OWL_RDP_PORT:-3389}

# Progress (percent of the whole launch) for a startup message; empty if it is not one we know.
# A "(NN%)" in the text (image download or conversion) is spread over the first part of the range.
owl_boot_percent_for_message() {
  local m="${1,,}"
  if [[ $m =~ \(([0-9]+)(\.[0-9]+)?%\) ]]; then
    echo $((8 + BASH_REMATCH[1] * 30 / 100))
    return
  fi
  case "$m" in
  *"starting windows"* | *"starting "*" for docker"*) echo 8 ;;
  *"creating "*" image"* | *"extracting image"* | *"converting"*) echo 12 ;;
  *"initializing disks"* | *"resizing "*) echo 14 ;;
  *"configuring display"*) echo 20 ;;
  *"initializing network"*) echo 26 ;;
  *"initializing shared folder"*) echo 30 ;;
  *"starting tpm"*) echo 33 ;;
  *"configuring boot"*) echo 34 ;;
  *"configuring qemu"*) echo 38 ;;
  *) ;;
  esac
}

# Strip the HTML wrapper the container puts around a message.
owl_boot_clean_message() {
  sed -e 's/<[^>]*>//g' -e 's/&amp;/\&/g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&#39;/'/g" |
    tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
}

# One look at the message endpoint. Prints "<state> <text>" where state is:
#   ok           a startup step is being shown (text is the step)
#   gone         the file is gone (404): QEMU is up, Windows is booting
#   unavailable  no web server yet, wrong credentials, timeout, anything else
owl_boot_message() {
  local tmp code
  tmp=$(mktemp) || { echo "unavailable"; return; }
  if [[ -r $OWL_CREDENTIALS_FILE ]]; then
    local user pass
    user=$(sed -n 's/^USERNAME=//p' "$OWL_CREDENTIALS_FILE" | head -n1)
    pass=$(sed -n 's/^PASSWORD=//p' "$OWL_CREDENTIALS_FILE" | head -n1)
    # --config - : the credentials travel on stdin, not on the command line.
    code=$(printf 'user = "%s:%s"\n' "${user//\"/\\\"}" "${pass//\"/\\\"}" |
      curl -s -m 1.5 --config - -o "$tmp" -w '%{http_code}' "$OWL_WEB_BASE/msg.html" 2>/dev/null)
  else
    code=$(curl -s -m 1.5 -o "$tmp" -w '%{http_code}' "$OWL_WEB_BASE/msg.html" 2>/dev/null)
  fi
  case "$code" in
  200) echo "ok $(owl_boot_clean_message <"$tmp")" ;;
  404) echo "gone" ;;
  *) echo "unavailable" ;;
  esac
  rm -f -- "$tmp"
}

# Does the guest answer an RDP connection request? (X.224 CR with RDP_NEG_REQ, 19 bytes.)
# The port is mapped by Docker even while the guest is down, so a bare connect proves nothing;
# only a reply starting with a TPKT header (03 00) does.
owl_probe_rdp() {
  local reply
  reply=$(OWL_H="$OWL_RDP_HOST" OWL_P="$OWL_RDP_PORT" timeout 2 bash -c '
    exec 3<>"/dev/tcp/$OWL_H/$OWL_P" || exit 1
    printf "\x03\x00\x00\x13\x0e\xe0\x00\x00\x00\x00\x00\x01\x00\x08\x00\x03\x00\x00\x00" >&3
    head -c 4 <&3 | od -An -tx1 | tr -d " \n"' 2>/dev/null)
  [[ $reply == 0300* ]]
}

# Progress while Windows boots with nothing to read: 45% → 90%, fast at first, then ever slower.
# $1 = seconds since QEMU came up.
owl_boot_guest_percent() {
  local t="${1:-0}"
  ((t < 0)) && t=0
  echo $((45 + (45 * t) / (t + 25)))
}
