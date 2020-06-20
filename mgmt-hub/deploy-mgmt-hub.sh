#!/bin/bash

# Deploy the management hub components (agbot, exchange, css, postgre, mongo), the agent, and the CLI

# Default environment variables. Note: they have to be exported for envsubst.
#HZN_LISTEN_IP   # the host IP address the hub components should listen on. Can be set to 0.0.0.0 to mean all interfaces. Defaults to the private IP address
export HZN_TRANSPORT=${HZN_TRANSPORT:-http}

export EXCHANGE_IMAGE_TAG=${EXCHANGE_IMAGE_TAG:-latest}   # or can be set to stable or a specific version
export EXCHANGE_PORT=${EXCHANGE_PORT:-3090}
export EXCHANGE_LOG_LEVEL=${EXCHANGE_LOG_LEVEL:-INFO}
export EXCHANGE_SYSTEM_ORG=${EXCHANGE_SYSTEM_ORG:-IBM}
export EXCHANGE_USER_ORG=${EXCHANGE_USER_ORG:-myorg}


export AGBOT_IMAGE_TAG=${AGBOT_IMAGE_TAG:-latest}   # or can be set to stable or a specific version
export AGBOT_PORT=${AGBOT_PORT:-3091}
export AGBOT_ID=${AGBOT_ID:-agbot}   # its agbot id in the exchange
export AGBOT_TOKEN=${AGBOT_TOKEN:-$(cat /dev/urandom | env LC_CTYPE=C tr -dc 'a-zA-Z0-9' | fold -w 30 | head -n 1)}   # its agbot token in the exchange

export CSS_IMAGE_TAG=${CSS_IMAGE_TAG:-latest}   # or can be set to stable or a specific version
export CSS_PORT=${CSS_PORT:-9443}

export POSTGRES_IMAGE_TAG=${POSTGRES_IMAGE_TAG:-latest}   # or can be set to stable or a specific version
export POSTGRES_PORT=${POSTGRES_PORT:-5432}
export POSTGRES_USER=${POSTGRES_USER:-admin}
export EXCHANGE_DATABASE=${EXCHANGE_DATABASE:-exchange}   # the db the exchange uses in the postgres instance
export AGBOT_DATABASE=${AGBOT_DATABASE:-agbot}   # the db the agbot uses in the postgres instance

export MONGO_IMAGE_TAG=${MONGO_IMAGE_TAG:-latest}   # or can be set to stable or a specific version
export MONGO_PORT=${MONGO_PORT:-27017}

