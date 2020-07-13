#!/bin/bash

# Deploy the management hub services (agbot, exchange, css, postgre, mongo), the agent, and the CLI

generateToken() { cat /dev/urandom | env LC_CTYPE=C tr -dc 'a-zA-Z0-9' | fold -w $1 | head -n 1; }

# Default environment variables. Note: most of them have to be exported for envsubst for the template files.

# You have the option of specifying the exchange root pw: the clear value is only used in this script temporarily to prime the exchange.
# The bcrypted value can be created using the /admin/hashpw API of an existing exhange. It is stored in the exchange config file, which
# is needed each time the exchange starts. It will default to the clear pw, but that is less secure.
if [[ -z "$EXCHANGE_ROOT_PW" ]];then
    if [[ -n "$EXCHANGE_ROOT_PW_BCRYPTED" ]]; then
        # Can't specify EXCHANGE_ROOT_PW_BCRYPTED while having use generate a random EXCHANGE_ROOT_PW, because they won't match
        fatal 1 "can not specify EXCHANGE_ROOT_PW_BCRYPTED without also specifying the equivalent EXCHANGE_ROOT_PW"
    fi
    EXCHANGE_ROOT_PW_GENERATED=true
fi
export EXCHANGE_ROOT_PW=${EXCHANGE_ROOT_PW:-$(generateToken 30)}  # the clear exchange root pw, used temporarily to prime the exchange
export EXCHANGE_ROOT_PW_BCRYPTED=${EXCHANGE_ROOT_PW_BCRYPTED:-$EXCHANGE_ROOT_PW}  # we are not able to bcrypt it, so must use the clear pw when they do not specify their own exch root pw

# the password of the admin user in the system org. Defaults to a generated value that will be displayed at the end
if [[ -z "$EXCHANGE_SYSTEM_ADMIN_PW" ]]; then
    export EXCHANGE_SYSTEM_ADMIN_PW=$(generateToken 30)
    EXCHANGE_SYSTEM_ADMIN_PW_GENERATED=true
fi
# the system org agbot token. Defaults to a generated value that will be displayed at the end
if [[ -z "$AGBOT_TOKEN" ]]; then
    export AGBOT_TOKEN=$(generateToken 30)
    AGBOT_TOKEN_GENERATED=true
fi
# the password of the admin user in the user org. Defaults to a generated value that will be displayed at the end
if [[ -z "$EXCHANGE_USER_ADMIN_PW" ]]; then
    export EXCHANGE_USER_ADMIN_PW=$(generateToken 30)
    EXCHANGE_USER_ADMIN_PW_GENERATED=true
fi
# the node token. Defaults to a generated value that will be displayed at the end
if [[ -z "$HZN_DEVICE_TOKEN" ]]; then
    export HZN_DEVICE_TOKEN=$(generateToken 30)
    HZN_DEVICE_TOKEN_GENERATED=true
fi

export HZN_LISTEN_IP=${HZN_LISTEN_IP:-127.0.0.1}   # the host IP address the hub services should listen on. Can be set to 0.0.0.0 to mean all interfaces, including the public IP, altho this is not recommended, since the services use http.
export HZN_TRANSPORT=${HZN_TRANSPORT:-http}

export EXCHANGE_IMAGE_TAG=${EXCHANGE_IMAGE_TAG:-latest}   # or can be set to stable or a specific version
export EXCHANGE_PORT=${EXCHANGE_PORT:-3090}
export EXCHANGE_LOG_LEVEL=${EXCHANGE_LOG_LEVEL:-INFO}
export EXCHANGE_SYSTEM_ORG=${EXCHANGE_SYSTEM_ORG:-IBM}   # the name of the system org (which contains the example services and patterns). Currently this can not be overridden
export EXCHANGE_USER_ORG=${EXCHANGE_USER_ORG:-myorg}   # the name of the org which you will use to create nodes, service, patterns, and deployment policies
export EXCHANGE_WAIT_ITERATIONS=${EXCHANGE_WAIT_ITERATIONS:-10}
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

export COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-hzn}

export HC_DOCKER_TAG=${HC_DOCKER_TAG:-testing}   # when using the anax-in-container agent

