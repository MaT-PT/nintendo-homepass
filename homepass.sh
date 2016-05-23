#!/bin/bash

DEFAULT_PREFIX='4E:53:50:4F:4F'
DEFAULT_SUFFIX='40'
DEFAULT_IFACE='wlan0'
DEFAULT_SSID='attwifi'
DEFAULT_DELAY='1.875m'
LAST_MAC_FILE='.last_mac'
LAST_INDEX_FILE='.last_index'

if [[ -f "homepass.conf" ]]; then
  source homepass.conf
fi

warn() {
  echo "$@" >&2
}

show_help() {
  local NAME=$(basename $0)

  if [[ -n "$1" ]]; then
    # Short format (usage)
    warn "Usage: $NAME [[[-m MAC_ADDRESS] | [[-p MAC_PREFIX] [-s MAC_SUFFIX] | [-f MAC_LIST]] [-d DELAY] [-n]] [-S SSID] [-i INTERFACE]] | [-k] | [-h]"
  else
    # Complete help
    warn "Usage: $NAME [-m MAC_ADDRESS] [-S SSID] [-i INTERFACE]"
    warn "       $NAME [-p MAC_PREFIX] [-s MAC_SUFFIX] [-S SSID] [-i INTERFACE] [-d DELAY] [-n]"
    warn "       $NAME [-k]"
    warn "       $NAME [-h]"
    warn
    warn "When no argument is given, $NAME will start a Homepass AP in cycle mode with SSID $DEFAULT_SSID"
    warn "on interface $DEFAULT_IFACE with a delay of $DEFAULT_DELAY, and attempt to set the previous MAC"
    warn "prefix and suffix from the '$LAST_MAC_FILE' file in case it exists; otherwise just use the default"
    warn "prefix $DEFAULT_PREFIX and suffix $DEFAULT_SUFFIX."
    warn
    warn "-m MAC_ADDRESS"
    warn "      Start a Homepass AP with a fixed MAC address, and exit."
    warn "      MAC_ADDRESS must be a colon-separated 6-byte hexadecimal MAC address, eg. 01:23:45:67:89:AB."
    warn
    warn "-p MAC_PREFIX"
    warn "      Start a Homepass AP in cycle mode with the given MAC prefix (it won't be changed)."
    warn "      MAC_PREFIX must be a colon-separated 5-byte hexadecimal MAC prefix, eg. 01:23:45:67:89."
    warn "      If this option is not given and '-n' is not set, the prefix from the previous MAC address"
    warn "      stored in '$LAST_MAC_FILE' will be used (defaults to $DEFAULT_PREFIX)."
    warn
    warn "-s MAC_SUFFIX"
    warn "      Start a Homepass AP in cycle mode with the given MAC suffix."
    warn "      It will be incremented every DELAY, starting at MAC_SUFFIX up to FF, then reset to 00 and contine from there."
    warn "      The AP will be restarted every time to refresh its MAC address (expect short disconnections client-side)."
    warn "      MAC_SUFFIX must be a byte in 2-digit hexadecimal form, eg. C9."
    warn "      If this option is not given and '-n' is not set, the suffix from the previous MAC address"
    warn "      stored in '$LAST_MAC_FILE' will be used (defaults to $DEFAULT_SUFFIX)."
    warn
    warn "-f MAC_LIST"
    warn "      Start a Homepass AP in cycle mode, using MAC addresses given in file MAC_LIST."
    warn "      The last used position in the list is saved in '$LAST_INDEX_FILE', and used to resume the cycle at the right position."
    warn
    warn "-S SSID"
    warn "      Set the SSID for the Homepass AP (defaults to $DEFAULT_PREFIX)."
    warn "      SSID must be an UTF-8 string, eg. NZ@McD1."
    warn
    warn "-i INTERFACE"
    warn "      Interface used by hostapd to start the Homepass AP (defaults to $DEFAULT_IFACE)."
    warn
    warn "-d DELAY"
    warn "      Cooldown between cycles, in a format understood by sleep(1) (defaults to $DEFAULT_DELAY)."
    warn
    warn "-k"
    warn "      Attempt to kill the currently running hostapd process."
    warn
    warn "-n"
    warn "      The file storing the previously used MAC address won't be used in case '-p' or '-s' aren't set"
    warn "      when not running in fixed mode (-m), thus using default values."
    warn
    warn "-h"
    warn "      Show this help page."
  fi
}

