#!/bin/bash

# Deploy the management hub services (agbot, exchange, css, sdo, postgre, mongo), the agent, and the CLI on the current host.

usage() {
    exitCode=${1:-0}
    cat << EndOfMessage
Usage: ${0##*/} [-h] [-v] [-s | -u | -S | -r <container>] [-P]

Deploys the Open Horizon management hub services, agent, and CLI on this host. Currently only supported on Ubuntu 18.04 and macOS (the macOS support is experimental).

Flags:
  -S    Stop the management hub services and agent (instead of starting them). This flag is necessary instead of you simply running 'docker-compose down' because docker-compose.yml contains environment variables that must be set.
  -P    Purge (delete) the persistent volumes of the Horizon services and uninstall the Horizon agent. Can only be used with -S.
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

# Parse cmd line
while getopts ":SPsur:vh" opt; do
	case $opt in
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

# Default environment variables that can be overridden. Note: most of them have to be exported for envsubst for the template files.

# You have the option of specifying the exchange root pw: the clear value is only used in this script temporarily to prime the exchange.
# The bcrypted value can be created using the /admin/hashpw API of an existing exhange. It is stored in the exchange config file, which
# is needed each time the exchange starts. It will default to the clear pw, but that is less secure.
if [[ -z "$EXCHANGE_ROOT_PW" ]];then
    if [[ -n "$EXCHANGE_ROOT_PW_BCRYPTED" ]]; then
        # Can't specify EXCHANGE_ROOT_PW_BCRYPTED while having use generate a random EXCHANGE_ROOT_PW, because they won't match
        fatal 1 "can not specify EXCHANGE_ROOT_PW_BCRYPTED without also specifying the equivalent EXCHANGE_ROOT_PW"
    fi
    EXCHANGE_ROOT_PW_GENERATED=1
fi
generateToken() { cat /dev/urandom | env LC_CTYPE=C tr -dc 'a-zA-Z0-9' | fold -w $1 | head -n 1; }
export EXCHANGE_ROOT_PW=${EXCHANGE_ROOT_PW:-$(generateToken 30)}  # the clear exchange root pw, used temporarily to prime the exchange
export EXCHANGE_ROOT_PW_BCRYPTED=${EXCHANGE_ROOT_PW_BCRYPTED:-$EXCHANGE_ROOT_PW}  # we are not able to bcrypt it, so must use the clear pw when they do not specify their own exch root pw

# the password of the admin user in the system org. Defaults to a generated value that will be displayed at the end
if [[ -z "$EXCHANGE_SYSTEM_ADMIN_PW" ]]; then
    export EXCHANGE_SYSTEM_ADMIN_PW=$(generateToken 30)
    EXCHANGE_SYSTEM_ADMIN_PW_GENERATED=1
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

export HZN_LISTEN_IP=${HZN_LISTEN_IP:-127.0.0.1}   # the host IP address the hub services should listen on. Can be set to 0.0.0.0 to mean all interfaces, including the public IP, altho this is not recommended, since the services use http.
export HZN_TRANSPORT=${HZN_TRANSPORT:-http}

export EXCHANGE_IMAGE_TAG=${EXCHANGE_IMAGE_TAG:-latest}   # or can be set to stable or a specific version
export EXCHANGE_PORT=${EXCHANGE_PORT:-3090}
export EXCHANGE_LOG_LEVEL=${EXCHANGE_LOG_LEVEL:-INFO}
export EXCHANGE_SYSTEM_ORG=${EXCHANGE_SYSTEM_ORG:-IBM}   # the name of the system org (which contains the example services and patterns). Currently this can not be overridden
export EXCHANGE_USER_ORG=${EXCHANGE_USER_ORG:-myorg}   # the name of the org which you will use to create nodes, service, patterns, and deployment policies
export EXCHANGE_WAIT_ITERATIONS=${EXCHANGE_WAIT_ITERATIONS:-30}
export EXCHANGE_WAIT_INTERVAL=${EXCHANGE_WAIT_INTERVAL:-2}   # number of seconds to sleep between iterations

export AGBOT_IMAGE_TAG=${AGBOT_IMAGE_TAG:-latest}   # or can be set to stable or a specific version
export AGBOT_PORT=${AGBOT_PORT:-3091}
export AGBOT_ID=${AGBOT_ID:-agbot}   # its agbot id in the exchange

export CSS_IMAGE_TAG=${CSS_IMAGE_TAG:-latest}   # or can be set to stable or a specific version
export CSS_PORT=${CSS_PORT:-9443}

export POSTGRES_IMAGE_TAG=${POSTGRES_IMAGE_TAG:-latest}   # or can be set to stable or a specific version
export POSTGRES_PORT=${POSTGRES_PORT:-5432}
export POSTGRES_USER=${POSTGRES_USER:-admin}
export EXCHANGE_DATABASE=${EXCHANGE_DATABASE:-exchange}   # the db the exchange uses in the postgres instance
export AGBOT_DATABASE=${AGBOT_DATABASE:-exchange}   #todo: figure out how to get 2 different databases created in postgres. The db the agbot uses in the postgres instance

export MONGO_IMAGE_TAG=${MONGO_IMAGE_TAG:-latest}   # or can be set to stable or a specific version
export MONGO_PORT=${MONGO_PORT:-27017}

export SDO_IMAGE_TAG=${SDO_IMAGE_TAG:-latest}   # or can be set to stable, testing, or a specific version
export SDO_OCS_API_PORT=${SDO_OCS_API_PORT:-9008}
export SDO_RV_PORT=${SDO_RV_PORT:-8040}
export SDO_OPS_PORT=${SDO_OPS_PORT:-8042}   # the port OPS should listen on *inside* the container
export SDO_OPS_EXTERNAL_PORT=${SDO_OPS_EXTERNAL_PORT:-$SDO_OPS_PORT}   # the external port the device should use to contact OPS
export SDO_OCS_DB_PATH=${SDO_OCS_DB_PATH:-/home/sdouser/ocs/config/db}
export AGENT_INSTALL_URL=${AGENT_INSTALL_URL:-https://github.com/open-horizon/anax/releases/latest/download/agent-install.sh}
# Note: in this environment, we are not supporting letting them specify their own owner key pair

export AGENT_WAIT_ITERATIONS=${AGENT_WAIT_ITERATIONS:-15}
export AGENT_WAIT_INTERVAL=${AGENT_WAIT_INTERVAL:-2}   # number of seconds to sleep between iterations

export COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-hzn}

export HC_DOCKER_TAG=${HC_DOCKER_TAG:-testing}   # when using the anax-in-container agent

OH_DEVOPS_REPO=${OH_DEVOPS_REPO:-https://raw.githubusercontent.com/open-horizon/devops/master}
OH_ANAX_RELEASES=${OH_ANAX_RELEASES:-https://github.com/open-horizon/anax/releases/latest/download}
OH_ANAX_MAC_PKG_TAR=${OH_ANAX_MAC_PKG_TAR:-horizon-agent-macos-pkg-x86_64.tar.gz}
OH_ANAX_DEB_PKG_TAR=${OH_ANAX_DEB_PKG_TAR:-horizon-agent-linux-deb-amd64.tar.gz}
OH_ANAX_RPM_PKG_TAR=${OH_ANAX_RPM_PKG_TAR:-horizon-agent-linux-rpm-x86_64.tar.gz}   # not used/supported yet
OH_EXAMPLES_REPO=${OH_EXAMPLES_REPO:-https://raw.githubusercontent.com/open-horizon/examples/master}

HZN_DEVICE_ID=${HZN_DEVICE_ID:-node1}   # the edge node id you want to use

# Global variables for this script (not intended to be overridden)
TMP_DIR=/tmp/horizon
mkdir -p $TMP_DIR
CURL_OUTPUT_FILE=$TMP_DIR/curlExchangeOutput
CURL_ERROR_FILE=$TMP_DIR/curlExchangeErrors
SYSTEM_TYPE=${SYSTEM_TYPE:-$(uname -s)}
DISTRO=${DISTRO:-$(lsb_release -d 2>/dev/null | awk '{print $2" "$3}')}

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
    local goodHttpCodes=$3   # space or comma separate list of acceptable http codes
    local task=$4
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

isUbuntu18() {
    if [[ "$DISTRO" == 'Ubuntu 18.'* ]]; then
		return 0
	else
		return 1
	fi
}

isDirInPath() {
    local dir="$1"
    echo $PATH | grep -q -E "(^|:)$dir(:|$)"
}

isDockerContainerRunning() {
    local container="$1"
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
        output=$($* 2>&1)
        if [[ $? -ne 0 ]]; then
            echo "Error running $*: $output"
            exit 2
        fi
    fi
}

# Returns exit code 0 if the specified cmd is in the path
isCmdInstalled() {
    local cmd=$1
    command -v $cmd >/dev/null 2>&1
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
    : ${1:?}
    local minVersion=$1
    if ! command -v docker-compose >/dev/null 2>&1; then
        return 1   # it is not even installed
    fi
    # docker-compose is installed, check its version
    lowerVersion=$(echo -e "$(docker-compose version --short)\n$minVersion" | sort -V | head -n1)
    if [[ $lowerVersion == $minVersion ]]; then
        return 0   # the installed version was >= minVersion
    else
        return 1
    fi
}

# Verify that the prereq commands we need are installed, or exist with error msg
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
    local url="$1"
    local localFile="$2"
    verbose "Downloading $url ..."
    if [[ $url == *@* ]]; then
        # special case for development:
        scp $url $localFile
        chk $? "scp'ing $url"
    else
        httpCode=$(curl -sS -w "%{http_code}" -L -o $localFile $url 2>$CURL_ERROR_FILE)
        chkHttp $? $httpCode 200 "downloading $url" $CURL_ERROR_FILE $localFile
    fi
}

# Pull all of the docker images to ensure we have the most recent images locally
pullImages() {
    # Even though docker-compose will pull these, it won't pull again if it already has a local copy of the tag but it has been updated on docker hub
    echo "Pulling openhorizon/amd64_agbot:${AGBOT_IMAGE_TAG}..."
    runCmdQuietly docker pull openhorizon/amd64_agbot:${AGBOT_IMAGE_TAG}
    echo "Pulling openhorizon/amd64_exchange-api:${EXCHANGE_IMAGE_TAG}..."
    runCmdQuietly docker pull openhorizon/amd64_exchange-api:${EXCHANGE_IMAGE_TAG}
    echo "Pulling openhorizon/amd64_cloud-sync-service:${CSS_IMAGE_TAG}..."
    runCmdQuietly docker pull openhorizon/amd64_cloud-sync-service:${CSS_IMAGE_TAG}
    echo "Pulling postgres:${POSTGRES_IMAGE_TAG}..."
    runCmdQuietly docker pull postgres:${POSTGRES_IMAGE_TAG}
    echo "Pulling mongo:${MONGO_IMAGE_TAG}..."
    runCmdQuietly docker pull mongo:${MONGO_IMAGE_TAG}
    echo "Pulling openhorizon/sdo-owner-services:${SDO_IMAGE_TAG}..."
    runCmdQuietly docker pull openhorizon/sdo-owner-services:${SDO_IMAGE_TAG}
}

# Find 1 of the private IPs of the host
getPrivateIp() {
    if isMacOS; then ipCmd=ifconfig
    else ipCmd='ip address'; fi
    $ipCmd | grep -m 1 -o -E "\sinet (172|10|192.168)[^/\s]*" | awk '{ print $2 }'
}

# Set distro-dependent variables
if isMacOS; then
    HZN=/usr/local/bin/hzn   # this is where the mac horizon-cli pkg puts it
    export ETC=/private/etc
    export VOLUME_MODE=cached   # supposedly helps avoid 100% cpu consumption bug https://github.com/docker/for-mac/issues/3499
else   # ubuntu
    HZN=hzn   # this deb horizon-cli pkg puts it in /usr/bin so it is always in the path
    export ETC=/etc
    export VOLUME_MODE=ro
fi

#====================== Start/Stop Utilities ======================
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
    # Unregister if necessary
    if [[ $($HZN node list 2>&1 | jq -r '.configstate.state' 2>&1) == 'configured' ]]; then
        $HZN unregister -f
        chk $? 'unregistration'
    fi
    echo "Stopping the Horizon agent..."
    if isMacOS; then
        /usr/local/bin/horizon-container stop
        # we don't currently have a way to uninstall the horizon and horizon-cli mac pkgs
    else   # ubuntu
        systemctl stop horizon
        if [[ -n "$PURGE" ]]; then
            echo "Uninstalling the Horizon agent..."
            runCmdQuietly apt-get purge -yq horizon horizon-cli
        fi
    fi

    if [[ -n "$PURGE" ]]; then
        echo "Stopping Horizon management hub services and deleting their persistent volumes..."
        purgeFlag='--volumes'
    else
        echo "Stopping Horizon management hub services..."
    fi
    docker-compose down $purgeFlag

    if [[ -n "$PURGE" ]]; then
        echo "Removing Open-horizon Docker images"
        runCmdQuietly docker rmi '$(docker images openhorizon/* -q)'
    fi
    
    exit
fi

# Start the mgmt hub services and agent (use existing configuration)
if [[ -n "$START" ]]; then
    echo "Starting management hub containers..."
    pullImages
    docker-compose up -d --no-build
    chk $? 'starting docker-compose services'

    echo "Starting the Horizon agent..."
    if isMacOS; then
        /usr/local/bin/horizon-container start
    else   # ubuntu
        systemctl start horizon
    fi
    exit
fi

# Run 'docker-compose up ...' again so any mgmt hub containers will be updated
if [[ -n "$UPDATE" ]]; then
    echo "Updating management hub containers..."
    pullImages
    docker-compose up -d --no-build
    chk $? 'updating docker-compose services'
    exit
fi

# Restart 1 mgmt hub container
if [[ -n "$RESTART" ]]; then
    if [[ $(( ${START:-0} + ${STOP:-0} + ${UPDATE:-0} )) -gt 0 ]]; then
        fatal 1 "-s or -S or -u cannot be specified with -r"
    fi
    echo "Restarting the $RESTART container..."
    docker-compose restart -t 10 "$RESTART"
    exit
fi

#====================== Main Deployment Code ======================

# Initial checking of the input and OS
echo "----------- Verifying input and the host OS..."
if [[ -z "$EXCHANGE_ROOT_PW" || -z "$EXCHANGE_ROOT_PW_BCRYPTED" ]]; then
    fatal 1 "these environment variables must be set: EXCHANGE_ROOT_PW, EXCHANGE_ROOT_PW_BCRYPTED"
fi
ensureWeAreRoot
if ! isMacOS && ! isUbuntu18; then
    fatal 1 "the host must be Ubuntu 18.x or macOS"
fi
confirmCmds grep awk curl   # these should be automatically available on all the OSes we support
echo "Management hub services will listen on $HZN_LISTEN_IP"

# Install jq envsubst (gettext-base) docker docker-compose
if isMacOS; then
    # we can't install docker* for them
    if ! isCmdInstalled docker || ! isCmdInstalled docker-compose; then
        fatal 2 "you must install docker before running this script: https://docs.docker.com/docker-for-mac/install"
    fi
    if ! areCmdsInstalled jq envsubst; then
        if isCmdInstalled brew; then
            echo "Installing prerequisites using brew, this could take a minute..."
            runCmdQuietly brew install jq gettext
        else
            fatal 2 "the commands jq and envsubst are required, and since brew is not installed, we can not install them for you"
        fi
    fi
else   # ubuntu
    echo "Updating apt package index..."
    runCmdQuietly apt-get update -q
    echo "Installing prerequisites, this could take a minute..."
    runCmdQuietly apt-get install -yqf jq gettext-base make

    # If docker isn't installed, do that
    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker is required, installing it..."
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
        chk $? 'adding docker repository key'
        add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        chk $? 'adding docker repository'
        apt-get install -y docker-ce docker-ce-cli containerd.io
        chk $? 'installing docker'
    fi

    minVersion=1.21.0
    if ! isDockerComposeAtLeast $minVersion; then
        if [[ -f '/usr/bin/docker-compose' ]]; then
            echo "Error: Need at least docker-compose $minVersion. A down-level version is currently installed, preventing us from installing the latest version. Uninstall docker-compose and rerun this script."
            exit 2
        fi
        echo "docker-compose is not installed or not at least version $minVersion, installing/upgrading it..."
        # Install docker-compose from its github repo, because that is the only way to get a recent enough version
        curl --progress-bar -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chk $? 'downloading docker-compose'
        chmod +x /usr/local/bin/docker-compose
        chk $? 'making docker-compose executable'
        ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
        chk $? 'linking docker-compose to /usr/bin'
    fi
fi

# Download and process templates from open-horizon/devops
if [[ $OH_DEVOPS_REPO == 'dontdownload' ]]; then
    echo "Skipping download of template files..."
else
    echo "----------- Downloading template files..."
    getUrlFile $OH_DEVOPS_REPO/mgmt-hub/docker-compose.yml docker-compose.yml
    getUrlFile $OH_DEVOPS_REPO/mgmt-hub/exchange-tmpl.json $TMP_DIR/exchange-tmpl.json
    getUrlFile $OH_DEVOPS_REPO/mgmt-hub/agbot-tmpl.json $TMP_DIR/agbot-tmpl.json
    getUrlFile $OH_DEVOPS_REPO/mgmt-hub/css-tmpl.conf $TMP_DIR/css-tmpl.conf
    # leave a copy of ourself in the current dir for subsequent stop/start commands
    if [[ ! -f 'deploy-mgmt-hub.sh' ]]; then   # do not overwrite ourself if already here
        getUrlFile $OH_DEVOPS_REPO/mgmt-hub/deploy-mgmt-hub.sh deploy-mgmt-hub.sh
        chmod +x deploy-mgmt-hub.sh
    fi
    # also leave a copy of test-sdo.sh so they can run that afterward if they want to take SDO for a spin
    getUrlFile $OH_DEVOPS_REPO/mgmt-hub/test-sdo.sh test-sdo.sh
    chmod +x test-sdo.sh
fi

echo "Substituting environment variables into template files..."
export ENVSUBST_DOLLAR_SIGN='$'   # needed for essentially escaping $, because we need to let the exchange itself replace $EXCHANGE_ROOT_PW_BCRYPTED
mkdir -p /etc/horizon   # putting the config files here because they are mounted long-term into the containers
cat $TMP_DIR/exchange-tmpl.json | envsubst > /etc/horizon/exchange.json
cat $TMP_DIR/agbot-tmpl.json | envsubst > /etc/horizon/agbot.json
cat $TMP_DIR/css-tmpl.conf | envsubst > /etc/horizon/css.conf
chmod a+r /etc/horizon/*

# Start mgmt hub services
echo "----------- Downloading/starting Horizon management hub services..."
echo "Downloading management hub docker images..."
# Even though docker-compose will pull these, it won't pull again if it already has a local copy of the tag but it has been updated on docker hub
pullImages

echo "Starting management hub containers..."
docker-compose up -d --no-build
chk $? 'starting docker-compose services'

# Ensure the exchange is responding
# Note: wanted to make these aliases to avoid quote/space problems, but aliases don't get inherited to sub-shells. But variables don't get processed again by the shell (but may get separated by spaces), so i think we are ok for the post/put data
HZN_EXCHANGE_URL=http://$HZN_LISTEN_IP:$EXCHANGE_PORT/v1
exchangeGet() {
    curl -sS -w "%{http_code}" -u "root/root:$EXCHANGE_ROOT_PW" -o $CURL_OUTPUT_FILE $* 2>$CURL_ERROR_FILE
}
exchangePost() {
    curl -sS -w "%{http_code}" -u "root/root:$EXCHANGE_ROOT_PW" -o $CURL_OUTPUT_FILE -H Content-Type:application/json -X POST $* 2>$CURL_ERROR_FILE
}
exchangePut() {
    curl -sS -w "%{http_code}" -u "root/root:$EXCHANGE_ROOT_PW" -o $CURL_OUTPUT_FILE -H Content-Type:application/json -X PUT $* 2>$CURL_ERROR_FILE
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
echo "----------- Creating the user org, the admin user in both orgs, and an agbot in the exchange..."

# Create admin user in system org
echo "Creating exchange admin user and agbot in the system org..."
if [[ $(exchangeGet $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/users/admin) != 200 ]]; then
    httpCode=$(exchangePost -d "{\"password\":\"$EXCHANGE_SYSTEM_ADMIN_PW\",\"admin\":true,\"email\":\"not@used\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/users/admin)
    chkHttp $? $httpCode 201 "creating /orgs/$EXCHANGE_SYSTEM_ORG/users/admin" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
else
    # Set the pw to be what they specified this time
    httpCode=$(exchangePost -d "{\"newPassword\":\"$EXCHANGE_SYSTEM_ADMIN_PW\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/users/admin/changepw)
    chkHttp $? $httpCode 201 "changing pw of /orgs/$EXCHANGE_SYSTEM_ORG/users/admin" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
fi

# Create or update the agbot in the system org, and configure it with the pattern and deployment policy orgs
httpCode=$(exchangePut -d "{\"token\":\"$AGBOT_TOKEN\",\"name\":\"agbot\",\"publicKey\":\"\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/agbots/agbot)
chkHttp $? $httpCode 201 "creating/updating /orgs/$EXCHANGE_SYSTEM_ORG/agbots/agbot" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
httpCode=$(exchangePost -d "{\"patternOrgid\":\"$EXCHANGE_SYSTEM_ORG\",\"pattern\":\"*\",\"nodeOrgid\":\"$EXCHANGE_USER_ORG\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/agbots/agbot/patterns)
chkHttp $? $httpCode 201,409 "adding /orgs/$EXCHANGE_SYSTEM_ORG/agbots/agbot/patterns" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
httpCode=$(exchangePost -d "{\"patternOrgid\":\"$EXCHANGE_USER_ORG\",\"pattern\":\"*\",\"nodeOrgid\":\"$EXCHANGE_USER_ORG\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/agbots/agbot/patterns)
chkHttp $? $httpCode 201,409 "adding /orgs/$EXCHANGE_SYSTEM_ORG/agbots/agbot/patterns" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
httpCode=$(exchangePost -d "{\"businessPolOrgid\":\"$EXCHANGE_USER_ORG\",\"businessPol\":\"*\",\"nodeOrgid\":\"$EXCHANGE_USER_ORG\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/agbots/agbot/businesspols)
chkHttp $? $httpCode 201,409 "adding /orgs/$EXCHANGE_SYSTEM_ORG/agbots/agbot/businesspols" $CURL_ERROR_FILE $CURL_OUTPUT_FILE

# Create the user org and an admin user within it
echo "Creating exchange user org and admin user..."
if [[ $(exchangeGet $HZN_EXCHANGE_URL/orgs/$EXCHANGE_USER_ORG) != 200 ]]; then
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
echo "----------- Downloading/installing Horizon agent and CLI..."
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
else   # ubuntu
    getUrlFile $OH_ANAX_RELEASES/$OH_ANAX_DEB_PKG_TAR $TMP_DIR/pkgs/$OH_ANAX_DEB_PKG_TAR
    tar -zxf $TMP_DIR/pkgs/$OH_ANAX_DEB_PKG_TAR -C $TMP_DIR/pkgs   # will extract files like: horizon-cli_2.27.0_amd64.deb
    chk $? 'extracting pkg tar file'
    echo "Installing the Horizon agent and CLI packages..."
    runCmdQuietly apt-get install -yqf $TMP_DIR/pkgs/horizon*.deb
fi

# Configure the agent/CLI
echo "Configuring the Horizon agent and CLI..."
if isMacOS; then
    if [[ $HZN_LISTEN_IP == '127.0.0.1' || $HZN_LISTEN_IP == 'localhost' ]]; then
        MODIFIED_LISTEN_IP=host.docker.internal  # so the agent in container can reach the host's localhost
        if ! grep -q -E '^127.0.0.1\s+host.docker.internal(\s|$)' /etc/hosts; then
            echo '127.0.0.1 host.docker.internal' >> /etc/hosts   # the hzn cmd needs to be able to use the same HZN_EXCHANGE_URL and resolve it
        fi
    else
        MODIFIED_LISTEN_IP="$HZN_LISTEN_IP"
    fi
else   # ubuntu
    MODIFIED_LISTEN_IP="$HZN_LISTEN_IP"
fi
mkdir -p /etc/default
cat << EOF > /etc/default/horizon
HZN_EXCHANGE_URL=http://${MODIFIED_LISTEN_IP}:$EXCHANGE_PORT/v1
HZN_FSS_CSSURL=http://${MODIFIED_LISTEN_IP}:$CSS_PORT/
HZN_DEVICE_ID=$HZN_DEVICE_ID
EOF

unset HZN_EXCHANGE_URL   # use the value in /etc/default/horizon

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
else   # ubuntu
    systemctl restart horizon.service
    chk $? 'restarting agent'
fi

# Prime exchange with horizon examples
echo "----------- Creating developer key pair, and installing Horizon example services, policies, and patterns..."
export EXCHANGE_ROOT_PASS="$EXCHANGE_ROOT_PW"
export HZN_EXCHANGE_USER_AUTH="root/root:$EXCHANGE_ROOT_PW"
export HZN_ORG_ID=$EXCHANGE_SYSTEM_ORG
export HZN_EXCHANGE_URL=http://${MODIFIED_LISTEN_IP}:$EXCHANGE_PORT/v1
if [[ ! -f "$HOME/.hzn/keys/service.private.key" || ! -f "$HOME/.hzn/keys/service.public.pem" ]]; then
    $HZN key create -f 'OpenHorizon' 'open-horizon@lfedge.org'   # Note: that is not a real email address yet
    chk $? 'creating developer key pair'
fi
rm -rf /tmp/open-horizon/examples   # exchangePublish.sh will clone the examples repo to here
curl -sSL $OH_EXAMPLES_REPO/tools/exchangePublish.sh | bash -s -- -c $EXCHANGE_USER_ORG
chk $? 'publishing examples'
unset HZN_EXCHANGE_USER_AUTH HZN_ORG_ID HZN_EXCHANGE_URL   # need to set them differently for the registration below

# Register the agent
echo "----------- Creating and registering the edge node with policy to run the helloworld Horizon example..."
getUrlFile $OH_EXAMPLES_REPO/edge/services/helloworld/horizon/node.policy.json node.policy.json

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
    numSeconds=$(( $AGENT_WAIT_ITERATIONS * $AGENT_WAIT_INTERVAL ))
    fatal 6 "can not reach the agent (tried for $numSeconds seconds): $(cat $CURL_ERROR_FILE 2>/dev/null)"
fi

# if they previously registered, then unregister
if [[ $($HZN node list 2>&1 | jq -r '.configstate.state' 2>&1) == 'configured' ]]; then
    $HZN unregister -f
    chk $? 'unregistration'
fi
$HZN register -o $EXCHANGE_USER_ORG -u "admin:$EXCHANGE_USER_ADMIN_PW" -n "$HZN_DEVICE_ID:$HZN_DEVICE_TOKEN" --policy node.policy.json -s ibm.helloworld --serviceorg $EXCHANGE_SYSTEM_ORG -t 100
chk $? 'registration'

# Summarize
echo -e "\n----------- Summary of what was done:"
echo "  1. Started Horizon management hub services: agbot, exchange, postgres DB, CSS, mongo DB"
echo "  2. Created exchange resources: system org ($EXCHANGE_SYSTEM_ORG) admin user, user org ($EXCHANGE_USER_ORG) and admin user, and agbot"
if [[ -n $EXCHANGE_ROOT_PW_GENERATED ]]; then
    echo "     - Exchange root user generated password: $EXCHANGE_ROOT_PW"
fi
if [[ -n $EXCHANGE_SYSTEM_ADMIN_PW_GENERATED ]]; then
    echo "     - System org admin user generated password: $EXCHANGE_SYSTEM_ADMIN_PW"
fi
if [[ -n $AGBOT_TOKEN_GENERATED ]]; then
    echo "     - Agbot generated token: $AGBOT_TOKEN"
fi
if [[ -n $EXCHANGE_USER_ADMIN_PW_GENERATED ]]; then
    echo "     - User org admin user generated password: $EXCHANGE_USER_ADMIN_PW"
fi
if [[ -n $HZN_DEVICE_TOKEN_GENERATED ]]; then
    echo "     - Node generated token: $HZN_DEVICE_TOKEN"
fi
if [[ $(( ${EXCHANGE_ROOT_PW_GENERATED:-0} + ${EXCHANGE_SYSTEM_ADMIN_PW_GENERATED:-0} + ${AGBOT_TOKEN_GENERATED:-0} + ${EXCHANGE_USER_ADMIN_PW_GENERATED:-0} + ${HZN_DEVICE_TOKEN_GENERATED:-0} )) -gt 0 ]]; then
    echo "     Important: save these generated passwords/tokens in a safe place. You will not be able to query them from Horizon."
fi
echo "  3. Installed the Horizon agent and CLI (hzn)"
echo "  4. Created a Horizon developer key pair"
echo "  5. Installed the Horizon examples"
echo "  6. Created and registered an edge node to run the helloworld example edge service"
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
echo " export HZN_ORG_ID=$EXCHANGE_USER_ORG"
echo " export HZN_EXCHANGE_USER_AUTH=admin:$userAdminPw"