OH_DEVOPS_REPO=${OH_DEVOPS_REPO:-https://raw.githubusercontent.com/open-horizon/devops/master}
OH_DEVOPS_RELEASES=${OH_DEVOPS_RELEASES:-https://github.com/open-horizon/devops/releases/latest/download}   #todo: change this to anax repo
OH_EXAMPLES_REPO=${OH_EXAMPLES_REPO:-https://raw.githubusercontent.com/open-horizon/examples/master}

HZN_DEVICE_ID=${HZN_DEVICE_ID:-node1}   # the edge node id you want to use

usage() {
    exitCode=${1:-0}
    cat << EndOfMessage
Usage: ${0##*/} [-h] [-v] [-s | -r <container>] [-p]

Deploys the Open Horizon management hub services, agent, and CLI on this host. Currently only supported on Ubuntu 18.04 and macOS.

Flags:
  -s    Shut down the management hub services (instead of starting them). This is necessary instead of you simply running 'docker-compose down' because docker-compose.yml contains environment variables that must be set.
  -p    Purge (delete) the persistent volumes of the Horizon services. Can only be used with -s.
  -r <container>   Have docker-compose restart the specified container.
  -v    Verbose output.
  -h    Show this usage.

Optional Environment Variables:
  For a list of optional environment variables, their defaults and descriptions, see the beginning of this script.
EndOfMessage
    exit $exitCode
}

TMP_DIR=/tmp/horizon
mkdir -p $TMP_DIR
CURL_OUTPUT_FILE=$TMP_DIR/curlExchangeOutput
CURL_ERROR_FILE=$TMP_DIR/curlExchangeErrors
HZN_EXCHANGE_URL=http://localhost:$EXCHANGE_PORT/v1
SYSTEM_TYPE=${SYSTEM_TYPE:-$(uname -s)}
DISTRO=${DISTRO:-$(lsb_release -d 2>/dev/null | awk '{print $2" "$3}')}

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
    local dontExit=$6   # optional: set to 'continue' to not exit for this error
    chk $exitCode $task
    if [[ -n $httpCode && $goodHttpCodes == *$httpCode* ]]; then return; fi
    if [[ -n $errorFile && -f $errorFile ]]; then
        echo "Error: http code $httpCode from: $task: $(cat $errorFile)"
    else
        echo "Error: http code $httpCode from: $task"
    fi
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
    echo $PATH | grep -E "(^|:)$dir(:|$)"
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
        chkHttp $? $httpCode 200 "downloading $url" $CURL_ERROR_FILE
    fi
}

# Find 1 of the private IPs of the host
getPrivateIp() {
    if isMacOS; then ipCmd=ifconfig
    else ipCmd='ip address'; fi
    $ipCmd | grep -m 1 -o -E "\sinet (172|10|192.168)[^/\s]*" | awk '{ print $2 }'
}

# Parse cmd line
while getopts ":r:hsp" opt; do
	case $opt in
		h)  usage
		    ;;
		v)  VERBOSE=true
		    ;;
		s)  STOP=true
		    ;;
		p)  PURGE=true
		    ;;
		r)  RESTART="$OPTARG"
		    ;;
		\?) echo "Error: invalid option: -$OPTARG"; usage 1
		    ;;
		:)  echo "Error: option -$OPTARG requires an argument"; usage 1
		    ;;
	esac
done

# Set distro-dependent variables
if isMacOS; then
    HZN=/usr/local/bin/hzn
    export ETC=/private/etc
else   # ubuntu
    HZN=hzn
    export ETC=/etc
fi

# Special cases: they want to bring down the mgmt hub or restart a service
# Note: we need to provide this because the env vars referenced in docker-compose.yml need to be set
if [[ "$STOP" == 'true' && -n "$RESTART" ]]; then
    fatal 1 "can not specify both -s and -r"
fi

if [[ "$PURGE" == 'true' && "$STOP" != 'true' ]]; then
    fatal 1 "-p can only be used with -s"
fi

if [[ "$STOP" == 'true' ]]; then
    # Unregister if necessary
    if [[ $($HZN node list 2>&1 | jq -r '.configstate.state' 2>&1) == 'configured' ]]; then
        $HZN unregister -f
        chk $? 'unregistration'
    fi
    echo "Stopping the Horizon agent..."
    if isMacOS; then
        /usr/local/bin/horizon-container stop
    else   # ubuntu
        systemctl stop horizon
    fi

    if [[ "$PURGE" == 'true' ]]; then
        echo "Stopping Horizon management hub services and deleting their persistent volumes..."
        purgeFlag='--volumes'
    else
        echo "Stopping Horizon management hub services..."
    fi
    docker-compose down $purgeFlag
    exit