show_usage () {
  show_help 1
}

die() {
  test -n "$@" && warn "ERROR: $@" || warn "An error occurred, exiting..."
  show_usage
  exit 1
}

if [[ "$EUID" -ne 0 ]]; then
   die "Need to be root (use sudo)."
fi

escape_sed() {
   echo "$1" | sed 's@[/\\&]@\\&@g'
}

check_mac() {
  local STR=$1
  if [[ -n "$2" ]]; then
    local SIZE=$2
  else
    local SIZE=6
  fi
  local REGEX="^([0-9A-F]{2}:){$(($SIZE-1))}[0-9A-F]{2}\$"
  if [[ "${STR^^}" =~ $REGEX ]]; then
    return 0
  else
    return 1
  fi
}

kill_ap() {
  if killall hostapd 2>/dev/null; then
    echo "Killed hostapd."
    return 0
  else
    echo "hostapd is not running."
    return 2
  fi
}

change_mac() {
  local MAC=$1
  local IFACE=$2
  local SSID=$3

  echo
  echo "Changing MAC to $MAC on $IFACE..."

  kill_ap
  ifconfig "$IFACE" down
  ifconfig "$IFACE" hw ether "$MAC"
  ifconfig "$IFACE" up
  echo
  hostapd -B <(cat 'hostapd_template.conf' | sed "s/%IFACE%/$(escape_sed "$IFACE")/;s/%SSID%/$(escape_sed "$SSID")/")
}

wait_next() {
  local DELAY=$1
  echo
  date "+[%H:%M:%S] Waiting $DELAY"
  sleep "$DELAY"
}

while getopts ':m:p:s:S:i:d:f:nkh' opt; do
  case "$opt" in
    m)
      if [[ -n "$PREFIX" ]]; then
        die "Can't set a full MAC address with a custom prefix (-p)."
      fi
      if [[ -n "$SUFFIX" ]]; then
        die "Can't set a full MAC address with a custom suffix (-s)."
      fi
      if ! check_mac "$OPTARG"; then
        die "Invalid MAC address: $OPTARG"
      fi
      MAC=${OPTARG^^}
      echo "User-set MAC address: $MAC"
      ;;

    p)
      if [[ -n "$MAC" ]]; then
        die "Can't set a custom prefix with a full MAC address (-m)."
      fi
      if ! check_mac "$OPTARG" 5; then
        die "Invalid MAC prefix: $OPTARG"
      fi
      PREFIX=${OPTARG^^}
      echo "User-set MAC prefix: $PREFIX"
      ;;

    s)
      if [[ -n "$MAC" ]]; then
        die "Can't set a custom suffix with a full MAC address (-m)."
      fi
      if ! check_mac "$OPTARG" 1; then
        die "Invalid MAC suffix: $OPTARG"
      fi
      SUFFIX=${OPTARG^^}
      echo "User-set MAC suffix: $SUFFIX"
      ;;

    S)
      SSID=$OPTARG
      echo "User-set SSID: $SSID"
      ;;

    i)
      IFACE=$OPTARG
      echo "User-set interface: $IFACE"
      ;;

    d)
      DELAY=$OPTARG
      echo "User-set delay: $DELAY"
      ;;

    f)
      MAC_LIST_FILE=$OPTARG
      if [[ ! -f "$MAC_LIST_FILE" ]]; then
        warn "File '$MAC_LIST_FILE' does not exist."
        unset MAC_LIST_FILE
      else
        echo "Using MAC list file '$MAC_LIST_FILE'."
      fi
      ;;

    n)
      NOLAST=1
      ;;

    k)
      if kill_ap; then
        exit 0
      else
        exit 2
      fi
      ;;

    h)
      show_help
      exit 0
      ;;

    \?)
      die "Invalid option: -$OPTARG"
      ;;

    :)
      die "Option -$OPTARG requires an argument."
      ;;
  esac
done

shift $(($OPTIND-1))
if [[ -n "$@" ]]; then
  warn "WARNING: ignoring extra options '$@'"
fi

