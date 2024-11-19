#!/bin/bash

# Deploy the management hub services (agbot, exchange, css, fdo, postgre, mongo), the agent, and the CLI on the current host.

usage() {
    exitCode=${1:-0}
    cat << EndOfMessage
Usage: ${0##*/} [-c <config-file>] [-A] [-E] [-v] [-h] [-s | -u | -S [-P] | -r <container>]

Deploy the Open Horizon management hub services, agent, and CLI on this host. Currently supports the following operating systems:

* Ubuntu 18.x, 20.x, 22.x (amd64, ppc64le)
* macOS (experimental)
* RHEL 8.x (ppc64le)
* Note: The support for ppc64le is experimental, because the management hub components are not yet generally available for ppc64le.

Flags:
  -c <config-file>   A config file with lines in the form variable=value that set any of the environment variables supported by this script. Takes precedence over the same variables passed in through the environment.
  -A    Do not install the horizon agent package. (It will still install the horizon-cli package.) Without this flag, it will install and register the horizon agent (as well as all of the management hub services).
  -R    Skip registering the edge node. If -A is not specified, it will install the horizon agent.
  -E    Skip loading the horizon example services, policies, and patterns.
  -S    Stop the management hub services and agent (instead of starting them). This flag is necessary instead of you simply running 'docker-compose down' because docker-compose.yml contains environment variables that must be set.
  -P    Purge (delete) the persistent volumes and images of the Horizon services and uninstall the Horizon agent. Can only be used with -S.
  -s    Start the management hub services and agent, without installing software or creating configuration. Intended to be run to restart the services and agent at some point after you have stopped them using -S. (If you want to change the configuration, run this script without any flags.)
  -u    Update any container whose specified version is not currently running.
  -r <container>   Have docker-compose restart the specified container.
  -v    Verbose output.
  -h    Show this usage.

Optional Environment Variables:
  For a list of optional environment variables, their defaults and descriptions, see the beginning of this script.
EndOfMessage
    exit $exitCode
}

# Get current hardware architecture
export ARCH=$(uname -m | sed -e 's/aarch64.*/arm64/' -e 's/x86_64.*/amd64/' -e 's/armv.*/arm/')
if [[ $ARCH == "ppc64le" ]]; then
    export ARCH_DEB=ppc64el
else
    export ARCH_DEB="${ARCH}"
fi

# Set the correct default value for docker-compose command regarding to architecture
if [[ $ARCH == "ppc64le" ]]; then
    export DOCKER_COMPOSE_CMD="pipenv run docker-compose"
else
    export DOCKER_COMPOSE_CMD="docker-compose"
fi

# Parse cmd line
while getopts ":c:ARESPsur:vh" opt; do
	case $opt in
		c)  CONFIG_FILE="$OPTARG"
		    ;;
		A)  OH_NO_AGENT=1
		    ;;
		R)  OH_NO_REGISTRATION=1
		    ;;
		E)  OH_NO_EXAMPLES=1
		    ;;
		S)  STOP=1
		    ;;
		P)  PURGE=1
		    ;;
		s)  START=1
		    ;;
		u)  UPDATE=1
		    ;;
		r)  RESTART="$OPTARG"
		    ;;
		v)  VERBOSE=1
		    ;;
		h)  usage
		    ;;
		\?) echo "Error: invalid option: -$OPTARG"; usage 1
		    ;;
		:)  echo "Error: option -$OPTARG requires an argument"; usage 1
		    ;;
	esac
done

# Read config file, if specified. This will override any corresponding variables from the environment.
# After this, the default values of env vars not set will be set below.
if [[ -n $CONFIG_FILE ]]; then
    if [[ ! -f $CONFIG_FILE ]]; then
        echo "$CONFIG_FILE does not exist"; exit 1
    fi
    echo "Reading configuration file $CONFIG_FILE ..."
    set -a   # export all variable assignments until further notice
    source "$CONFIG_FILE"
    if [[ $? -ne 0 ]]; then echo "there are errors in $CONFIG_FILE"; exit 1; fi   # source seems to return 0 even when there is an error in the file
    set +a   # undoes the automatic exporting
fi

# Default environment variables that can be overridden. Note: most of them have to be exported for envsubst to use when processing the template files.

# You have the option of specifying the exchange root pw: the clear value is only used in this script temporarily to prime the exchange.
# The bcrypted value can be created using the /admin/hashpw API of an existing exhange. It is stored in the exchange config file, which
# is needed each time the exchange starts. It will default to the clear pw, but that is less secure.
if [[ -z "$EXCHANGE_ROOT_PW" ]];then
    if [[ -n "$EXCHANGE_ROOT_PW_BCRYPTED" ]]; then
        # Can't specify EXCHANGE_ROOT_PW_BCRYPTED while having this script generate a random EXCHANGE_ROOT_PW, because they won't match
        fatal 1 "can not specify EXCHANGE_ROOT_PW_BCRYPTED without also specifying the equivalent EXCHANGE_ROOT_PW"
    fi
    EXCHANGE_ROOT_PW_GENERATED=1
fi
generateToken() { head -c 1024 /dev/urandom | base64 | tr -cd "[:alpha:][:digit:]"  | head -c $1; }   # inspired by https://gist.github.com/earthgecko/3089509#gistcomment-3530978
export EXCHANGE_ROOT_PW=${EXCHANGE_ROOT_PW:-$(generateToken 30)}  # the clear exchange root pw, used temporarily to prime the exchange
export EXCHANGE_ROOT_PW_BCRYPTED=${EXCHANGE_ROOT_PW_BCRYPTED:-$EXCHANGE_ROOT_PW}  # we are not able to bcrypt it, so must default to the clear pw when they do not specify it. [DEPRECATED] in v2.124.0+

# the passwords of the admin user in the system org and of the hub admin. Defaults to a generated value that will be displayed at the end
if [[ -z "$EXCHANGE_SYSTEM_ADMIN_PW" ]]; then
    export EXCHANGE_SYSTEM_ADMIN_PW=$(generateToken 30)
    EXCHANGE_SYSTEM_ADMIN_PW_GENERATED=1
fi
if [[ -z "$EXCHANGE_HUB_ADMIN_PW" ]]; then
    export EXCHANGE_HUB_ADMIN_PW=$(generateToken 30)
    EXCHANGE_HUB_ADMIN_PW_GENERATED=1
fi
# the system org agbot token. Defaults to a generated value that will be displayed at the end
if [[ -z "$AGBOT_TOKEN" ]]; then
    export AGBOT_TOKEN=$(generateToken 30)
    AGBOT_TOKEN_GENERATED=1
fi
# the password of the admin user in the user org. Defaults to a generated value that will be displayed at the end
if [[ -z "$EXCHANGE_USER_ADMIN_PW" ]]; then
    export EXCHANGE_USER_ADMIN_PW=$(generateToken 30)
    EXCHANGE_USER_ADMIN_PW_GENERATED=1
fi
# the node token. Defaults to a generated value that will be displayed at the end
if [[ -z "$HZN_DEVICE_TOKEN" ]]; then
    export HZN_DEVICE_TOKEN=$(generateToken 30)
    HZN_DEVICE_TOKEN_GENERATED=1
fi

export HZN_LISTEN_IP=${HZN_LISTEN_IP:-127.0.0.1}   # the host IP address the hub services should listen on. Can be set to 0.0.0.0 to mean all interfaces, including the public IP.
# You can also set HZN_LISTEN_PUBLIC_IP to the public IP if you want to set HZN_LISTEN_IP=0.0.0.0 but this script can't determine the public IP.
export HZN_TRANSPORT=${HZN_TRANSPORT:-http}   # Note: setting this to https is experimental, still under development!!!!!!