fi

if [[ -n "$RESTART" ]]; then
    echo "Restarting the $RESTART container..."
    docker-compose restart -t 10 "$RESTART"
    exit
fi

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
echo "Manaagement hub services will listen on $HZN_LISTEN_IP"

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
    runCmdQuietly apt-get install -yqf jq gettext-base make docker-compose
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
fi

echo "Substituting environment variables into template files..."
export ENVSUBST_DOLLAR_SIGN='$'   # needed for essentially escaping $, because we need to let the exchange itself replace $EXCHANGE_ROOT_PW_BCRYPTED
if isMacOS; then export VOLUME_MODE=cached   # supposedly helps avoid 100% cpu consumption bug https://github.com/docker/for-mac/issues/3499
else export VOLUME_MODE=ro; fi
mkdir -p /etc/horizon   # putting the config files here because they are mounted long-term into the containers
cat $TMP_DIR/exchange-tmpl.json | envsubst > /etc/horizon/exchange.json
cat $TMP_DIR/agbot-tmpl.json | envsubst > /etc/horizon/agbot.json
cat $TMP_DIR/css-tmpl.conf | envsubst > /etc/horizon/css.conf

# Start mgmt hub services
echo "----------- Downloading/starting Horizon management hub services..."
echo "Downloading management hub docker images..."
# Even though docker-compose will pull these, it won't pull again if it already has a local copy of the 'latest' tag but it has been updated on docker hub
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

echo "Starting management hub containers..."
docker-compose up -d --no-build
chk $? 'starting docker-compose services'

# Ensure the exchange is responding
# Note: wanted to make these aliases to avoid quote/space problems, but aliases don't get inherited to sub-shells. But variables don't get processed again by the shell (but may get separated by spaces), so i think we are ok for the post/put data
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
    chkHttp $? $httpCode 201 "creating /orgs/$EXCHANGE_SYSTEM_ORG/users/admin" $CURL_ERROR_FILE