if [[ -f "$LAST_MAC_FILE" ]]; then
  if [[ -n "$NOLAST" ]]; then
    echo "File '$LAST_MAC_FILE' exists but we're not using it (-n)."
  else
    LAST_MAC=$(cat "$LAST_MAC_FILE" | head -n1)
    if ! check_mac "$LAST_MAC"; then
      unset LAST_MAC
      warn "WARNING: bad MAC address in '$LAST_MAC_FILE'; using defaults."
    fi
  fi
fi

if [[ -f "$LAST_INDEX_FILE" ]]; then
  if [[ -n "$NOLAST" ]]; then
    echo "File '$LAST_INDEX_FILE' exists but we're not using it (-n)."
  else
    LAST_INDEX=$(cat "$LAST_INDEX_FILE" | head -n1)
    TOTAL_LINES=$(wc -l < "$MAC_LIST_FILE")
    if [[ "$LAST_INDEX" -gt "$TOTAL_LINES" ]]; then
      warn "WARNING: Line number $LAST_INDEX invalid or too high; using defaults."
      unset LAST_INDEX
    fi
  fi
fi
if [[ -z "$LAST_INDEX" ]]; then
  LAST_INDEX=0
fi

if [[ -z "$PREFIX" ]]; then
  if [[ -n "$LAST_MAC" ]]; then
    PREFIX=$(echo "$LAST_MAC" | cut -d: -f1-5)
    echo "Using previously set MAC prefix: $PREFIX"
  else
    PREFIX=$DEFAULT_PREFIX
    echo "Using default MAC prefix: $PREFIX"
  fi
fi
if [[ -z "$SUFFIX" ]]; then
  if [[ -n "$LAST_MAC" ]]; then
    SUFFIX=$(echo "$LAST_MAC" | cut -d: -f6)
    echo "Using previously set MAC suffix: $SUFFIX"
  else
    SUFFIX=$DEFAULT_SUFFIX
    echo "Using default MAC suffix: $SUFFIX"
  fi
fi
if [[ -z "$SSID" ]]; then
  SSID=$DEFAULT_SSID
  echo "Using default SSID: $SSID"
fi
if [[ -z "$IFACE" ]]; then
  IFACE=$DEFAULT_IFACE
  echo "Using default interface: $IFACE"
fi
if [[ -z "$DELAY" ]]; then
  DELAY=$DEFAULT_DELAY
  echo "Using default delay: $DELAY"
fi

ifconfig "$IFACE" up >/dev/null 2>&1
IFACE_IP=$(ip addr show "$IFACE" | egrep -o '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}')
if [[ -z "$IFACE_IP" ]]; then
  die "Invalid interface $IFACE."
fi
echo
echo "Setting up NAT routing on interface $IFACE with IP mask $IFACE_IP..."
iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -s "$IFACE_IP" ! -d "$IFACE_IP" -j MASQUERADE

if [[ -n "$MAC" ]]; then
  change_mac "$MAC" "$IFACE" "$SSID"
elif [[ -f "$MAC_LIST_FILE" ]]; then
  echo "Reading MAC list from file '$MAC_LIST_FILE'."
  TOTAL_LINES=$(wc -l < "$MAC_LIST_FILE")

  while true; do
    N=0
    while read -r LINE; do
      ((N++))
      if [[ $N -ge $LAST_INDEX ]]; then
        echo "$N" > $LAST_INDEX_FILE
        MAC=$(echo "$LINE" | cut -d, -f1)

        if check_mac "$MAC"; then
          if echo "$LINE" | grep -F ',' >/dev/null; then
            SSID_LINE=$(echo "$LINE" | cut -d, -f2)
          else
            SSID_LINE=$SSID
          fi

          echo "Line #$N/$TOTAL_LINES"

          change_mac "$MAC" "$IFACE" "$SSID_LINE"

          wait_next "$DELAY"
        else
          warn "Invalid MAC address $MAC, ignoring..."
        fi
      fi
    done < $MAC_LIST_FILE

    LAST_INDEX=0
  done
else
  while true; do
    MAC="$PREFIX:$SUFFIX"
    echo "$MAC" > $LAST_MAC_FILE

    change_mac "$MAC" "$IFACE" "$SSID"

    SUFFIX=$(printf "%02X" $(echo "ibase=16;($SUFFIX+1)%100" | bc))

    wait_next "$DELAY"
  done
fi