export OH_DEVOPS_REPO=${OH_DEVOPS_REPO:-https://raw.githubusercontent.com/open-horizon/devops/master}

usage() {
    exitCode=${1:-0}
    cat << EndOfMessage
Usage: ${0##*/} [-h]

Deploys the Open Horizon management hub components, agent, and CLI on this host.

Flags:
  -h    Show this usage.

Required Environment Variables:
  EXCHANGE_ROOT_PW: the clear exchange root pw to use temporarily to prime the exchange.
  EXCHANGE_ROOT_PW_BCRYPTED: the bcrypted exchange root pw to be put in the exchange config file. Can be the clear pw, but that is not recommended.

Optional Environment Variables:
  For a list of optional environment variables, their defaults and descriptions, see the beginning of this script.
EndOfMessage
    exit $exitCode
}

# Only echo this if VERBOSE is 1 or true
verbose() {
    if [[ "$VERBOSE" == "1" || "$VERBOSE" == "true" ]]; then
        echo 'verbose:' $*
    fi
}

# Echo message and exit
fatal() {
    local exitCode=$1
    # the rest of the args are the message
    echo "Error:" ${@:2}
    exit $exitCode
}

# Check the exit code passed in and exit if non-zero
chk() {
    local exitCode=$1
    local task=$2
    local dontExit=$3   # set to 'continue' to not exit for this error
    if [[ $exitCode == 0 ]]; then return; fi
    echo "Error: exit code $exitCode from: $task"
    if [[ $dontExit != 'continue' ]]; then
        exit $exitCode
    fi
}

# Check both the exit code and http code passed in and exit if non-zero
chkHttp() {
    local exitCode=$1
    local httpCode=$2
    local task=$3
    local dontExit=$4   # set to 'continue' to not exit for this error
    chk $exitCode $task
    if [[ $httpCode == 200 ]]; then return; fi
    echo "Error: http code $httpCode from: $task"
    if [[ $dontExit != 'continue' ]]; then
        if [[ ! "$httpCode" =~ ^[0-9]+$ ]]; then
            httpCode=5   # some times httpCode is the curl error msg
        fi
        exit $httpCode
    fi
}

# Returns exit code 0 if the specified cmd is in the path
isCmdInstalled() {
    local cmd=$1
    command -v $cmd >/dev/null 2>&1
}

# Verify that the prereq commands we need are installed
confirmCmds() {
    for c in $*; do
        #echo "checking $c..."
        if ! isCmdInstalled $c; then
            fatal 2 "$c is not installed but required, exiting"
        fi
    done
}

ensureWeAreRoot() {
    if [[ $(whoami) != 'root' ]]; then
        fatal 2 "must be root to run ${0##*/} with these options."
    fi
}

# Download a file via a URL
getUrlFile() {
    local url="$1"
    local localFile="$2"
    echo "Downloading $url ..."
    if [[ $url == *@* ]]; then
        # special case for development:
        scp $url $localFile
        chk $? "scp'ing $url"
    else
        httpCode=$(curl -sS -w "%{http_code}" -L -o $localFile $url)
        chkHttp $? $httpCode "downloading $url"
    fi
}

getPrivateIp() {
    ip address | grep -m 1 -o -E " inet (172|10|192.168)[^/]*" | awk '{ print $2 }'
}

# Parse cmd line
while getopts ":h" opt; do
	case $opt in
		h) usage
		    ;;
		\?) echo "Error: invalid option: -$OPTARG"; usage 1
		    ;;
		:) echo "Error: option -$OPTARG requires an argument"; usage 1
		    ;;
	esac
done

# Initial checking of the input and OS
if [[ -z "$EXCHANGE_ROOT_PW" || -z "$EXCHANGE_ROOT_PW_BCRYPTED" ]]; then
    fatal 1 "these environment variables must be set: EXCHANGE_ROOT_PW, EXCHANGE_ROOT_PW_BCRYPTED"
fi
ensureWeAreRoot
confirmCmds grep awk curl

# Get private IP to listen on, if they did not specify it otherwise
if [[ -z $HZN_LISTEN_IP ]]; then
    export HZN_LISTEN_IP=$(getPrivateIp)
    chk $? 'getting private IP'
    if [[ -z $HZN_LISTEN_IP ]]; then fatal 2 "Could not get the private IP address"; fi
fi
echo "Manaagement hub components will listen on $HZN_LISTEN_IP"

# Install jq envsubst (gettext-base) docker docker-compose
apt install -y jq gettext-base docker-compose
chk $? 'installing required software'

# Download and process templates from open-horizon/devops
#echo "Downloading template files..."
getUrlFile $OH_DEVOPS_REPO/mgmt-hub/docker-compose.yml docker-compose.yml
getUrlFile $OH_DEVOPS_REPO/mgmt-hub/exchange-tmpl.json /tmp/exchange-tmpl.json
getUrlFile $OH_DEVOPS_REPO/mgmt-hub/agbot-tmpl.json /tmp/agbot-tmpl.json
getUrlFile $OH_DEVOPS_REPO/mgmt-hub/css-tmpl.conf /tmp/css-tmpl.conf

echo "Substituting environment variables into template files..."
cat /tmp/exchange-tmpl.json | envsubst > exchange.json
cat /tmp/agbot-tmpl.json | envsubst > agbot.json
cat /tmp/css-tmpl.conf | envsubst > css.conf

# Start mgmt hub components
echo "Starting Horizon management hub components..."
docker-compose up -d --no-build

# Prime exchange with the user org and admin, and horizon examples

# Install agent and CLI