else
    # Set the pw to be what they specified this time
    httpCode=$(exchangePost -d "{\"newPassword\":\"$EXCHANGE_SYSTEM_ADMIN_PW\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/users/admin/changepw)
    chkHttp $? $httpCode 201 "changing pw of /orgs/$EXCHANGE_SYSTEM_ORG/users/admin" $CURL_ERROR_FILE
fi

# Create or update the agbot in the system org, and configure it with the pattern and deployment policy orgs
httpCode=$(exchangePut -d "{\"token\":\"$AGBOT_TOKEN\",\"name\":\"agbot\",\"publicKey\":\"\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/agbots/agbot)
chkHttp $? $httpCode 201 "creating/updating /orgs/$EXCHANGE_SYSTEM_ORG/agbots/agbot" $CURL_ERROR_FILE
httpCode=$(exchangePost -d "{\"patternOrgid\":\"$EXCHANGE_SYSTEM_ORG\",\"pattern\":\"*\",\"nodeOrgid\":\"$EXCHANGE_USER_ORG\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/agbots/agbot/patterns)
chkHttp $? $httpCode 201,409 "adding /orgs/$EXCHANGE_SYSTEM_ORG/agbots/agbot/patterns" $CURL_ERROR_FILE
httpCode=$(exchangePost -d "{\"patternOrgid\":\"$EXCHANGE_USER_ORG\",\"pattern\":\"*\",\"nodeOrgid\":\"$EXCHANGE_USER_ORG\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/agbots/agbot/patterns)
chkHttp $? $httpCode 201,409 "adding /orgs/$EXCHANGE_SYSTEM_ORG/agbots/agbot/patterns" $CURL_ERROR_FILE
httpCode=$(exchangePost -d "{\"businessPolOrgid\":\"$EXCHANGE_USER_ORG\",\"businessPol\":\"*\",\"nodeOrgid\":\"$EXCHANGE_USER_ORG\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/agbots/agbot/businesspols)
chkHttp $? $httpCode 201,409 "adding /orgs/$EXCHANGE_SYSTEM_ORG/agbots/agbot/businesspols" $CURL_ERROR_FILE

# Create the user org and an admin user within it
echo "Creating exchange user org and admin user..."
if [[ $(exchangeGet $HZN_EXCHANGE_URL/orgs/$EXCHANGE_USER_ORG) != 200 ]]; then
    httpCode=$(exchangePost -d "{\"label\":\"$EXCHANGE_USER_ORG\",\"description\":\"$EXCHANGE_USER_ORG\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_USER_ORG)
    chkHttp $? $httpCode 201 "creating /orgs/$EXCHANGE_USER_ORG" $CURL_ERROR_FILE
fi
if [[ $(exchangeGet $HZN_EXCHANGE_URL/orgs/$EXCHANGE_USER_ORG/users/admin) != 200 ]]; then
    httpCode=$(exchangePost -d "{\"password\":\"$EXCHANGE_USER_ADMIN_PW\",\"admin\":true,\"email\":\"not@used\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_USER_ORG/users/admin)
    chkHttp $? $httpCode 201 "creating /orgs/$EXCHANGE_USER_ORG/users/admin" $CURL_ERROR_FILE
else
    # Set the pw to be what they specified this time
    httpCode=$(exchangePost -d "{\"newPassword\":\"$EXCHANGE_USER_ADMIN_PW\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_USER_ORG/users/admin/changepw)
    chkHttp $? $httpCode 201 "changing pw of /orgs/$EXCHANGE_USER_ORG/users/admin" $CURL_ERROR_FILE
fi

# Install agent and CLI (CLI is needed for exchangePublish.sh in next step)
echo "----------- Downloading/installing Horizon agent and CLI..."
echo "Downloading the Horizon agent and CLI packages..."
mkdir -p $TMP_DIR/pkgs
rm -rf $TMP_DIR/pkgs/*   # get rid of everything so we can safely wildcard instead of having to figure out the version
if isMacOS; then
    getUrlFile $OH_DEVOPS_RELEASES/macos.macos.amd64.assets.tar.gz $TMP_DIR/pkgs/macos.macos.amd64.assets.tar.gz
    tar -zxf $TMP_DIR/pkgs/macos.macos.amd64.assets.tar.gz -C $TMP_DIR/pkgs   # will extract files like: v2.26.12.macos.macos.amd64.assets/horizon-cli-2.26.12.pkg
    chk $? 'extracting pkg tar file'
    echo "Installing the Horizon agent and CLI packages..."
    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $TMP_DIR/pkgs/*.macos.macos.amd64.assets/horizon-cli.crt
    sudo installer -pkg $TMP_DIR/pkgs/*.macos.macos.amd64.assets/horizon-cli-2.26.12.pkg -target /
    chk $? 'installing macos horizon-cli pkg'
    # we will install the agent below, after configuring /etc/default/horizon
else   # ubuntu
    getUrlFile $OH_DEVOPS_RELEASES/ubuntu.bionic.amd64.assets.tar.gz $TMP_DIR/pkgs/ubuntu.bionic.amd64.assets.tar.gz
    tar -zxf $TMP_DIR/pkgs/ubuntu.bionic.amd64.assets.tar.gz -C $TMP_DIR/pkgs   # will extract files like: v2.26.12.ubuntu.bionic.amd64.assets/horizon-cli_2.26.12~ppa~ubuntu.bionic_amd64.deb
    chk $? 'extracting pkg tar file'
    echo "Installing the Horizon agent and CLI packages..."
    runCmdQuietly apt-get install -yqf $TMP_DIR/pkgs/*.ubuntu.bionic.amd64.assets/*horizon*~ppa~ubuntu.bionic_*.deb
fi

# Configure the agent/CLI
echo "Configuring the Horizon agent and CLI..."
if isMacOS; then localhost=host.docker.internal  # so the agent in container can reach the host localhost
else localhost=localhost; fi
mkdir -p /etc/default
cat << EOF > /etc/default/horizon
HZN_EXCHANGE_URL=http://${localhost}:$EXCHANGE_PORT/v1
HZN_FSS_CSSURL=http://${localhost}:$CSS_PORT/
HZN_DEVICE_ID=$HZN_DEVICE_ID
EOF
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
export HZN_EXCHANGE_URL
export HZN_EXCHANGE_USER_AUTH="root/root:$EXCHANGE_ROOT_PW"
export HZN_ORG_ID=$EXCHANGE_SYSTEM_ORG
if [[ ! -f "$HOME/.hzn/keys/service.private.key" || ! -f "$HOME/.hzn/keys/service.public.pem" ]]; then
    $HZN key create -f 'OpenHorizon' 'open-horizon@lfedge.org'   # Note: that is not a real email address yet
    chk $? 'creating developer key pair'
fi
rm -rf /tmp/open-horizon/examples   # exchangePublish.sh will clone the examples repo to here
curl -sSL $OH_EXAMPLES_REPO/tools/exchangePublish.sh | bash -s -- -c $EXCHANGE_USER_ORG
chk $? 'publishing examples'
unset HZN_EXCHANGE_USER_AUTH HZN_ORG_ID   # need to set them differently for the registration below

# Temporary fixes: create pattern in user org, and restart agbot now that the agbot definition in the exchange has been configured (issues: https://github.com/open-horizon/anax/issues/1865 and https://github.com/open-horizon/anax/issues/1888)
if [[ $(exchangeGet $HZN_EXCHANGE_URL/orgs/$EXCHANGE_USER_ORG/patterns/donotdelete) != 200 ]]; then
    httpCode=$(exchangePost -d "{\"label\":\"temporary\",\"services\":[{\"serviceUrl\":\"ibm.helloworld\",\"serviceOrgid\":\"$EXCHANGE_SYSTEM_ORG\",\"serviceArch\":\"amd64\",\"serviceVersions\":[{\"version\":\"1.0.0\"}]}]}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_USER_ORG/patterns/donotdelete)
    chkHttp $? $httpCode 201 "creating /orgs/$EXCHANGE_USER_ORG/patterns/donotdelete" $CURL_ERROR_FILE
fi
echo "Restarting the agbot container as a temporary work around..."
docker-compose restart -t 10 agbot
chk $? 'restarting agbot service'

# Register the agent
echo "----------- Creating and registering the edge node with policy to run the helloworld Horizon example..."
getUrlFile $OH_EXAMPLES_REPO/edge/services/helloworld/horizon/node.policy.json node.policy.json
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
if [[ $EXCHANGE_ROOT_PW_GENERATED == 'true' ]]; then
    echo "     - Exchange root user generated password: $EXCHANGE_ROOT_PW"
fi
if [[ $EXCHANGE_SYSTEM_ADMIN_PW_GENERATED == 'true' ]]; then
    echo "     - System org admin user generated password: $EXCHANGE_SYSTEM_ADMIN_PW"
fi
if [[ $AGBOT_TOKEN_GENERATED == 'true' ]]; then
    echo "     - Agbot generated token: $AGBOT_TOKEN"
fi
if [[ $EXCHANGE_USER_ADMIN_PW_GENERATED == 'true' ]]; then
    echo "     - User org admin user generated password: $EXCHANGE_USER_ADMIN_PW"
fi
if [[ $HZN_DEVICE_TOKEN_GENERATED == 'true' ]]; then
    echo "     - Node generated token: $HZN_DEVICE_TOKEN"
fi
if [[ $EXCHANGE_ROOT_PW_GENERATED == 'true' || $EXCHANGE_SYSTEM_ADMIN_PW_GENERATED == 'true' || $AGBOT_TOKEN_GENERATED == 'true' || $EXCHANGE_USER_ADMIN_PW_GENERATED == 'true' || $HZN_DEVICE_TOKEN_GENERATED == 'true' ]]; then
    echo "     Important: save these generated passwords/tokens in a safe place. You will not be able to query them from Horizon."
fi
echo "  3. Installed the Horizon agent and CLI (hzn)"
echo "  4. Created a Horizon developer key pair"
echo "  5. Installed the Horizon examples"
echo "  6. Created and registered an edge node to run the helloworld example edge service"
if isMacOS && ! isDirInPath '/usr/local/bin'; then
    echo "Warning: /usr/local/bin is not in your path. Add it now, otherwise you will have to always full qualify the hzn and horizon-container commands."
fi
if isMacOS; then
    echo "Note: you must export the following variables when using the hzn command (because /etc/default/horizon was set to allow the agent in the container to reach the host's localhost):"
    echo "export HZN_EXCHANGE_URL=http://localhost:$EXCHANGE_PORT/v1 HZN_FSS_CSSURL=http://localhost:$CSS_PORT/"
echo "For what to do next, see: https://github.com/open-horizon/devops/blob/master/mgmt-hub/README.md#all-in-1-what-next"