export EXCHANGE_DB_PW=${EXCHANGE_DB_PW:-$(generateToken 30)}
export EXCHANGE_IMAGE_NAME=${EXCHANGE_IMAGE_NAME:-openhorizon/${ARCH}_exchange-api}
export EXCHANGE_IMAGE_TAG=${EXCHANGE_IMAGE_TAG:-testing}   # or can be set to stable or a specific version
export EXCHANGE_PORT=${EXCHANGE_PORT:-3090}
export EXCHANGE_LOG_LEVEL=${EXCHANGE_LOG_LEVEL:-INFO}
export EXCHANGE_SYSTEM_ORG=${EXCHANGE_SYSTEM_ORG:-IBM}   # the name of the system org (which contains the example services and patterns). Currently this can not be overridden
export EXCHANGE_USER_ORG=${EXCHANGE_USER_ORG:-myorg}   # the name of the org which you will use to create nodes, service, patterns, and deployment policies
export EXCHANGE_WAIT_ITERATIONS=${EXCHANGE_WAIT_ITERATIONS:-30}
export EXCHANGE_WAIT_INTERVAL=${EXCHANGE_WAIT_INTERVAL:-2}   # number of seconds to sleep between iterations
export HZN_EXCHANGE_URL=${HZN_EXCHANGE_URL:-$HZN_TRANSPORT://$HZN_LISTEN_IP:$EXCHANGE_PORT/v1}

export AGBOT_IMAGE_NAME=${AGBOT_IMAGE_NAME:-openhorizon/${ARCH}_agbot}
export AGBOT_IMAGE_TAG=${AGBOT_IMAGE_TAG:-latest}   # or can be set to stable or a specific version
export AGBOT_ID=${AGBOT_ID:-agbot}   # its agbot id in the exchange
export AGBOT_PORT=${AGBOT_PORT:-3110}   #todo: should we not expose this to anything but localhost?
export AGBOT_INTERNAL_PORT=${AGBOT_INTERNAL_PORT:-8080}
export AGBOT_SECURE_PORT=${AGBOT_SECURE_PORT:-3111}   # the externally accessible port
export AGBOT_INTERNAL_SECURE_PORT=${AGBOT_INTERNAL_SECURE_PORT:-8083}
export ANAX_LOG_LEVEL=${ANAX_LOG_LEVEL:-3}   # passed into the agbot containers
# For descriptions for these values in agbot: https://github.com/open-horizon/anax/blob/40bb7c134f7fc5d1699c921489a07b7ec220c89c/config/config.go#L80
export AGBOT_AGREEMENT_TIMEOUT_S=${AGBOT_AGREEMENT_TIMEOUT_S:-360}
export AGBOT_NEW_CONTRACT_INTERVAL_S=${AGBOT_NEW_CONTRACT_INTERVAL_S:-5}
export AGBOT_PROCESS_GOVERNANCE_INTERVAL_S=${AGBOT_PROCESS_GOVERNANCE_INTERVAL_S:-5}
export AGBOT_EXCHANGE_HEARTBEAT=${AGBOT_EXCHANGE_HEARTBEAT:-5}
export AGBOT_CHECK_UPDATED_POLICY_S=${AGBOT_CHECK_UPDATED_POLICY_S:-7}
export AGBOT_AGREEMENT_BATCH_SIZE=${AGBOT_AGREEMENT_BATCH_SIZE:-300}
export AGBOT_RETRY_LOOK_BACK_WINDOW=${AGBOT_RETRY_LOOK_BACK_WINDOW:-3600}
export AGBOT_MMS_GARBAGE_COLLECTION_INTERVAL=${AGBOT_MMS_GARBAGE_COLLECTION_INTERVAL:-20}
# Note: several alternatives were explored for deploying a 2nd agbot:
#   - the --scale flag: gave errors about port numbers and container names coonflicting
#   - profiles: requires compose schema version 3.9 (1Q2021), docker-compose 1.28, and docker engine 20.10.5 (could switch to this eventually)
#   - multiple docker-compose yml files: only include the 2nd one when the 2nd agbot is requested (chose this option)
export START_SECOND_AGBOT=${START_SECOND_AGBOT:-false}   # a 2nd agbot is mostly used for e2edev testing
if [[ $START_SECOND_AGBOT == 'true' ]]; then export COMPOSE_FILE='docker-compose.yml:docker-compose-agbot2.yml'; fi   # docker-compose will automatically use this
export AGBOT2_PORT=${AGBOT2_PORT:-3120}
export AGBOT2_SECURE_PORT=${AGBOT2_SECURE_PORT:-3121}

export CSS_IMAGE_NAME=${CSS_IMAGE_NAME:-openhorizon/${ARCH}_cloud-sync-service}
export CSS_IMAGE_TAG=${CSS_IMAGE_TAG:-latest}   # or can be set to stable or a specific version
export CSS_PORT=${CSS_PORT:-9443}   # the host port the css container port should be mapped to
export CSS_INTERNAL_PORT=${CSS_INTERNAL_PORT:-8080}   # the port css is listening on inside the container (gets mapped to host port CSS_PORT)
# For descriptions and defaults for these values in CSS: https://github.com/open-horizon/edge-sync-service/blob/master/common/config.go
export CSS_PERSISTENCE_PATH=${CSS_PERSISTENCE_PATH:-/var/edge-sync-service/persist}
export CSS_LOG_LEVEL=${CSS_LOG_LEVEL:-INFO}
export CSS_LOG_TRACE_DESTINATION=${CSS_LOG_TRACE_DESTINATION:-stdout}
export CSS_LOG_ROOT_PATH=${CSS_LOG_ROOT_PATH:-/var/edge-sync-service/log}
export CSS_TRACE_LEVEL=${CSS_TRACE_LEVEL:-INFO}
export CSS_TRACE_ROOT_PATH=${CSS_TRACE_ROOT_PATH:-/var/edge-sync-service/trace}
export CSS_MONGO_AUTH_DB_NAME=${CSS_MONGO_AUTH_DB_NAME:-admin}
export HZN_FSS_CSSURL=${HZN_FSS_CSSURL:-$HZN_TRANSPORT://$HZN_LISTEN_IP:$CSS_PORT}

export POSTGRES_HOST_AUTH_METHOD=${POSTGRES_HOST_AUTH_METHOD:-scram-sha-256}
export POSTGRES_IMAGE_NAME=${POSTGRES_IMAGE_NAME:-postgres}
export POSTGRES_IMAGE_TAG=${POSTGRES_IMAGE_TAG:-13}   # or can be set to stable or a specific version
export POSTGRES_PORT=${POSTGRES_PORT:-5432}
export POSTGRES_USER=${POSTGRES_USER:-admin}
export EXCHANGE_DATABASE=${EXCHANGE_DATABASE:-exchange}   # the db the exchange uses in the postgres instance
export AGBOT_DATABASE=${AGBOT_DATABASE:-exchange}   #todo: figure out how to get 2 different databases created in postgres. The db the agbot uses in the postgres instance

export MONGO_IMAGE_NAME=${MONGO_IMAGE_NAME:-mongo}
export MONGO_IMAGE_TAG=${MONGO_IMAGE_TAG:-6.0}   # or can be set to stable or a specific version
export MONGO_PORT=${MONGO_PORT:-27017}

# FDO Owner [Companion] Service
export EXCHANGE_INTERNAL_INTERVAL=${EXCHANGE_INTERNAL_INTERVAL:-5}   # the number of seconds to wait between attempts to connect to the exchange during startup
export EXCHANGE_INTERNAL_RETRIES=${EXCHANGE_INTERNAL_RETRIES:-12}   # the maximum number of times to try connecting to the exchange during startup to verify the connection info
export EXCHANGE_INTERNAL_URL=${EXCHANGE_INTERNAL_URL:-http://exchange-api:8080/v1}
export FDO_GET_CFG_FILE_FROM=${FDO_GET_CFG_FILE_FROM:-css:}   # or can be set to 'agent-install.cfg' to use the file FDO creates (which doesn't include HZN_AGBOT_URL)
export FDO_GET_PKGS_FROM=${FDO_GET_PKGS_FROM:-https://github.com/open-horizon/anax/releases/latest/download}   # where the FDO container gets the horizon pkgs and agent-install.sh from.
export FDO_OCS_DB_CONTAINER_DIR=${FDO_OCS_DB_CONTAINER_DIR:-/home/fdouser/ocs/config/db}
export FDO_OWN_COMP_SVC_PORT=${FDO_OWN_COMP_SVC_PORT:-9008}
export FDO_OWN_SVC_AUTH=${FDO_OWN_SVC_AUTH:-apiUser:$(generateToken 30)}
export FDO_OWN_SVC_DB=${FDO_OWN_SVC_DB:-fdo}
export FDO_OWN_SVC_DB_PASSWORD=${FDO_OWN_SVC_DB_PASSWORD:-$(generateToken 30)}
export FDO_OWN_SVC_DB_PORT=${FDO_OWN_SVC_DB_PORT:-5433} # Need a different port than the Exchange
export FDO_OWN_SVC_DB_URL=${FDO_OWN_SVC_DB_URL:-jdbc:postgresql://postgres-fdo-owner-service:5432/${FDO_OWN_SVC_DB}}
export FDO_OWN_SVC_DB_USER=${FDO_OWN_SVC_DB_USER:-fdouser}
export FDO_OWN_SVC_IMAGE_NAME=${FDO_OWN_SVC_IMAGE_NAME:-openhorizon/fdo-owner-services}
export FDO_OWN_SVC_IMAGE_TAG=${FDO_OWN_SVC_IMAGE_TAG:-testing}
export FDO_OWN_SVC_PORT=${FDO_OWN_SVC_PORT:-8042}
export FDO_OWN_SVC_VERBOSE=${FDO_OWN_SVC_VERBOSE:-false}
export FDO_OPS_SVC_HOST=${FDO_OPS_SVC_HOST:-${HZN_LISTEN_IP}:${FDO_OWN_SVC_PORT}}
export FIDO_DEVICE_ONBOARD_REL_VER=${FIDO_DEVICE_ONBOARD_REL_VER:-1.1.7}

export SDO_IMAGE_NAME=${SDO_IMAGE_NAME:-openhorizon/sdo-owner-services}
export SDO_IMAGE_TAG=${SDO_IMAGE_TAG:-lastest}   # or can be set to stable, testing, or a specific version

# Note: in this environment, we are not supporting letting them specify their own owner key pair (only using the built-in sample key pair)
export BAO_AUTH_PLUGIN_EXCHANGE=openhorizon-exchange
export BAO_PORT=${BAO_PORT:-8200}
export BAO_PORT_CLUSTER=${BAO_PORT_CLUSTER:-8201}
export BAO_DISABLE_TLS=true
# Todo: Future suuport for TLS/HTTPS with Bao
#if [[ ${HZN_TRANSPORT} == https ]]; then
#    BAO_DISABLE_TLS=false
#else
#    BAO_DISABLE_TLS=true
#fi
export BAO_API_ADDR=${BAO_API_ADDR:-${HZN_TRANSPORT}://0.0.0.0:${BAO_PORT}}
export BAO_CLUSTER_ADDR=${BAO_CLUSTER_ADDR:-${HZN_TRANSPORT}://0.0.0.0:${BAO_PORT_CLUSTER}}
export BAO_IMAGE_NAME=${BAO_IMAGE_NAME:-quay.io/openbao/openbao-ubi}
export BAO_IMAGE_TAG=${BAO_IMAGE_TAG:-2.0}
export BAO_LOG_LEVEL=${BAO_LOG_LEVEL:-info}
export BAO_ROOT_TOKEN=${BAO_ROOT_TOKEN:-}
export BAO_SEAL_SECRET_SHARES=1                                                   # Number of keys that exist that are capabale of being used to unseal the bao instance. 0 < shares >= threshold
export BAO_SEAL_SECRET_THRESHOLD=1                                                # Number of keys needed to unseal the bao instance. threshold <= shares > 0
export BAO_SECRETS_ENGINE_NAME=openhorizon
export BAO_UNSEAL_KEY=${BAO_UNSEAL_KEY:-}
export HZN_BAO_URL=${HZN_TRANSPORT}://${HZN_LISTEN_IP}:${BAO_PORT}
export OPENBAO_PLUGIN_AUTH_OPENHORIZON_VERSION=${OPENBAO_PLUGIN_AUTH_OPENHORIZON_VERSION:-0.1.0-test}
export VAULT_IMAGE_NAME=${VAULT_IMAGE_NAME:-openhorizon/${ARCH}_vault}
export VAULT_IMAGE_TAG=${VAULT_IMAGE_TAG:-latest}


export AGENT_WAIT_ITERATIONS=${AGENT_WAIT_ITERATIONS:-15}
export AGENT_WAIT_INTERVAL=${AGENT_WAIT_INTERVAL:-2}   # number of seconds to sleep between iterations

export COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-hzn}

export HC_DOCKER_TAG=${HC_DOCKER_TAG:-latest}   # when using the anax-in-container agent

OH_DEVOPS_REPO=${OH_DEVOPS_REPO:-https://raw.githubusercontent.com/open-horizon/devops/new-mongodb}
OH_ANAX_RELEASES=${OH_ANAX_RELEASES:-https://github.com/open-horizon/anax/releases/latest/download}
OH_ANAX_MAC_PKG_TAR=${OH_ANAX_MAC_PKG_TAR:-horizon-agent-macos-pkg-x86_64.tar.gz}
OH_ANAX_DEB_PKG_TAR=${OH_ANAX_DEB_PKG_TAR:-horizon-agent-linux-deb-${ARCH_DEB}.tar.gz}
OH_ANAX_RPM_PKG_TAR=${OH_ANAX_RPM_PKG_TAR:-horizon-agent-linux-rpm-${ARCH}.tar.gz}
OH_ANAX_RPM_PKG_X86_TAR=${OH_ANAX_RPM_PKG_X86_TAR:-horizon-agent-linux-rpm-x86_64.tar.gz}
OH_EXAMPLES_REPO=${OH_EXAMPLES_REPO:-https://raw.githubusercontent.com/open-horizon/examples/master}

HZN_DEVICE_ID=${HZN_DEVICE_ID:-node1}   # the edge node id you want to use

# Global variables for this script (not intended to be overridden)
TMP_DIR=/tmp/horizon-all-in-1
mkdir -p $TMP_DIR
CURL_OUTPUT_FILE=$TMP_DIR/curlExchangeOutput
CURL_ERROR_FILE=$TMP_DIR/curlExchangeErrors
BAO_ERROR_FILE=$TMP_DIR/curlBaoError
BAO_KEYS_FILE=$TMP_DIR/baokeys.json
BAO_OUTPUT_FILE=$TMP_DIR/curlBaoOutput
BAO_PLUGIN_FILE=$TMP_DIR/curlBaoPlugin
BAO_STATUS_FILE=$TMP_DIR/curlBaoStatus
SYSTEM_TYPE=${SYSTEM_TYPE:-$(uname -s)}
DISTRO=${DISTRO:-$(. /etc/os-release 2>/dev/null;echo $ID $VERSION_ID)}
IP_REGEX='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'   # use it like: if [[ $host =~ $IP_REGEX ]]
export CERT_DIR=/etc/horizon/keys
export CERT_BASE_NAME=horizonMgmtHub
EXCHANGE_TRUST_STORE_FILE=truststore.p12
# colors for shell ascii output. Must use printf (and add newline) because echo -e is not supported on macos
RED='\e[0;31m'
GREEN='\e[0;32m'
BLUE='\e[0;34m'
PURPLE='\e[0;35m'
CYAN='\e[0;36m'
YELLOW='\e[1;33m'
NC='\e[0m'   # no color, return to default

#====================== Functions ======================

# Only echo this if VERBOSE is 1 or true
verbose() {
    if [[ "$VERBOSE" == '1' || "$VERBOSE" == 'true' ]]; then
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
    local exitCode=${1:?}
    local task=${2:?}
    local dontExit=$3   # set to 'continue' to not exit for this error
    if [[ $exitCode == 0 ]]; then return; fi
    echo "Error: exit code $exitCode from: $task"
    if [[ $dontExit != 'continue' ]]; then
        exit $exitCode
    fi
}

# Check both the exit code and http code passed in and exit if non-zero
chkHttp() {
    local exitCode=${1:?}
    local httpCode=${2:?}
    local goodHttpCodes=${3:?}   # space or comma separated list of acceptable http codes
    local task=${4:?}
    local errorFile=$5   # optional: the file that has the curl error in it
    local outputFile=$6   # optional: the file that has the curl output in it (which sometimes has the error in it)
    local dontExit=$7   # optional: set to 'continue' to not exit for this error
    if [[ -n $errorFile && -f $errorFile && $(wc -c $errorFile | awk '{print $1}') -gt 0 ]]; then
        task="$task, stderr: $(cat $errorFile)"
    fi
    chk $exitCode $task
    if [[ -n $httpCode && $goodHttpCodes == *$httpCode* ]]; then return; fi
    # the httpCode was bad, normally in this case the api error msg is in the outputFile
    if [[ -n $outputFile && -f $outputFile && $(wc -c $outputFile | awk '{print $1}') -gt 0 ]]; then
        task="$task, stdout: $(cat $outputFile)"
    fi
    echo "Error: http code $httpCode from: $task"
    if [[ $dontExit != 'continue' ]]; then
        if [[ ! "$httpCode" =~ ^[0-9]+$ ]]; then
            httpCode=5   # some times httpCode is the curl error msg
        fi
        exit $httpCode
    fi
}

isMacOS() {
	if [[ "$SYSTEM_TYPE" == "Darwin" ]]; then
		return 0
	else
		return 1
	fi
}

isFedora() {
  if [[ "$DISTRO" =~ fedora\ ((3[6-9])|([4-9][0-9])|([1-9][0-9]{2,}))$ ]]; then
    return 0
  else
    return 1
  fi
}

isRedHat8() {
    if [[ "$DISTRO" == 'rhel 8.'* ]] && [[ "${ARCH}" == 'ppc64le' ]]; then
		return 0
	else
		return 1
	fi
}

isUbuntu18() {
    if [[ "$DISTRO" == 'ubuntu 18.'* ]]; then
		return 0
	else
		return 1
	fi
}

isUbuntu2x() {
    if [[ "$DISTRO" =~ ubuntu\ 2[0-9]\.* ]]; then
		return 0
	else
		return 1
	fi
}

isDirInPath() {
    local dir=${1:?}
    echo $PATH | grep -q -E "(^|:)$dir(:|$)"
}

isWordInString() {   # returns true (0) if the specified word is in the space-separated string
    local word=${1:?} string=$2
    if [[ $string =~ (^|[[:space:]])$word($|[[:space:]]) ]]; then
        return 0
    else
        return 1
    fi
}

isDockerContainerRunning() {
    local container=${1:?}
    if [[ -n $(docker ps -q --filter name=$container) ]]; then
		return 0
	else
		return 1
	fi
}

# Run a command that does not have a good quiet option, so we have to capture the output and only show if an error occurs
runCmdQuietly() {
    # all of the args to this function are the cmd and its args
    if [[  "$VERBOSE" == '1' || "$VERBOSE" == 'true' ]]; then
        $*
        chk $? "running: $*"
    else
        local output=$($* 2>&1)
        if [[ $? -ne 0 ]]; then
            echo "Error running $*: $output"
            exit 2
        fi
    fi
}

# Returns exit code 0 if the specified cmd is in the path
isCmdInstalled() {
    local cmd=${1:?}
    command -v $cmd >/dev/null 2>&1
    local ret=$?
    # Special addition for python-based version of docker-compose
    if [[ $ret -ne 0 && $cmd == "docker-compose" ]]; then
        ${DOCKER_COMPOSE_CMD} version --short >/dev/null 2>&1
        ret=$?
    fi
    return $ret
}

# Returns exit code 0 if all of the specified cmds are in the path
areCmdsInstalled() {
    for c in $*; do
        if ! isCmdInstalled $c; then
            return 1
        fi
    done
    return 0
}

# Checks if docker-compose is installed, and if so, if it is at least this minimum version
isDockerComposeAtLeast() {
    local minVersion=${1:?}
    if ! isCmdInstalled docker-compose; then
        return 1   # it is not even installed
    fi
    # docker-compose is installed, check its version
    local lowerVersion=$(echo -e "$(${DOCKER_COMPOSE_CMD} version --short)\n$minVersion" | sort -V | head -n1)
    if [[ $lowerVersion == $minVersion ]]; then
        return 0   # the installed version was >= minVersion
    else
        return 1
    fi
}

# Verify that the prereq commands we need are installed, or exit with error msg
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
        fatal 2 "must be root to run ${0##*/}. Run 'sudo -i' and then run ${0##*/}"
    fi
}

# Download a file via a URL
getUrlFile() {
    local url=${1:?}
    local localFile=${2:?}
    if isWordInString "${url##*/}" "$OH_DONT_DOWNLOAD"; then
        echo "Skipping download of $url"
        return
    fi
    verbose "Downloading $url ..."
    if [[ $url == *@* ]]; then
        # special case for development:
        scp $url $localFile
        chk $? "scp'ing $url"
    else
        local httpCode=$(curl -sS -w "%{http_code}" -L -o $localFile $url 2>$CURL_ERROR_FILE)
        chkHttp $? $httpCode 200 "downloading $url" $CURL_ERROR_FILE $localFile
    fi
}

# Always pull when the image tag is latest or testing. For other tags, try to pull, but if the image exists locally, but does not exist in the remote repo, do not report error.
pullDockerImage() {
    local imagePath=${1:?}
    local imageTag=${imagePath##*:}
    if [[ $imageTag =~ ^(latest|testing)$ || -z $(docker images -q $imagePath 2> /dev/null) ]]; then
        echo "Pulling $imagePath ..."
        runCmdQuietly docker pull $imagePath
    else
        # Docker image exists locally. Try to pull, but only exit if pull fails for a reason other than 'not found'
        echo "Trying to pull $imagePath ..."
        local output=$(docker pull $imagePath 2>&1)
        if [[ $? -ne 0 && $output != *'not found'* ]]; then
            echo "Error running docker pull $imagePath: $output"
            exit 2
        fi
    fi
}

# Pull all of the docker images to ensure we have the most recent images locally
pullImages() {
    # Even though docker-compose will pull these, it won't pull again if it already has a local copy of the tag but it has been updated on docker hub
    pullDockerImage ${AGBOT_IMAGE_NAME}:${AGBOT_IMAGE_TAG}
    pullDockerImage ${EXCHANGE_IMAGE_NAME}:${EXCHANGE_IMAGE_TAG}
    pullDockerImage ${CSS_IMAGE_NAME}:${CSS_IMAGE_TAG}
    pullDockerImage ${POSTGRES_IMAGE_NAME}:${POSTGRES_IMAGE_TAG}
    pullDockerImage ${MONGO_IMAGE_NAME}:${MONGO_IMAGE_TAG}
    pullDockerImage ${FDO_OWN_SVC_IMAGE_NAME}:${FDO_OWN_SVC_IMAGE_TAG}
    pullDockerImage ${BAO_IMAGE_NAME}:${BAO_IMAGE_TAG}
}

# Find 1 of the private IPs of the host - not currently used
getPrivateIp() {
    local ipCmd
    if isMacOS; then ipCmd=ifconfig
    else ipCmd='ip address'; fi
    $ipCmd | grep -m 1 -o -E "\sinet (172|10|192.168)[^/\s]*" | awk '{ print $2 }'
}

# Find 1 of the public IPs of the host
getPublicIp() {
    if [[ -n $HZN_LISTEN_PUBLIC_IP ]]; then
        echo "$HZN_LISTEN_PUBLIC_IP"
        return
    fi
    local ipCmd
    if isMacOS; then ipCmd=ifconfig
    else ipCmd='ip address'; fi
    $ipCmd | grep -o -E "\sinet [^/\s]*" | grep -m 1 -v -E "\sinet (127|172|10|192.168)" | awk '{ print $2 }'
}

getAllIps() {   # get all of the IP addresses and return them as a comma-separated string
    ip address | grep -o -E "\sinet [^/\s]*" | awk -vORS=, '{ print $2 }' | sed 's/,$//'
}

# Source the hzn autocomplete file
add_autocomplete() {
    local shellFile="${SHELL##*/}"
    local autocomplete

    if isMacOS; then
        local autocomplete="/usr/local/share/horizon/hzn_bash_autocomplete.sh"
        # The default terminal app on mac reads .bash_profile instead of .bashrc . But some 3rd part terminal apps read .bashrc, so update that too, if it exists
        for rcFile in ~/.${shellFile}_profile ~/.${shellFile}rc; do
            if [[ -f "$rcFile" ]]; then
                grep -q -E "^source ${autocomplete}" $rcFile 2>/dev/null || echo -e "\nsource ${autocomplete}" >> $rcFile
            fi
        done
    else   # linux
        local autocomplete="/etc/bash_completion.d/hzn_bash_autocomplete.sh"
        grep -q -E "^source ${autocomplete}" ~/.${shellFile}rc 2>/dev/null || echo -e "\nsource ${autocomplete}" >>~/.${shellFile}rc
    fi
}

waitForAgent() {
    local success
    printf "Waiting for the agent to be ready"
    for ((i=1; i<=$AGENT_WAIT_ITERATIONS; i++)); do
        if $HZN node list >/dev/null 2>$CURL_ERROR_FILE; then
            success=true
            break
        fi
        printf '.'
        sleep $AGENT_WAIT_INTERVAL
    done
    echo ''
    if [[ "$success" != 'true' ]]; then
        local numSeconds=$(( $AGENT_WAIT_ITERATIONS * $AGENT_WAIT_INTERVAL ))
        fatal 6 "can not reach the agent (tried for $numSeconds seconds): $(cat $CURL_ERROR_FILE 2>/dev/null)"
    fi
}

putOneFileInCss() {
    local filename=${1:?} objectID=$2 version=$3   # objectID and version are optional
    if [[ -z $objectID ]]; then
        objectID=${filename##*/}
    fi

    echo "Publishing $filename in CSS as public object $objectID in the IBM org..."
    echo '{ "objectID":"'$objectID'", "objectType":"agent_files", "destinationOrgID":"IBM", "version":"'$version'", "public":true }' | $HZN mms -o IBM object publish -m- -f $filename
    chk $? "publishing $filename in CSS as a public object"
}

isCertForHost() {   # Not currently used!! Return true (0) if the current cert is for the specified ip or host.
    local ipOrHost=${1:?}
    currentCert="$CERT_DIR/$CERT_BASE_NAME.crt"
    if [[ ! -f $currentCert ]]; then
        return 1   # does not exist
    fi
    certCommonName=$(openssl x509 -noout -subject -in $currentCert | awk '{print $NF}')   # $NF gets the last word of the text
    chk $? "getting common name of cert $currentCert"
    if [[ $certCommonName == $ipOrHost ]]; then
        return 0
    else
        return 1
    fi
}

removeKeyAndCert() {
    mkdir -p $CERT_DIR && chmod +r $CERT_DIR   # need to make it readable by the non-root user inside the container
    rm -f $CERT_DIR/$CERT_BASE_NAME.{key,crt} $CERT_DIR/$EXCHANGE_TRUST_STORE_FILE
    chk $? "removing key and cert from $CERT_DIR"
}

createTrustStore() {   # Combine the private key and cert into a p12 file for the exchange
    echo "Combining the private key and cert into a p12 file for the exchange..."
    openssl pkcs12 -export -out $CERT_DIR/$EXCHANGE_TRUST_STORE_FILE -in $CERT_DIR/$CERT_BASE_NAME.crt -inkey $CERT_DIR/$CERT_BASE_NAME.key -aes256 -passout pass:
    chk $? "creating $CERT_DIR/$EXCHANGE_TRUST_STORE_FILE"
    chmod +r $CERT_DIR/$EXCHANGE_TRUST_STORE_FILE   # needed so the exchange container can read it when it is mounted into the container
}

createKeyAndCert() {   # create in directory $CERT_DIR a self-signed key and certificate named: $CERT_BASE_NAME.key, $CERT_BASE_NAME.crt
    # Check if the cert is already correct from a previous run, so we don't keep changing it
    if ! isCmdInstalled openssl; then
        fatal 2 "specified HZN_TRANSPORT=$HZN_TRANSPORT, but command openssl is not installed to create the self-signed certificate"
    fi
    if [[ -f "$CERT_DIR/$CERT_BASE_NAME.key" && -f "$CERT_DIR/$CERT_BASE_NAME.crt" ]]; then
        if [[ ! -f $CERT_DIR/$EXCHANGE_TRUST_STORE_FILE ]]; then
            createTrustStore   # this is the case where they kept the persistent data from a previous version of this script
        fi
        echo "Certificate $CERT_DIR/$CERT_BASE_NAME.crt already exists, so not receating it"
        return   # no need to recreate the cert
    fi

    # Create the private key and certificate that all of the mgmt hub components need
    mkdir -p $CERT_DIR && chmod +r $CERT_DIR   # need to make it readable by the non-root user inside the container
    chk $? "making directory $CERT_DIR"
    removeKeyAndCert
    local altNames=$(ip address | grep -o -E "\sinet [^/\s]*" | awk -vORS=,IP: '{ print $2 }' | sed -e 's/^/IP:/' -e 's/,IP:$//')   # result: IP:127.0.0.1,IP:10.21.42.91,...
    altNames="$altNames,DNS:localhost,DNS:agbot,DNS:exchange-api,DNS:css-api,DNS:fdo-owner-services"   # add the names the containers use to contact each other

    echo "Creating self-signed certificate for these IP addresses: $altNames"
    # taken from https://medium.com/@groksrc/create-an-openssl-self-signed-san-cert-in-a-single-command-627fd771f25
    openssl req -newkey rsa:4096 -nodes -sha256 -x509 -keyout $CERT_DIR/$CERT_BASE_NAME.key -days 365 -out $CERT_DIR/$CERT_BASE_NAME.crt -subj "/C=US/ST=NY/L=New York/O=allin1@openhorizon.org/CN=$(hostname)" -extensions san -config <(echo '[req]'; echo 'distinguished_name=req'; echo '[san]'; echo "subjectAltName=$altNames")
    chk $? "creating key and certificate"
    chmod +r $CERT_DIR/$CERT_BASE_NAME.key

    createTrustStore

    #todo: should we do this so local curl cmds will use it: ln -s $CERT_DIR/$CERT_BASE_NAME.crt /etc/ssl/certs
}

export CERT_BASE_NAME_FDO="${CERT_BASE_NAME}FDO"
# For FDO, when the All-in-1 is using http. Use standard method when using https.
createKeyAndCertFDO() {   # create in directory $CERT_DIR a certificate named: $CERT_BASE_NAME_FDO.crt
    # Check if the cert is already correct from a previous run, so we don't keep changing it
    if ! isCmdInstalled openssl; then
        fatal 2 "specified HZN_TRANSPORT=$HZN_TRANSPORT, but command openssl is not installed to create the self-signed certificate"
    fi
    if [[ -f "$CERT_DIR/$CERT_BASE_NAME_FDO.crt" ]]; then
        echo "Certificate $CERT_DIR/$CERT_BASE_NAME_FDO.crt already exists, so not receating it"
        return   # no need to recreate the cert
    fi

    # Create the certificate that FDO needs
    mkdir -p $CERT_DIR && chmod +r $CERT_DIR   # need to make it readable by the non-root user inside the container
    chk $? "making directory $CERT_DIR"
    local altNames=$(ip address | grep -o -E "\sinet [^/\s]*" | awk -vORS=,IP: '{ print $2 }' | sed -e 's/^/IP:/' -e 's/,IP:$//')   # result: IP:127.0.0.1,IP:10.21.42.91,...
    altNames="$altNames,DNS:localhost,DNS:agbot,DNS:exchange-api,DNS:css-api,DNS:fdo-owner-services"   # add the names the containers use to contact each other

    echo "Creating self-signed certificate for these IP addresses: $altNames"
    # taken from https://medium.com/@groksrc/create-an-openssl-self-signed-san-cert-in-a-single-command-627fd771f25
    # In this case we do not need the key, just the certificate.
    openssl req -newkey rsa:4096 -nodes -sha256 -x509 -days 365 -out $CERT_DIR/$CERT_BASE_NAME_FDO.crt -subj "/C=US/ST=NY/L=New York/O=allin1@openhorizon.org/CN=$(hostname)" -extensions san -config <(echo '[req]'; echo 'distinguished_name=req'; echo '[san]'; echo "subjectAltName=$altNames")
    chk $? "creating certificate"

    # Do not need to create the truststore for the Exchange.

    #todo: should we do this so local curl cmds will use it: ln -s $CERT_DIR/$CERT_BASE_NAME_FDO.crt /etc/ssl/certs
}

# ----- Bao functions -----
baoAuthMethodCheck() {
    curl -sS -w "%{http_code}" -o /dev/null -H "X-Vault-Token: $BAO_ROOT_TOKEN" -H Content-Type:application/json -X GET $HZN_BAO_URL/v1/sys/auth/$BAO_SECRETS_ENGINE_NAME/$BAO_AUTH_PLUGIN_EXCHANGE/tune $* 2>$BAO_ERROR_FILE
}

baoCreateSecretsEngine() {
    echo Creating KV ver.2 secrets engine $BAO_SECRETS_ENGINE_NAME...
    httpCode=$(curl -sS -w "%{http_code}" -H "X-Vault-Token: $BAO_ROOT_TOKEN" -H Content-Type:application/json -X POST -d "{\"path\": \"$BAO_SECRETS_ENGINE_NAME\",\"type\": \"kv\",\"config\": {},\"options\": {\"version\":2},\"generate_signing_key\": true}" $HZN_BAO_URL/v1/sys/mounts/$BAO_SECRETS_ENGINE_NAME $* 2>$BAO_ERROR_FILE)
    chkHttp $? $httpCode 204 "baoCreateSecretsEngine" $BAO_ERROR_FILE
}

baoDownloadAuthOHPlugin() {
  if isFedora || isRedHat8 || isUbuntu18 || isUbuntu2x; then
    os=linux
  elif isMacOS; then
    os=darwin
  fi
  if [[ "${ARCH}" == "amd64" ]]; then
    arch=x86_64
  elif [[ "${ARCH}" == "arm" ]]; then
    arch=armv6
  elif [[ "${ARCH}" == "arm64" ]]; then
    arch=arm64v8.0
  fi

  getUrlFile https://github.com/naphelps/openbao-plugin-auth-openhorizon/releases/download/v"$OPENBAO_PLUGIN_AUTH_OPENHORIZON_VERSION"/openbao-plugin-auth-openhorizon_"$OPENBAO_PLUGIN_AUTH_OPENHORIZON_VERSION"_"$os"_"$arch".tar.gz "$TMP_DIR"/openbao-plugin-auth-openhorizon.tar.gz
  mkdir -p $TMP_DIR/openbao/plugins
  tar -zxf $TMP_DIR/openbao-plugin-auth-openhorizon.tar.gz -C $TMP_DIR/openbao/plugins
}

baoEnableAuthMethod() {
    echo Enabling auth method $BAO_AUTH_PLUGIN_EXCHANGE for secrets engine $BAO_SECRETS_ENGINE_NAME...
    httpCode=$(curl -sS -w "%{http_code}" -H "X-Vault-Token: $BAO_ROOT_TOKEN" -H Content-Type:application/json -X POST -d "{\"config\": {\"token\": \"$BAO_ROOT_TOKEN\", \"url\": \"$HZN_TRANSPORT://exchange-api:8080\"}, \"type\": \"$BAO_AUTH_PLUGIN_EXCHANGE\"}" $HZN_BAO_URL/v1/sys/auth/$BAO_SECRETS_ENGINE_NAME)
    chkHttp $? $httpCode 204 "baoEnableAuthMethod" $BAO_ERROR_FILE
}

baoPluginCheck() {
    curl -sS -w "%{http_code}" -o $BAO_PLUGIN_FILE -H "X-Vault-Token: $BAO_ROOT_TOKEN" -H Content-Type:application/json -X GET $HZN_BAO_URL/v1/sys/plugins/catalog/auth/$BAO_AUTH_PLUGIN_EXCHANGE $* 2>$BAO_ERROR_FILE
}

baoPluginHash() {
    echo Generating SHA256 hash of $BAO_AUTH_PLUGIN_EXCHANGE plugin...
    # Note: must redirect stdin to /dev/null, otherwise when this script is being piped into bash the following cmd will gobble the rest of this script and execution will end abruptly
    hash=$($DOCKER_COMPOSE_CMD exec -T bao sha256sum /openbao/plugins/openbao-plugin-auth-openhorizon </dev/null | cut -d " " -f1)
}

baoRegisterPlugin() {
    local hash=
    echo Registering auth plugin $BAO_AUTH_PLUGIN_EXCHANGE to Bao instance...
    baoPluginHash
    httpCode=$(curl -sS -w "%{http_code}" -H "X-Vault-Token: $BAO_ROOT_TOKEN" -H Content-Type:application/json -X PUT -d "{\"sha256\": \"$hash\", \"command\": \"openbao-plugin-auth-openhorizon\", \"version\": \"$OPENBAO_PLUGIN_AUTH_OPENHORIZON_VERSION\"}" $HZN_BAO_URL/v1/sys/plugins/catalog/auth/$BAO_AUTH_PLUGIN_EXCHANGE $* 2>$BAO_ERROR_FILE)
    chkHttp $? $httpCode 204 "baoRegisterPlugin" $BAO_ERROR_FILE
}

baoSecretsEngineCheck() {
    curl -sS -w "%{http_code}" -o /dev/null -H "X-Vault-Token: $BAO_ROOT_TOKEN" -H Content-Type:application/json -X GET $HZN_BAO_URL/v1/sys/mounts/$BAO_SECRETS_ENGINE_NAME $* 2>$BAO_ERROR_FILE
}

baoServiceCheck() {
    echo Checking Bao service status, initialization, and seal...
    httpCode=$(curl -sS -w "%{http_code}" -o $BAO_STATUS_FILE -H Content-Type:application/json -X GET $HZN_BAO_URL/v1/sys/seal-status $* 2>$BAO_ERROR_FILE)
    chkHttp $? $httpCode 200 "baoServiceCheck" $BAO_ERROR_FILE
}

baoUnregisterPlugin() {
    echo Unregistering auth plugin $BAO_AUTH_PLUGIN_EXCHANGE from Bao instance...
    httpCode=$(curl -sS -w "%{http_code}" -H "X-Vault-Token: $BAO_ROOT_TOKEN" -H Content-Type:application/json -X DELETE $HZN_BAO_URL/v1/sys/plugins/catalog/auth/$BAO_AUTH_PLUGIN_EXCHANGE $* 2>$BAO_ERROR_FILE)
    chkHttp $? $httpCode 204 "baoUnregisterPlugin" $BAO_ERROR_FILE
}

# Assumes a secret threshold size of 1
baoUnseal() {
    echo Bao instance is sealed. Unsealing...
    httpCode=$(curl -sS -w "%{http_code}" -o /dev/null -H Content-Type:application/json -X PUT -d "{\"key\": \"$BAO_UNSEAL_KEY\"}" $HZN_BAO_URL/v1/sys/unseal $* 2>$BAO_ERROR_FILE)
    chkHttp $? $httpCode 200 "baoUnseal" $BAO_ERROR_FILE
}

baoInitialize() {
    echo A Bao instance has not been initialized. Initializing...
    httpCode=$(curl -sS -w "%{http_code}" -o $BAO_KEYS_FILE -H Content-Type:application/json -X PUT -d "{\"secret_shares\": $BAO_SEAL_SECRET_SHARES,\"secret_threshold\": $BAO_SEAL_SECRET_THRESHOLD}" $HZN_BAO_URL/v1/sys/init $* 2>$BAO_ERROR_FILE)
    chkHttp $? $httpCode 200 "baoInitialize" $BAO_ERROR_FILE
    BAO_ROOT_TOKEN=$(cat $BAO_KEYS_FILE | jq -r '.root_token')
    BAO_UNSEAL_KEY=$(cat $BAO_KEYS_FILE | jq -r '.keys_base64[0]')
    baoUnseal
    baoCreateSecretsEngine
    baoRegisterPlugin
    baoEnableAuthMethod
}

baoVaildation() {
    echo Found a Bao instance.
    # TODO: Regenerated root user's token
    #if [[ -z $BAO_ROOT_TOKEN ]]; then
    #    BAO_ROOT_TOKEN=$(cat $BAO_KEYS_FILE | jq -r '.root_token')
    #elif [[ -n $BAO_ROOT_TOKEN ]] && [[ $BAO_ROOT_TOKEN != $(cat $BAO_KEYS_FILE | jq -r '.root_token') ]]; then
    #    jq -a $BAO_ROOT_TOKEN '.root_token=$BAO_ROOT_TOKEN' < $BAO_KEYS_FILE > $BAO_KEYS_FILE
    #fi

    # TODO: Rekeyed the seal of the bao instance
    # Will only work if seal was rekeyed to a secret threshold size of 1
    #if [[ -z $BAO_UNSEAL_KEY ]]; then
    #    BAO_UNSEAL_KEY=$(cat $BAO_KEYS_FILE | jq -r '.keys_base64[0]')
    #elif [[ -n $BAO_UNSEAL_KEY ]] && [[ $BAO_UNSEAL_KEY != $(cat $BAO_KEYS_FILE | jq -r 'keys_base64[0]') ]]; then
    #    jq -a $BAO_UNSEAL_KEY 'keys_base64[0]=$BAO_ROOT_TOKEN' < $BAO_KEYS_FILE > $BAO_KEYS_FILE
    #fi

    if [[ $(cat $BAO_STATUS_FILE | jq '.sealed') == true ]]; then
        baoUnseal
    fi

    if [[ $(baoSecretsEngineCheck) == 404 ]]; then
      baoCreateSecretsEngine
      baoRegisterPlugin
      baoEnableAuthMethod
    elif [[ $(baoPluginCheck) == 404 ]]; then
      baoRegisterPlugin
      baoEnableAuthMethod
    elif [[ $(baoAuthMethodCheck) == 400 ]]; then
      baoEnableAuthMethod
    else
        # New Exchange auth plugin
        baoPluginHash
        if [[ $hash != $(cat $BAO_PLUGIN_FILE | jq -r '.data.sha256') ]]; then
            echo Found new auth plugin $BAO_AUTH_PLUGIN_EXCHANGE
            baoUnregisterPlugin
            baoRegisterPlugin
            # TODO: Not sure if the auth method needs to be cycled if the plugin has been cycled
            #baoEnableAuthMethod
        fi
    fi
}

#====================== End of Functions, Start of Main Initialization ======================

# Set distro-dependent variables
if isMacOS; then
    HZN=/usr/local/bin/hzn   # this is where the mac horizon-cli pkg puts it
    export ETC=/private/etc
    export VOLUME_MODE=cached   # supposedly helps avoid 100% cpu consumption bug https://github.com/docker/for-mac/issues/3499
else   # ubuntu and redhat
    HZN=hzn   # this deb horizon-cli pkg puts it in /usr/bin so it is always in the path
    export ETC=/etc
    export VOLUME_MODE=ro
fi

# TODO: Future directory for TLS certificates and keys.
#export BAO_INSTANCE_DIR=${ETC}/vault/file
#export BAO_KEYS_DIR=${ETC}/vault/keys


# Set OS-dependent package manager settings in Linux
if isUbuntu18 || isUbuntu2x; then
    export PKG_MNGR=apt-get
    export PKG_MNGR_INSTALL_QY_CMD="install -yqf"
    export PKG_MNGR_PURGE_CMD="purge -yq"
    export PKG_MNGR_GETTEXT="gettext-base"
else   # redhat
    export PKG_MNGR=dnf
    export PKG_MNGR_INSTALL_QY_CMD="install -y -q"
    export PKG_MNGR_PURGE_CMD="erase -y -q"
    export PKG_MNGR_GETTEXT="gettext"
fi

# Initial checking of the input and OS
if [[ -z "$EXCHANGE_ROOT_PW" || -z "$EXCHANGE_ROOT_PW_BCRYPTED" ]]; then
    fatal 1 "these environment variables must be set: EXCHANGE_ROOT_PW, EXCHANGE_ROOT_PW_BCRYPTED"
fi
if [[ ! $HZN_LISTEN_IP =~ $IP_REGEX ]]; then
    fatal 1 "HZN_LISTEN_IP must be an IP address (not a hostname)"
fi
ensureWeAreRoot

if ! isFedora && ! isMacOS && ! isUbuntu18 && ! isUbuntu2x && ! isRedHat8; then
    fatal 1 "the host must be Fedora 35+ or macOS or Red Hat 8.x (ppc64le) or Ubuntu 18.x (amd64, ppc64le) or Ubuntu 2x.x (amd64, ppc64le)"
fi

printf "${CYAN}------- Checking input and initializing...${NC}\n"
confirmCmds grep awk curl   # these should be automatically available on all the OSes we support
echo "Management hub services will listen on ${HZN_TRANSPORT}://$HZN_LISTEN_IP"

# Install jq envsubst (gettext-base) docker docker-compose
if isMacOS; then
    # we can't install docker* for them
    if ! isCmdInstalled docker || ! isCmdInstalled docker-compose; then
        fatal 2 "you must install docker before running this script: https://docs.docker.com/docker-for-mac/install"
    fi
    if ! areCmdsInstalled jq envsubst socat; then
        fatal 2 "these commands are required: jq, envsubst (installed via the gettext package), socat. Install them via https://brew.sh/ or https://www.macports.org/ ."
    fi
else   # ubuntu and redhat
    echo "Updating ${PKG_MNGR} package index..."
    runCmdQuietly ${PKG_MNGR} update -q -y
    echo "Installing prerequisites, this could take a minute..."
    if [[ $HZN_TRANSPORT == 'https' ]]; then
        optionalOpensslPkg='openssl'
    fi
    runCmdQuietly ${PKG_MNGR} ${PKG_MNGR_INSTALL_QY_CMD} jq ${PKG_MNGR_GETTEXT} make $optionalOpensslPkg

    # If docker isn't installed, do that
    if ! isCmdInstalled docker; then
        echo "Docker is required, installing it..."
        if isFedora; then
          ${PKG_MNGR} install -y moby-engine docker-compose
          chk $? 'installing docker and compose'
          systemctl --now --quiet enable docker
          chk $? 'starting docker'
        elif isUbuntu18 || isUbuntu2x; then
          curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
          chk $? 'adding docker repository key'
          add-apt-repository "deb [arch=${ARCH_DEB}] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
          chk $? 'adding docker repository'
          if [[ $ARCH == "amd64" ]]; then
            ${PKG_MNGR} install -y docker-ce docker-ce-cli containerd.io
          elif [[ $ARCH == "ppc64le" ]]; then
            if isUbuntu18; then
              ${PKG_MNGR} install -y docker-ce containerd.io
            else # Ubuntu 20
              ${PKG_MNGR} install -y docker.io containerd
            fi
          else
            fatal 1 "hardware plarform ${ARCH} is not supported yet"
          fi
          chk $? 'installing docker'
        else # redhat (ppc64le)
          OP_REPO_ID="Open-Power"
          IS_OP_REPO_ID=$(${PKG_MNGR} repolist ${OP_REPO_ID} | grep ${OP_REPO_ID} | cut -d" " -f1)
          if [[ "${IS_OP_REPO_ID}" != "${OP_REPO_ID}" ]]; then
            # Add OpenPower repo with ID Open-Power
            cat > /etc/yum.repos.d/open-power.repo << EOFREPO
[Open-Power]
name=Unicamp OpenPower Lab - $basearch
baseurl=https://oplab9.parqtec.unicamp.br/pub/repository/rpm/
enabled=1
gpgcheck=0
repo_gpgcheck=1
gpgkey=https://oplab9.parqtec.unicamp.br/pub/key/openpower-gpgkey-public.asc
EOFREPO
            runCmdQuietly ${PKG_MNGR} update -q -y
          fi
          ${PKG_MNGR} install -y docker-ce docker-ce-cli containerd
          chk $? 'installing docker'
          systemctl --now --quiet enable docker
          chk $? 'starting docker'
        fi
   fi

    minVersion=1.29.2
    if ! isDockerComposeAtLeast $minVersion; then
        if isCmdInstalled docker-compose; then
            fatal 2 "Need at least docker-compose $minVersion. A down-level version is currently installed, preventing us from installing the latest version. Uninstall docker-compose and rerun this script."
        fi
        echo "docker-compose is not installed or not at least version $minVersion, installing/upgrading it..."
        if [[ "${ARCH}" == "amd64" ]]; then
            # Install docker-compose from its github repo, because that is the only way to get a recent enough version
            curl --progress-bar -L "https://github.com/docker/compose/releases/download/${minVersion}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            chk $? 'downloading docker-compose'
            chmod +x /usr/local/bin/docker-compose
            chk $? 'making docker-compose executable'
            ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
            chk $? 'linking docker-compose to /usr/bin'
         export DOCKER_COMPOSE_CMD="docker-compose"
        elif [[ "${ARCH}" == "ppc64le" ]]; then
            # Install docker-compose for ppc64le platform (python-based)
            ${PKG_MNGR} install -y python3 python3-pip
            chk $? 'installing python3 and pip'
            pip3 install pipenv
            chk $? 'installing pipenv'
           # Install specific version of docker-compose because the latest one is not working just now (possible reason see on https://status.python.org)
            pipenv install docker-compose==$minVersion
            chk $? 'installing python-based docker-compose'
          export DOCKER_COMPOSE_CMD="pipenv run docker-compose"
        else
          fatal 1 "hardware plarform ${ARCH} is not supported yet"
        fi
    fi
fi

# Create self-signed certificate (if necessary)
if [[ $HZN_TRANSPORT == 'https' ]]; then
    if isMacOS; then
        fatal 1 "Using HZN_TRANSPORT=https is not supported on macOS"
    fi
    createKeyAndCert   # this won't recreate it if already correct

    # agbot-tmpl.json can only have these set when using https
    export SECURE_API_SERVER_KEY="/home/agbotuser/keys/${CERT_BASE_NAME}.key"
    export SECURE_API_SERVER_CERT="/home/agbotuser/keys/${CERT_BASE_NAME}.crt"

    export EXCHANGE_HTTP_PORT=8081   #todo: change this back to null when https://github.com/open-horizon/anax/issues/2628 is fixed. Just for CSS. [DEPRECATED] in v2.124.0+
    export EXCHANGE_PEKKO_HTTP_PORT=8081
    export EXCHANGE_HTTPS_PORT=8080   # the internal port it listens on. [DEPRECATED] in v2.124.0+
    export EXCHANGE_PEKKO_HTTPS_PORT=8080
    export EXCHANGE_TRUST_STORE_PATH=\"/etc/horizon/exchange/keys/${EXCHANGE_TRUST_STORE_FILE}\"   # the exchange container's internal path
    export EXCHANGE_TLS_TRUSTSTORE=${EXCHANGE_TRUST_STORE_PATH}
    EXCH_CERT_ARG="--cacert $CERT_DIR/$CERT_BASE_NAME.crt"   # for use when this script is calling the exchange

    export CSS_LISTENING_TYPE=secure

    export HZN_MGMT_HUB_CERT=$(cat $CERT_DIR/$CERT_BASE_NAME.crt)
else
    removeKeyAndCert   # so when we mount CERT_DIR to the containers it will be empty
    export CSS_LISTENING_TYPE=unsecure

    export EXCHANGE_HTTP_PORT=8080   # the internal port it listens on. [DEPRECATED] in v2.124.0+
    export EXCHANGE_PEKKO_HTTPS_PORT=8083
    export EXCHANGE_HTTPS_PORT=null
    export EXCHANGE_TRUST_STORE_PATH=null

    # For FDO only.
    createKeyAndCertFDO
    export HZN_MGMT_HUB_CERT=$(cat "$CERT_DIR/$CERT_BASE_NAME_FDO.crt" | base64)   # needs to be in the environment or docker-compose will complain
fi

# For FDO.
export EXCHANGE_INTERNAL_CERT=${HZN_MGMT_HUB_CERT:-N/A}

# Download and process templates from open-horizon/devops
printf "${CYAN}------- Downloading template files...${NC}\n"
getUrlFile $OH_DEVOPS_REPO/mgmt-hub/docker-compose.yml docker-compose.yml
getUrlFile $OH_DEVOPS_REPO/mgmt-hub/docker-compose-agbot2.yml docker-compose-agbot2.yml
getUrlFile $OH_DEVOPS_REPO/mgmt-hub/exchange-tmpl.json $TMP_DIR/exchange-tmpl.json # [DEPRECATED] in v2.124.0+
getUrlFile $OH_DEVOPS_REPO/mgmt-hub/agbot-tmpl.json $TMP_DIR/agbot-tmpl.json
getUrlFile $OH_DEVOPS_REPO/mgmt-hub/css-tmpl.conf $TMP_DIR/css-tmpl.conf
getUrlFile $OH_DEVOPS_REPO/mgmt-hub/bao-tmpl.json $TMP_DIR/bao-tmpl.json
# Leave a copy of ourself in the current dir for subsequent stop/start commands.
# If they are running us via ./deploy-mgmt-hub.sh we can't overwrite ourselves (or we get syntax errors), so only do it if we are piped into bash or for some other reason aren't executing the script from the current dir
if [[ $0 == 'bash' || ! -f deploy-mgmt-hub.sh ]]; then
    getUrlFile $OH_DEVOPS_REPO/mgmt-hub/deploy-mgmt-hub.sh deploy-mgmt-hub.sh
    chmod +x deploy-mgmt-hub.sh
fi
# also leave a copy of test-mgmt-hub.sh and test-sdo.sh so they can run those afterward, if they want
getUrlFile $OH_DEVOPS_REPO/mgmt-hub/test-mgmt-hub.sh test-mgmt-hub.sh
chmod +x test-mgmt-hub.sh
getUrlFile $OH_DEVOPS_REPO/mgmt-hub/test-fdo.sh test-fdo.sh
chmod +x test-fdo.sh

echo "Substituting environment variables into template files..."
export ENVSUBST_DOLLAR_SIGN='$'   # needed for essentially escaping $, because we need to let the exchange itself replace $EXCHANGE_ROOT_PW_BCRYPTED
mkdir -p /etc/horizon   # putting the config files here because they are mounted long-term into the containers
cat $TMP_DIR/exchange-tmpl.json | envsubst > /etc/horizon/exchange.json # [DEPRECATED] in v2.124.0+
cat $TMP_DIR/agbot-tmpl.json | envsubst > /etc/horizon/agbot.json
cat $TMP_DIR/css-tmpl.conf | envsubst > /etc/horizon/css.conf
export BAO_LOCAL_CONFIG=$(cat $TMP_DIR/bao-tmpl.json | envsubst)
baoDownloadAuthOHPlugin

#====================== Start/Stop/Restart/Update ======================
# Special cases to start/stop/restart via docker-compose needed so all of the same env vars referenced in docker-compose.yml will be set

# Check for invalid flag combinations
if [[ $(( ${START:-0} + ${STOP:-0} + ${UPDATE:-0} )) -gt 1 ]]; then
    fatal 1 "only 1 of these flags can be specified: -s, -S, -u"
fi
if [[ -n "$PURGE" && -z "$STOP" ]]; then
    fatal 1 "-p can only be used with -S"
fi

# Bring down the agent and the mgmt hub services
if [[ -n "$STOP" ]]; then
    printf "${CYAN}------- Stopping Horizon services...${NC}\n"
    # Unregister if necessary
    if [[ $($HZN node list 2>&1 | jq -r '.configstate.state' 2>&1) == 'configured' ]]; then
        $HZN unregister -f
        chk $? 'unregistration'
    fi

    if isMacOS; then
        if [[ -z $OH_NO_AGENT ]]; then
            /usr/local/bin/horizon-container stop
        fi
        if [[ -n "$PURGE" ]]; then
            echo "Uninstalling the Horizon CLI..."
            /usr/local/bin/horizon-cli-uninstall.sh -y   # removes the content of the horizon-cli pkg
            if [[ -z $OH_NO_AGENT ]]; then
                echo "Removing the Horizon agent image..."
                runCmdQuietly docker rmi openhorizon/amd64_anax:$HC_DOCKER_TAG
            fi
        fi
    elif [[ -z $OH_NO_AGENT  ]]; then   # ubuntu and redhat
        echo "Stopping the Horizon agent..."
        systemctl stop horizon
        if [[ -n "$PURGE" ]]; then
            echo "Uninstalling the Horizon agent and CLI..."
            runCmdQuietly ${PKG_MNGR} ${PKG_MNGR_PURGE_CMD} horizon horizon-cli
        fi
    else   # ubuntu and redhat, but only cli
        if [[ -n "$PURGE" ]]; then
            echo "Uninstalling the Horizon CLI..."
            runCmdQuietly ${PKG_MNGR} ${PKG_MNGR_PURGE_CMD} horizon-cli
        fi
    fi

    if [[ -n "$PURGE" ]]; then
        echo "Stopping Horizon management hub services and deleting their persistent volumes..."
        purgeFlag='--volumes'
    else
        echo "Stopping Horizon management hub services..."
    fi
    ${DOCKER_COMPOSE_CMD} down $purgeFlag

    if [[ -n "$PURGE" ]]; then
        removeKeyAndCert
        # TODO: Future directories for bao
        #if [[ -d ${ETC}/bao ]]; then
          # Remove Bao instance
          #rm -dfr ${ETC}/bao
        #fi
    fi

    if [[ -n "$PURGE" && $KEEP_DOCKER_IMAGES != 'true' ]]; then   # KEEP_DOCKER_IMAGES is a hidden env var for convenience while developing this script
        echo "Removing Open-horizon Docker images..."
        runCmdQuietly docker rmi ${AGBOT_IMAGE_NAME}:${AGBOT_IMAGE_TAG} ${BAO_IMAGE_NAME}:${BAO_IMAGE_TAG} ${FDO_OWN_SVC_IMAGE_NAME}:${FDO_OWN_SVC_IMAGE_TAG} ${EXCHANGE_IMAGE_NAME}:${EXCHANGE_IMAGE_TAG} ${CSS_IMAGE_NAME}:${CSS_IMAGE_TAG} ${POSTGRES_IMAGE_NAME}:${POSTGRES_IMAGE_TAG} ${MONGO_IMAGE_NAME}:${MONGO_IMAGE_TAG} ${SDO_IMAGE_NAME}:${SDO_IMAGE_TAG} ${VAULT_IMAGE_NAME}:${VAULT_IMAGE_TAG}
    fi
    exit
fi

# TODO: Future directories for Bao.
#mkdir -p ${BAO_INSTANCE_DIR}
#chown -R 1001 ${BAO_INSTANCE_DIR}
#mkdir -p ${BAO_KEYS_DIR}

# Start the mgmt hub services and agent (use existing configuration)
if [[ -n "$START" ]]; then
    printf "${CYAN}------- Starting Horizon services...${NC}\n"
    pullImages
    ${DOCKER_COMPOSE_CMD} up -d --no-build
    chk $? 'starting docker-compose services'

    if [[ -z $OH_NO_AGENT ]]; then
        echo "Starting the Horizon agent..."
        if isMacOS; then
            /usr/local/bin/horizon-container start
        else   # ubuntu and redhat
            systemctl start horizon
        fi
    fi
    exit
fi

# Run 'docker-compose up ...' again so any mgmt hub containers will be updated
if [[ -n "$UPDATE" ]]; then
    printf "${CYAN}------- Updating management hub containers...${NC}\n"
    pullImages
    ${DOCKER_COMPOSE_CMD} up -d --no-build
    chk $? 'updating docker-compose services'
    exit
fi

# Restart 1 mgmt hub container
if [[ -n "$RESTART" ]]; then
    if [[ $(( ${START:-0} + ${STOP:-0} + ${UPDATE:-0} )) -gt 0 ]]; then
        fatal 1 "-s or -S or -u cannot be specified with -r"
    fi
    printf "${CYAN}------- Restarting the $RESTART container...${NC}\n"
    ${DOCKER_COMPOSE_CMD} restart -t 10 "$RESTART"   #todo: do not know if this will work if there are 2 agbots replicas running
    exit
fi

#====================== Deploy All Of The Services ======================

# If the edge node was previously registered and we are going to register it again, then unregister before we possibly change the mgmt hub components
if [[ -z $OH_NO_AGENT && -z $OH_NO_REGISTRATION ]]; then
    if [[ $($HZN node list 2>&1 | jq -r '.configstate.state' 2>&1) == 'configured' ]]; then   # this check will properly be not true if hzn isn't installed yet
        $HZN unregister -f $UNREGISTER_FLAGS   # this flag variable is left here because rerunning this script was resulting in the unregister failing partway thru, but now i can't reproduce it
        chk $? 'unregistration'
    fi
fi

# Start mgmt hub services
printf "${CYAN}------- Downloading/starting Horizon management hub services...${NC}\n"
echo "Downloading management hub docker images..."
# Even though docker-compose will pull these, it won't pull again if it already has a local copy of the tag but it has been updated on docker hub
pullImages

echo "Starting management hub containers..."
${DOCKER_COMPOSE_CMD} up -d --no-build
chk $? 'starting docker-compose services'

# Ensure the exchange is responding
# Note: wanted to make these aliases to avoid quote/space problems, but aliases don't get inherited to sub-shells. But variables don't get processed again by the shell (but may get separated by spaces), so i think we are ok for the post/put data
exchangeGet() {
    curl -sS -w "%{http_code}" $EXCH_CERT_ARG -u "root/root:$EXCHANGE_ROOT_PW" -o $CURL_OUTPUT_FILE $* 2>$CURL_ERROR_FILE
}
exchangePost() {
    curl -sS -w "%{http_code}" $EXCH_CERT_ARG -u "root/root:$EXCHANGE_ROOT_PW" -o $CURL_OUTPUT_FILE -H Content-Type:application/json -X POST $* 2>$CURL_ERROR_FILE
}
exchangePut() {
    curl -sS -w "%{http_code}" $EXCH_CERT_ARG -u "root/root:$EXCHANGE_ROOT_PW" -o $CURL_OUTPUT_FILE -H Content-Type:application/json -X PUT $* 2>$CURL_ERROR_FILE
}

printf "Waiting for the exchange"
for ((i=1; i<=$EXCHANGE_WAIT_ITERATIONS; i++)); do
    if [[ $(exchangeGet $HZN_EXCHANGE_URL/admin/version) == 200 ]]; then
        success=true
        break
    fi
    printf '.'
    sleep $EXCHANGE_WAIT_INTERVAL
done
echo ''
if [[ "$success" != 'true' ]]; then
    numSeconds=$(( $EXCHANGE_WAIT_ITERATIONS * $EXCHANGE_WAIT_INTERVAL ))
    fatal 6 "can not reach the exchange at $HZN_EXCHANGE_URL (tried for $numSeconds seconds): $(cat $CURL_ERROR_FILE 2>/dev/null)"
fi
# also verify authentication works
if [[ $(exchangeGet $HZN_EXCHANGE_URL/admin/status) != 200 ]]; then
    fatal 6 "exchange root credentials invalid: $(cat $CURL_ERROR_FILE 2>/dev/null)"
fi

# Create exchange resources
# Note: in all of the checks below to see if the resource exists, we don't handle all of the error possibilities, because we'll catch them when we try to create the resource
printf "${CYAN}------- Creating the user org, and the admin user in both orgs...${NC}\n"

# Create the hub admin in the root org and the admin user in system org
echo "Creating exchange hub admin user, and the admin user and agbot in the system org..."
if [[ $(exchangeGet $HZN_EXCHANGE_URL/orgs/root/users/hubadmin) != 200 ]]; then
    httpCode=$(exchangePost -d "{\"password\":\"$EXCHANGE_HUB_ADMIN_PW\",\"hubAdmin\":true,\"admin\":false,\"email\":\"\"}" $HZN_EXCHANGE_URL/orgs/root/users/hubadmin)
    chkHttp $? $httpCode 201 "creating /orgs/root/users/hubadmin" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
else
    # Set the pw to be what they specified this time
    httpCode=$(exchangePost -d "{\"newPassword\":\"$EXCHANGE_HUB_ADMIN_PW\"}" $HZN_EXCHANGE_URL/orgs/root/users/hubadmin/changepw)
    chkHttp $? $httpCode 201 "changing pw of /orgs/root/users/hubadmin" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
fi
if [[ $(exchangeGet $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/users/admin) != 200 ]]; then
    httpCode=$(exchangePost -d "{\"password\":\"$EXCHANGE_SYSTEM_ADMIN_PW\",\"admin\":true,\"email\":\"not@used\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/users/admin)
    chkHttp $? $httpCode 201 "creating /orgs/$EXCHANGE_SYSTEM_ORG/users/admin" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
else
    # Set the pw to be what they specified this time
    httpCode=$(exchangePost -d "{\"newPassword\":\"$EXCHANGE_SYSTEM_ADMIN_PW\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/users/admin/changepw)
    chkHttp $? $httpCode 201 "changing pw of /orgs/$EXCHANGE_SYSTEM_ORG/users/admin" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
fi

printf "${CYAN}------- Creating a Bao instance and performing all setup and configuration operations ...${NC}\n"
# TODO: Implement HTTPS support
if [[ $HZN_TRANSPORT == http ]]; then
    baoServiceCheck
    if [[ $(cat $BAO_STATUS_FILE | jq '.initialized') == false ]]; then
        baoInitialize
    else
        baoVaildation
    fi

    # Cannot read custom configuration keys/values. Assume either its never been set, or it has changed every time.
    echo Configuring auth method $BAO_AUTH_PLUGIN_EXCHANGE for use with the Exchange...
    # Note: must redirect stdin to /dev/null, otherwise when this script is being piped into bash the following cmd will gobble the rest of this script and execution will end abruptly
    ${DOCKER_COMPOSE_CMD} exec -T -e BAO_TOKEN=$BAO_ROOT_TOKEN bao bao write -address=$HZN_TRANSPORT://0.0.0.0:8200 auth/openhorizon/config url=$HZN_TRANSPORT://exchange-api:8080/v1 token=$BAO_ROOT_TOKEN </dev/null
fi

printf "${CYAN}------- Creating an agbot in the exchange...${NC}\n"
# Create or update the agbot in the system org, and configure it with the pattern and deployment policy orgs
#if [[ $(exchangeGet $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/agbots/$AGBOT_ID) == 200 ]]; then
#    restartAgbot='true'   # we may be changing its token, so need to restart it. (If there is initially no agbot resource, the agbot will just wait until it appears)
#fi
httpCode=$(exchangePut -d "{\"token\":\"$AGBOT_TOKEN\",\"name\":\"agbot\",\"publicKey\":\"\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/agbots/$AGBOT_ID)
chkHttp $? $httpCode 201 "creating/updating /orgs/$EXCHANGE_SYSTEM_ORG/agbots/$AGBOT_ID" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
httpCode=$(exchangePost -d "{\"patternOrgid\":\"$EXCHANGE_SYSTEM_ORG\",\"pattern\":\"*\",\"nodeOrgid\":\"$EXCHANGE_USER_ORG\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/agbots/$AGBOT_ID/patterns)
chkHttp $? $httpCode 201,409 "adding /orgs/$EXCHANGE_SYSTEM_ORG/agbots/$AGBOT_ID/patterns" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
httpCode=$(exchangePost -d "{\"patternOrgid\":\"$EXCHANGE_USER_ORG\",\"pattern\":\"*\",\"nodeOrgid\":\"$EXCHANGE_USER_ORG\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/agbots/$AGBOT_ID/patterns)
chkHttp $? $httpCode 201,409 "adding /orgs/$EXCHANGE_SYSTEM_ORG/agbots/$AGBOT_ID/patterns" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
httpCode=$(exchangePost -d "{\"businessPolOrgid\":\"$EXCHANGE_USER_ORG\",\"businessPol\":\"*\",\"nodeOrgid\":\"$EXCHANGE_USER_ORG\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/agbots/$AGBOT_ID/businesspols)
chkHttp $? $httpCode 201,409 "adding /orgs/$EXCHANGE_SYSTEM_ORG/agbots/$AGBOT_ID/businesspols" $CURL_ERROR_FILE $CURL_OUTPUT_FILE


# Bao needs the Agbot to restart everytime there is a setup or configuration change.
# Agbot will enter non-secrets mode if Bao is not working.
${DOCKER_COMPOSE_CMD} restart -t 10 agbot   # docker-compose will print that it is restarting the agbot
chk $? 'restarting agbot service'

# Create the user org and an admin user within it
echo "Creating exchange user org and admin user..."
if [[ $(exchangeGet $HZN_EXCHANGE_URL/orgs/$EXCHANGE_USER_ORG) != 200 ]]; then
    # we set the heartbeat intervals lower than the defaults so agreements will be made faster (since there are only a few nodes)
    httpCode=$(exchangePost -d "{\"label\":\"$EXCHANGE_USER_ORG\",\"description\":\"$EXCHANGE_USER_ORG\",\"heartbeatIntervals\":{\"minInterval\":3,\"maxInterval\":10,\"intervalAdjustment\":1}}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_USER_ORG)
    chkHttp $? $httpCode 201 "creating /orgs/$EXCHANGE_USER_ORG" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
fi
if [[ $(exchangeGet $HZN_EXCHANGE_URL/orgs/$EXCHANGE_USER_ORG/users/admin) != 200 ]]; then
    httpCode=$(exchangePost -d "{\"password\":\"$EXCHANGE_USER_ADMIN_PW\",\"admin\":true,\"email\":\"not@used\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_USER_ORG/users/admin)
    chkHttp $? $httpCode 201 "creating /orgs/$EXCHANGE_USER_ORG/users/admin" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
else
    # Set the pw to be what they specified this time
    httpCode=$(exchangePost -d "{\"newPassword\":\"$EXCHANGE_USER_ADMIN_PW\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_USER_ORG/users/admin/changepw)
    chkHttp $? $httpCode 201 "changing pw of /orgs/$EXCHANGE_USER_ORG/users/admin" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
fi

# Install agent and CLI (CLI is needed for exchangePublish.sh in next step)
printf "${CYAN}------- Downloading/installing/configuring Horizon agent and CLI...${NC}\n"
echo "Downloading the Horizon agent and CLI packages..."
mkdir -p $TMP_DIR/pkgs
rm -rf $TMP_DIR/pkgs/*   # get rid of everything so we can safely wildcard instead of having to figure out the version
if isMacOS; then
    getUrlFile $OH_ANAX_RELEASES/$OH_ANAX_MAC_PKG_TAR $TMP_DIR/pkgs/$OH_ANAX_MAC_PKG_TAR
    tar -zxf $TMP_DIR/pkgs/$OH_ANAX_MAC_PKG_TAR -C $TMP_DIR/pkgs   # will extract files like: horizon-cli-2.27.0.pkg
    chk $? 'extracting pkg tar file'
    echo "Installing the Horizon CLI package..."
    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $TMP_DIR/pkgs/horizon-cli.crt
    sudo installer -pkg $TMP_DIR/pkgs/horizon-cli-*.pkg -target /
    chk $? 'installing macos horizon-cli pkg'
    # we will install the agent below, after configuring /etc/default/horizon
else   # ubuntu and redhat
    if isUbuntu18 || isUbuntu2x; then
        getUrlFile $OH_ANAX_RELEASES/$OH_ANAX_DEB_PKG_TAR $TMP_DIR/pkgs/$OH_ANAX_DEB_PKG_TAR
        tar -zxf $TMP_DIR/pkgs/$OH_ANAX_DEB_PKG_TAR -C $TMP_DIR/pkgs   # will extract files like: horizon-cli_2.27.0_amd64.deb
        chk $? 'extracting pkg tar file'
        if [[ -z $OH_NO_AGENT ]]; then
            echo "Installing the Horizon agent and CLI packages..."
            horizonPkgs=$(ls $TMP_DIR/pkgs/horizon*.deb)
        else   # only horizon-cli
            echo "Installing the Horizon CLI package..."
            horizonPkgs=$(ls $TMP_DIR/pkgs/horizon-cli*.deb)
        fi
        runCmdQuietly ${PKG_MNGR} ${PKG_MNGR_INSTALL_QY_CMD} $horizonPkgs
    else # redhat
        if isFedora; then
          getUrlFile $OH_ANAX_RELEASES/$OH_ANAX_RPM_PKG_X86_TAR $TMP_DIR/pkgs/$OH_ANAX_RPM_PKG_X86_TAR
          tar -zxf $TMP_DIR/pkgs/$OH_ANAX_RPM_PKG_X86_TAR -C $TMP_DIR/pkgs   # will extract files like: horizon-cli_2.27.0_x86_64.rpm
        else
          getUrlFile $OH_ANAX_RELEASES/$OH_ANAX_RPM_PKG_TAR $TMP_DIR/pkgs/$OH_ANAX_RPM_PKG_TAR
          tar -zxf $TMP_DIR/pkgs/$OH_ANAX_RPM_PKG_TAR -C $TMP_DIR/pkgs   # will extract files like: horizon-cli_2.27.0_amd64.rpm
        fi
        chk $? 'extracting pkg tar file'
        echo "Installing the Horizon agent and CLI packages..."
        if [[ -z $OH_NO_AGENT ]]; then
            echo "Installing the Horizon agent and CLI packages..."
            horizonPkgs="horizon-cli horizon"
        else   # only horizon-cli
            echo "Installing the Horizon CLI package..."
            horizonPkgs="horizon-cli"
        fi
        for pkg in $horizonPkgs
        do
            PKG_NAME=${pkg}
            ${PKG_MNGR} list installed ${PKG_NAME} >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                # Already installed: prohibit possible downgrade but return 0 in that case
                INSTALL_CMD="upgrade -y -q"
            else
                # Install the first time
                INSTALL_CMD="${PKG_MNGR_INSTALL_QY_CMD}"
            fi
            runCmdQuietly ${PKG_MNGR} ${INSTALL_CMD} $TMP_DIR/pkgs/${PKG_NAME}-[0-9]*.rpm
        done
    fi
fi
add_autocomplete

# Configure the agent/CLI
export HZN_EXCHANGE_USER_AUTH="root/root:$EXCHANGE_ROOT_PW"
export HZN_ORG_ID=$EXCHANGE_SYSTEM_ORG
echo "Configuring the Horizon agent and CLI..."
if isMacOS; then
    if [[ $HZN_LISTEN_IP =~ ^(127.0.0.1|localhost|0.0.0.0)$ ]]; then
        THIS_HOST_LISTEN_IP=host.docker.internal  # so the agent in container can reach the host's localhost
        if ! grep -q -E '^127.0.0.1\s+host.docker.internal(\s|$)' /etc/hosts; then
            echo '127.0.0.1 host.docker.internal' >> /etc/hosts   # the hzn cmd needs to be able to use the same HZN_EXCHANGE_URL and resolve it
        fi
    else
        THIS_HOST_LISTEN_IP="$HZN_LISTEN_IP"
    fi
else   # ubuntu and redhat
    if [[ $HZN_LISTEN_IP == '0.0.0.0' ]]; then
        THIS_HOST_LISTEN_IP="127.0.0.1"
    else
        THIS_HOST_LISTEN_IP="$HZN_LISTEN_IP"
    fi
fi
mkdir -p /etc/default
cat << EOF > /etc/default/horizon
HZN_EXCHANGE_URL=${HZN_TRANSPORT}://${THIS_HOST_LISTEN_IP}:$EXCHANGE_PORT/v1
HZN_FSS_CSSURL=${HZN_TRANSPORT}://${THIS_HOST_LISTEN_IP}:$CSS_PORT/
HZN_AGBOT_URL=${HZN_TRANSPORT}://${THIS_HOST_LISTEN_IP}:$AGBOT_SECURE_PORT
HZN_FDO_SVC_URL=${HZN_TRANSPORT}://${THIS_HOST_LISTEN_IP}:$FDO_OWN_COMP_SVC_PORT/api
HZN_DEVICE_ID=$HZN_DEVICE_ID
ANAX_LOG_LEVEL=$ANAX_LOG_LEVEL
EOF

if [[ $HZN_TRANSPORT == 'https' ]]; then
    echo "HZN_MGMT_HUB_CERT_PATH=$CERT_DIR/$CERT_BASE_NAME.crt" >> /etc/default/horizon

    # Now that HZN_MGMT_HUB_CERT_PATH is in /etc/default/horizon, we can use hzn mms to put the certificate in CSS
    unset HZN_EXCHANGE_URL   # use the value in /etc/default/horizon
    putOneFileInCss $CERT_DIR/$CERT_BASE_NAME.crt agent-install.crt
fi

unset HZN_EXCHANGE_URL   # use the value in /etc/default/horizon

if [[ -z $OH_NO_AGENT ]]; then
    # start or restart the agent
    if isMacOS; then
        if isDockerContainerRunning horizon1; then
            echo "Restarting the Horizon agent container..."
            /usr/local/bin/horizon-container update
            chk $? 'restarting agent'
        else
            echo "Starting the Horizon agent container..."
            /usr/local/bin/horizon-container start
            chk $? 'starting agent'
        fi
    else   # ubuntu and redhat
        systemctl restart horizon.service
        chk $? 'restarting agent'
    fi
fi

# Add agent-install.cfg to CSS so agent-install.sh can be used to install edge nodes
if [[ $HZN_LISTEN_IP == '0.0.0.0' ]]; then
    CFG_LISTEN_IP=$(getPublicIp)   # the agent-install.cfg in CSS is mostly for other edge nodes, so need to try to give them a public ip
    if [[ -z $CFG_LISTEN_IP ]]; then
        echo "Warning: can not find a public IP on this host, so the agent-install.cfg file that will be added to CSS will not be usable outside of the this host. You can explicitly specify the public IP via HZN_LISTEN_PUBLIC_IP."
        CFG_LISTEN_IP='127.0.0.1'
    fi
else
    CFG_LISTEN_IP=$HZN_LISTEN_IP   # even if they are listening on a private IP, they can at least test agent-install.sh locally
fi
cat << EOF > $TMP_DIR/agent-install.cfg
HZN_EXCHANGE_URL=${HZN_TRANSPORT}://${CFG_LISTEN_IP}:$EXCHANGE_PORT/v1
HZN_FSS_CSSURL=${HZN_TRANSPORT}://${CFG_LISTEN_IP}:$CSS_PORT/
HZN_AGBOT_URL=${HZN_TRANSPORT}://${CFG_LISTEN_IP}:$AGBOT_SECURE_PORT
HZN_FDO_SVC_URL=${HZN_TRANSPORT}://${CFG_LISTEN_IP}:$FDO_OWN_COMP_SVC_PORT/api
EOF

if [[ $HZN_TRANSPORT == 'https' ]]; then
    echo "HZN_MGMT_HUB_CERT_PATH=$CERT_DIR/$CERT_BASE_NAME.crt" >> $TMP_DIR/agent-install.cfg
fi

putOneFileInCss $TMP_DIR/agent-install.cfg

if [[ ! -f "$HOME/.hzn/keys/service.private.key" || ! -f "$HOME/.hzn/keys/service.public.pem" ]]; then
    echo "Creating a Horizon developer key pair..."
    $HZN key create -f 'OpenHorizon' 'open-horizon@lfedge.org'   # Note: that is not a real email address yet
    chk $? 'creating developer key pair'
fi

if [[ -z $OH_NO_EXAMPLES ]]; then
    # Prime exchange with horizon examples
    printf "${CYAN}------- Installing Horizon example services, policies, and patterns...${NC}\n"
    export EXCHANGE_ROOT_PASS="$EXCHANGE_ROOT_PW"
    # HZN_EXCHANGE_USER_AUTH and HZN_ORG_ID are set in the section above
    export HZN_EXCHANGE_URL=${HZN_TRANSPORT}://${THIS_HOST_LISTEN_IP}:$EXCHANGE_PORT/v1
    rm -rf /tmp/open-horizon/examples   # exchangePublish.sh will clone the examples repo to here
    curl -sSL $OH_EXAMPLES_REPO/tools/exchangePublish.sh | bash -s -- -c $EXCHANGE_USER_ORG
    chk $? 'publishing examples'
fi
unset HZN_EXCHANGE_USER_AUTH HZN_ORG_ID HZN_EXCHANGE_URL   # need to set them differently for the registration below

if [[ -z $OH_NO_AGENT && -z $OH_NO_REGISTRATION ]]; then
    # Register the agent
    printf "${CYAN}------- Creating and registering the edge node with policy to run the helloworld Horizon example...${NC}\n"
    getUrlFile $OH_EXAMPLES_REPO/edge/services/helloworld/horizon/node.policy.json node.policy.json
    waitForAgent

    # if necessary unregister was done near the beginning of the script
    $HZN register -o $EXCHANGE_USER_ORG -u "admin:$EXCHANGE_USER_ADMIN_PW" -n "$HZN_DEVICE_ID:$HZN_DEVICE_TOKEN" --policy node.policy.json -s ibm.helloworld --serviceorg $EXCHANGE_SYSTEM_ORG -t 180
    chk $? 'registration'
fi

# Summarize
echo -e "\n----------- Summary of what was done:"
echo "  1. Started Horizon management hub services: Agbot, CSS, Exchange, FDO, Mongo DB, Postgres DB, Postgres DB FDO, Bao"
echo "  2. Created exchange resources: system organization (${EXCHANGE_SYSTEM_ORG}) admin user, user organization (${EXCHANGE_USER_ORG}) and admin user, and agbot"
if [[ $(( ${EXCHANGE_ROOT_PW_GENERATED:-0} + ${EXCHANGE_HUB_ADMIN_PW_GENERATED:-0} + ${EXCHANGE_SYSTEM_ADMIN_PW_GENERATED:-0} + ${AGBOT_TOKEN_GENERATED:-0} + ${EXCHANGE_USER_ADMIN_PW_GENERATED:-0} + ${HZN_DEVICE_TOKEN_GENERATED:-0} )) -gt 0 ]]; then
    echo "    Automatically generated these passwords/tokens:"
    if [[ -n $EXCHANGE_ROOT_PW_GENERATED ]]; then
        echo "      export EXCHANGE_ROOT_PW=$EXCHANGE_ROOT_PW"
        echo "      export HZN_ORG_ID=root"
        echo "      export HZN_EXCHANGE_USER_AUTH=root:$EXCHANGE_ROOT_PW"
    fi
    if [[ -n $EXCHANGE_HUB_ADMIN_PW_GENERATED ]]; then
        echo -e "\n      export EXCHANGE_HUB_ADMIN_PW=$EXCHANGE_HUB_ADMIN_PW"
        echo "      export HZN_ORG_ID=root"
        echo "      export HZN_EXCHANGE_USER_AUTH=hubadmin:$EXCHANGE_HUB_ADMIN_PW"
    fi
    if [[ -n $EXCHANGE_SYSTEM_ADMIN_PW_GENERATED ]]; then
        echo -e "\n      export EXCHANGE_SYSTEM_ADMIN_PW=$EXCHANGE_SYSTEM_ADMIN_PW"
        echo "      export HZN_ORG_ID=$EXCHANGE_SYSTEM_ORG"
        echo "      export HZN_EXCHANGE_USER_AUTH=admin:$EXCHANGE_SYSTEM_ADMIN_PW"
    fi
    if [[ -n $AGBOT_TOKEN_GENERATED ]]; then
        echo -e "\n      export AGBOT_TOKEN=$AGBOT_TOKEN"
        echo "      export HZN_ORG_ID=$EXCHANGE_SYSTEM_ORG"
        echo "      export HZN_EXCHANGE_USER_AUTH=$AGBOT_ID:$AGBOT_TOKEN"
    fi
    if [[ -n $EXCHANGE_USER_ADMIN_PW_GENERATED ]]; then
        echo -e "\n      export EXCHANGE_USER_ADMIN_PW=$EXCHANGE_USER_ADMIN_PW"
        echo "      export HZN_ORG_ID=$EXCHANGE_USER_ORG"
        echo "      export HZN_EXCHANGE_USER_AUTH=admin:$EXCHANGE_USER_ADMIN_PW"
    fi
    if [[ -n $HZN_DEVICE_TOKEN_GENERATED ]]; then
        echo -e "\n      export HZN_DEVICE_TOKEN=$HZN_DEVICE_TOKEN"
        echo "      export HZN_ORG_ID=$EXCHANGE_USER_ORG"
        echo "      export HZN_EXCHANGE_USER_AUTH=$HZN_DEVICE_ID:$HZN_DEVICE_TOKEN"
    fi

    echo -e "\n    Important: save these generated passwords/tokens in a safe place. You will not be able to query them from Horizon."
    echo "    Authentication to the Exchange is in the format <organization>/<identity>:<password> or \$HZN_ORG_ID/\$HZN_EXCHANGE_USER_AUTH."
fi
echo "  3. Installed and configured a PostgreSQL database instance for the Exchange. Important: save the generated user password in a safe place."
echo "       export POSTGRES_USER=$POSTGRES_USER"
echo "       export EXCHANGE_DB_PW=$EXCHANGE_DB_PW"
if [[ -z $OH_NO_AGENT ]]; then
    echo "  4. Installed and configured the Horizon agent and CLI (hzn)"
else   # only cli
    echo "  4. Installed and configured the Horizon CLI (hzn)"
fi
echo "  5. Created a Horizon developer key pair"
nextNum='6'
if [[ -z $OH_NO_EXAMPLES ]]; then
    echo "  $nextNum. Installed the Horizon examples"
    nextNum=$((nextNum+1))
fi
if [[ -z $OH_NO_AGENT && -z $OH_NO_REGISTRATION ]]; then
    echo "  $nextNum. Created and registered an edge node to run the helloworld example edge service"
    nextNum=$((nextNum+1))
fi
echo "  $nextNum. Created a bao instance: $HZN_BAO_URL/v1/sys/seal-status" # $HZN_BAO_URL/ui/bao/auth?with=token UI not available in Bao 2.x
echo "    Automatically generated this key/token:"
echo "      export BAO_UNSEAL_KEY=$BAO_UNSEAL_KEY"
echo "      export BAO_ROOT_TOKEN=$BAO_ROOT_TOKEN"
echo -e "\n    Important: save this generated key/token in a safe place. You will not be able to query them from Horizon."
nextNum=$((nextNum+1))
echo "  $nextNum. Created a FDO Owner Service instance."
echo "    Run test-fdo.sh to simulate the transfer of a device and automatic workload provisioning."
echo "    FDO Owner Service on port $FDO_OWN_SVC_PORT API credentials:"
echo "      export FDO_OWN_SVC_AUTH=$FDO_OWN_SVC_AUTH"
nextNum=$((nextNum+1))
echo "  $nextNum. Created and configured a PostgreSQL database instance for the FDO Owner Service. Important: save the generated user password in a safe place."
echo "        export FDO_OWN_SVC_DB_USER=$FDO_OWN_SVC_DB_USER"
echo "        export FDO_OWN_SVC_DB_PASSWORD=$FDO_OWN_SVC_DB_PASSWORD"
nextNum=$((nextNum+1))
echo -e "\n  $nextNum. Added the hzn auto-completion file to ~/.${SHELL##*/}rc (but you need to source that again for it to take effect in this shell session)"
if isMacOS && ! isDirInPath '/usr/local/bin'; then
    echo "Warning: /usr/local/bin is not in your path. Add it now, otherwise you will have to always full qualify the hzn and horizon-container commands."
fi

echo -e "\nFor what to do next, see: https://github.com/open-horizon/devops/blob/master/mgmt-hub/README.md#all-in-1-what-next"
if [[ -n $EXCHANGE_USER_ADMIN_PW_GENERATED ]]; then
    userAdminPw="$EXCHANGE_USER_ADMIN_PW"
else
    userAdminPw='$EXCHANGE_USER_ADMIN_PW'   # if they specified a pw, do not reveal it
fi
echo "Before running the commands in the What To Do Next section, copy/paste/run these commands in your terminal:"
echo "  export HZN_ORG_ID=$EXCHANGE_USER_ORG"
echo "  export HZN_EXCHANGE_USER_AUTH=admin:$userAdminPw"
