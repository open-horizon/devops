#!/bin/bash

# Deploy the management hub services (agbot, exchange, css, sdo, postgre, mongo), the agent, and the CLI on the current host.

usage() {
    exitCode=${1:-0}
    cat << EndOfMessage
Usage: ${0##*/} [-c <config-file>] [-A] [-v] [-h] [-s | -u | -S [-P] | -r <container>]

Deploy the Open Horizon management hub services, agent, and CLI on this host. Currently supports the following operating systems:

* Ubuntu 18.x and 20.x (amd64, ppc64le)
* macOS (experimental)
* RHEL 8.x (ppc64le)
* Note: The support for ppc64le is experimental, because the management hub components are not yet generally available for ppc64le.

Flags:
  -c <config-file>   A config file with lines in the form variable=value that set any of the environment variables supported by this script. Takes precedence over the same variables passed in through the environment.
  -A    Do not install the horizon agent package. (It will still install the horizon-cli package.) Without this flag, it will install and register the horizon agent (as well as all of the management hub services).
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
if [[ $ARCH == "amd64" ]]; then
    export DOCKER_COMPOSE_CMD="docker-compose"
else    # ppc64le
    export DOCKER_COMPOSE_CMD="pipenv run docker-compose"
fi

# Parse cmd line
while getopts ":c:ASPsur:vh" opt; do
	case $opt in
		c)  CONFIG_FILE="$OPTARG"
		    ;;
		A)  NO_AGENT=1
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
export EXCHANGE_ROOT_PW_BCRYPTED=${EXCHANGE_ROOT_PW_BCRYPTED:-$EXCHANGE_ROOT_PW}  # we are not able to bcrypt it, so must default to the clear pw when they do not specify it

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

export EXCHANGE_IMAGE_NAME=${EXCHANGE_IMAGE_NAME:-openhorizon/${ARCH}_exchange-api}
export EXCHANGE_IMAGE_TAG=${EXCHANGE_IMAGE_TAG:-latest}   # or can be set to stable or a specific version
export EXCHANGE_PORT=${EXCHANGE_PORT:-3090}
export EXCHANGE_LOG_LEVEL=${EXCHANGE_LOG_LEVEL:-INFO}
export EXCHANGE_SYSTEM_ORG=${EXCHANGE_SYSTEM_ORG:-IBM}   # the name of the system org (which contains the example services and patterns). Currently this can not be overridden
export EXCHANGE_USER_ORG=${EXCHANGE_USER_ORG:-myorg}   # the name of the org which you will use to create nodes, service, patterns, and deployment policies
export EXCHANGE_WAIT_ITERATIONS=${EXCHANGE_WAIT_ITERATIONS:-30}
export EXCHANGE_WAIT_INTERVAL=${EXCHANGE_WAIT_INTERVAL:-2}   # number of seconds to sleep between iterations

export AGBOT_IMAGE_NAME=${AGBOT_IMAGE_NAME:-openhorizon/${ARCH}_agbot}
export AGBOT_IMAGE_TAG=${AGBOT_IMAGE_TAG:-latest}   # or can be set to stable or a specific version
export AGBOT_ID=${AGBOT_ID:-agbot}   # its agbot id in the exchange
export AGBOT_PORT=${AGBOT_PORT:-3110}   #todo: should we not expose this to anything but localhost?
export AGBOT_SECURE_PORT=${AGBOT_SECURE_PORT:-3111}   # the externally accessible port
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
export CSS_PORT=${CSS_PORT:-9443}

export POSTGRES_IMAGE_NAME=${POSTGRES_IMAGE_NAME:-postgres}
export POSTGRES_IMAGE_TAG=${POSTGRES_IMAGE_TAG:-latest}   # or can be set to stable or a specific version
export POSTGRES_PORT=${POSTGRES_PORT:-5432}
export POSTGRES_USER=${POSTGRES_USER:-admin}
export EXCHANGE_DATABASE=${EXCHANGE_DATABASE:-exchange}   # the db the exchange uses in the postgres instance
export AGBOT_DATABASE=${AGBOT_DATABASE:-exchange}   #todo: figure out how to get 2 different databases created in postgres. The db the agbot uses in the postgres instance

export MONGO_IMAGE_NAME=${MONGO_IMAGE_NAME:-mongo}
export MONGO_IMAGE_TAG=${MONGO_IMAGE_TAG:-latest}   # or can be set to stable or a specific version
export MONGO_PORT=${MONGO_PORT:-27017}

export SDO_IMAGE_NAME=${SDO_IMAGE_NAME:-openhorizon/sdo-owner-services}
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

export HC_DOCKER_TAG=${HC_DOCKER_TAG:-latest}   # when using the anax-in-container agent

OH_DEVOPS_REPO=${OH_DEVOPS_REPO:-https://raw.githubusercontent.com/open-horizon/devops/master}
OH_ANAX_RELEASES=${OH_ANAX_RELEASES:-https://github.com/open-horizon/anax/releases/latest/download}
OH_ANAX_MAC_PKG_TAR=${OH_ANAX_MAC_PKG_TAR:-horizon-agent-macos-pkg-x86_64.tar.gz}
OH_ANAX_DEB_PKG_TAR=${OH_ANAX_DEB_PKG_TAR:-horizon-agent-linux-deb-${ARCH_DEB}.tar.gz}
OH_ANAX_RPM_PKG_TAR=${OH_ANAX_RPM_PKG_TAR:-horizon-agent-linux-rpm-${ARCH}.tar.gz}
OH_EXAMPLES_REPO=${OH_EXAMPLES_REPO:-https://raw.githubusercontent.com/open-horizon/examples/master}

HZN_DEVICE_ID=${HZN_DEVICE_ID:-node1}   # the edge node id you want to use

# Global variables for this script (not intended to be overridden)
TMP_DIR=/tmp/horizon
mkdir -p $TMP_DIR
CURL_OUTPUT_FILE=$TMP_DIR/curlExchangeOutput
CURL_ERROR_FILE=$TMP_DIR/curlExchangeErrors
SYSTEM_TYPE=${SYSTEM_TYPE:-$(uname -s)}
DISTRO=${DISTRO:-$(. /etc/os-release 2>/dev/null;echo $ID $VERSION_ID)}
IP_REGEX='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'   # use it like: if [[ $host =~ $IP_REGEX ]]
export CERT_DIR=/etc/horizon/keys
export CERT_BASE_NAME=horizonMgmtHub

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

isUbuntu18() {
    if [[ "$DISTRO" == 'ubuntu 18.'* ]]; then
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

isUbuntu20() {
    if [[ "$DISTRO" == 'ubuntu 20.'* ]]; then
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
    pullDockerImage ${SDO_IMAGE_NAME}:${SDO_IMAGE_TAG}
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
    rm -f $CERT_DIR/$CERT_BASE_NAME.{key,crl} 
    chk $? "removing key and cert from $CERT_DIR"
}

createKeyAndCert() {   # create in directory $CERT_DIR a self-signed key and certificate named: $CERT_BASE_NAME.key, $CERT_BASE_NAME.crt
    # Check if the cert is already correct from a previous run, so we don't keep changing it
    if ! isCmdInstalled openssl; then
        fata 2 "specified HZN_TRANSPORT=$HZN_TRANSPORT, but command openssl is not installed to create the self-signed certificate"
    fi
    if [[ -f "$CERT_DIR/$CERT_BASE_NAME.key" && -f "$CERT_DIR/$CERT_BASE_NAME.crt" ]]; then
        echo "Certificate $CERT_DIR/$CERT_BASE_NAME.crt already exists, so not receating it"
        return   # no need to recreate the cert
    fi

    # Create the private key and certificate
    mkdir -p $CERT_DIR && chmod +r $CERT_DIR   # need to make it readable by the non-root user inside the container
    chk $? "making directory $CERT_DIR"
    removeKeyAndCert
    local altNames=$(ip address | grep -o -E "\sinet [^/\s]*" | awk -vORS=,IP: '{ print $2 }' | sed -e 's/^/IP:/' -e 's/,IP:$//')   # result: IP:127.0.0.1,IP:10.21.42.91,...
    altNames="$altNames,DNS:localhost,DNS:agbot,DNS:exchange-api,DNS:css-api,DNS:sdo-owner-services"   # add the names the containers use to contact each other
    echo "Creating self-signed certificate for these IP addresses: $altNames"
    # taken from https://medium.com/@groksrc/create-an-openssl-self-signed-san-cert-in-a-single-command-627fd771f25
    openssl req -newkey rsa:4096 -nodes -sha256 -x509 -keyout $CERT_DIR/$CERT_BASE_NAME.key -days 365 -out $CERT_DIR/$CERT_BASE_NAME.crt -subj "/C=US/ST=NY/L=New York/O=allin1@openhorizon.org/CN=$(hostname)" -extensions san -config <(echo '[req]'; echo 'distinguished_name=req'; echo '[san]'; echo "subjectAltName=$altNames")
    chk $? "creating key and certificate"
    chmod +r $CERT_DIR/$CERT_BASE_NAME.key

    # Currently the SDO mgmt hub component needs the key and cert named differently
    cp $CERT_DIR/$CERT_BASE_NAME.key $CERT_DIR/sdoapi.key   # a sym link won't work when it is mounted into the container
    chk $? "linking key to $CERT_DIR/sdoapi.key"
    cp $CERT_DIR/$CERT_BASE_NAME.crt $CERT_DIR/sdoapi.crt
    chk $? "linking crt to $CERT_DIR/sdoapi.crt"

    #todo: should we do this so local curl cmds will use it: ln -s $CERT_DIR/$CERT_BASE_NAME.crt /etc/ssl/certs
}

#====================== End of Functions, Start of Main ======================

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

# Set OS-dependent package manager settings in Linux
if isUbuntu18 || isUbuntu20; then
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

if ! isMacOS && ! isUbuntu18 && ! isUbuntu20 && ! isRedHat8; then
    fatal 1 "the host must be Ubuntu 18.x (amd64, ppc64le) or Ubuntu 20.x (amd64, ppc64le) or macOS or RedHat 8.x (ppc64le)"
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

    if isMacOS; then
        if [[ -z $NO_AGENT ]]; then
            /usr/local/bin/horizon-container stop
        fi
        if [[ -n "$PURGE" ]]; then
            echo "Uninstalling the Horizon CLI..."
            /usr/local/bin/horizon-cli-uninstall.sh -y   # removes the content of the horizon-cli pkg
            if [[ -z $NO_AGENT ]]; then
                echo "Removing the Horizon agent image..."
                runCmdQuietly docker rmi openhorizon/amd64_anax:$HC_DOCKER_TAG
            fi
        fi
    elif [[ -z $NO_AGENT  ]]; then   # ubuntu and redhat
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
    fi

    if [[ -n "$PURGE" && $KEEP_DOCKER_IMAGES != 'true' ]]; then   # KEEP_DOCKER_IMAGES is a hidden env var for convenience while developing this script
        echo "Removing Open-horizon Docker images..."
        runCmdQuietly docker rmi ${AGBOT_IMAGE_NAME}:${AGBOT_IMAGE_TAG} ${EXCHANGE_IMAGE_NAME}:${EXCHANGE_IMAGE_TAG} ${CSS_IMAGE_NAME}:${CSS_IMAGE_TAG} ${POSTGRES_IMAGE_NAME}:${POSTGRES_IMAGE_TAG} ${MONGO_IMAGE_NAME}:${MONGO_IMAGE_TAG} ${SDO_IMAGE_NAME}:${SDO_IMAGE_TAG}
    fi
    exit
fi

# Start the mgmt hub services and agent (use existing configuration)
if [[ -n "$START" ]]; then
    echo "Starting management hub containers..."
    pullImages
    ${DOCKER_COMPOSE_CMD} up -d --no-build
    chk $? 'starting docker-compose services'

    if [[ -z $NO_AGENT ]]; then
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
    echo "Updating management hub containers..."
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
    echo "Restarting the $RESTART container..."
    ${DOCKER_COMPOSE_CMD} restart -t 10 "$RESTART"   #todo: do not know if this will work if there are 2 agbots replicas running
    exit
fi

#====================== Main Deployment Code ======================

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
        optionalOpensslPkg='oepnssl'
    fi
    runCmdQuietly ${PKG_MNGR} ${PKG_MNGR_INSTALL_QY_CMD} jq ${PKG_MNGR_GETTEXT} make $optionalOpensslPkg

    # If docker isn't installed, do that
    if ! isCmdInstalled docker; then
        echo "Docker is required, installing it..."
        if isUbuntu18 || isUbuntu20; then
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

    minVersion=1.21.0
    if ! isDockerComposeAtLeast $minVersion; then
        if isCmdInstalled docker-compose; then
            fatal 2 "Need at least docker-compose $minVersion. A down-level version is currently installed, preventing us from installing the latest version. Uninstall docker-compose and rerun this script."
        fi
        echo "docker-compose is not installed or not at least version $minVersion, installing/upgrading it..."
        if [[ "${ARCH}" == "amd64" ]]; then
            # Install docker-compose from its github repo, because that is the only way to get a recent enough version
            curl --progress-bar -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
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
    createKeyAndCert   # won't recreate it if already correct

    # agbot-tmpl.json can only have these set when using https
    export SECURE_API_SERVER_KEY="/home/agbotuser/keys/${CERT_BASE_NAME}.key"
    export SECURE_API_SERVER_CERT="/home/agbotuser/keys/${CERT_BASE_NAME}.crt"

    export CSS_LISTENING_TYPE=secure
else
    removeKeyAndCert   # so when we mount CERT_DIR to the containers it will be empty
    export CSS_LISTENING_TYPE=unsecure
fi

# Download and process templates from open-horizon/devops
echo "----------- Downloading template files..."
getUrlFile $OH_DEVOPS_REPO/mgmt-hub/docker-compose.yml docker-compose.yml
getUrlFile $OH_DEVOPS_REPO/mgmt-hub/docker-compose-agbot2.yml docker-compose-agbot2.yml
getUrlFile $OH_DEVOPS_REPO/mgmt-hub/exchange-tmpl.json $TMP_DIR/exchange-tmpl.json
getUrlFile $OH_DEVOPS_REPO/mgmt-hub/agbot-tmpl.json $TMP_DIR/agbot-tmpl.json
getUrlFile $OH_DEVOPS_REPO/mgmt-hub/css-tmpl.conf $TMP_DIR/css-tmpl.conf
# Leave a copy of ourself in the current dir for subsequent stop/start commands.
# If they are running us via ./deploy-mgmt-hub.sh we can't overwrite ourselves (or we get syntax errors), so only do it if we are piped into bash or for some other reason aren't executing the script from the current dir
if [[ $0 == 'bash' || ! -f deploy-mgmt-hub.sh ]]; then
    getUrlFile $OH_DEVOPS_REPO/mgmt-hub/deploy-mgmt-hub.sh deploy-mgmt-hub.sh
    chmod +x deploy-mgmt-hub.sh
fi
# also leave a copy of test-sdo.sh so they can run that afterward if they want to take SDO for a spin
getUrlFile $OH_DEVOPS_REPO/mgmt-hub/test-sdo.sh test-sdo.sh
chmod +x test-sdo.sh

echo "Substituting environment variables into template files..."
export ENVSUBST_DOLLAR_SIGN='$'   # needed for essentially escaping $, because we need to let the exchange itself replace $EXCHANGE_ROOT_PW_BCRYPTED
mkdir -p /etc/horizon   # putting the config files here because they are mounted long-term into the containers
cat $TMP_DIR/exchange-tmpl.json | envsubst > /etc/horizon/exchange.json
cat $TMP_DIR/agbot-tmpl.json | envsubst > /etc/horizon/agbot.json
cat $TMP_DIR/css-tmpl.conf | envsubst > /etc/horizon/css.conf

# Start mgmt hub services
echo "----------- Downloading/starting Horizon management hub services..."
echo "Downloading management hub docker images..."
# Even though docker-compose will pull these, it won't pull again if it already has a local copy of the tag but it has been updated on docker hub
pullImages

echo "Starting management hub containers..."
${DOCKER_COMPOSE_CMD} up -d --no-build
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

# Create or update the agbot in the system org, and configure it with the pattern and deployment policy orgs
if [[ $(exchangeGet $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/agbots/$AGBOT_ID) == 200 ]]; then
    restartAgbot='true'   # we may be changing its token, so need to restart it. (If there is initially no agbot resource, the agbot will just wait until it appears)
fi
httpCode=$(exchangePut -d "{\"token\":\"$AGBOT_TOKEN\",\"name\":\"agbot\",\"publicKey\":\"\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/agbots/$AGBOT_ID)
chkHttp $? $httpCode 201 "creating/updating /orgs/$EXCHANGE_SYSTEM_ORG/agbots/$AGBOT_ID" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
httpCode=$(exchangePost -d "{\"patternOrgid\":\"$EXCHANGE_SYSTEM_ORG\",\"pattern\":\"*\",\"nodeOrgid\":\"$EXCHANGE_USER_ORG\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/agbots/$AGBOT_ID/patterns)
chkHttp $? $httpCode 201,409 "adding /orgs/$EXCHANGE_SYSTEM_ORG/agbots/$AGBOT_ID/patterns" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
httpCode=$(exchangePost -d "{\"patternOrgid\":\"$EXCHANGE_USER_ORG\",\"pattern\":\"*\",\"nodeOrgid\":\"$EXCHANGE_USER_ORG\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/agbots/$AGBOT_ID/patterns)
chkHttp $? $httpCode 201,409 "adding /orgs/$EXCHANGE_SYSTEM_ORG/agbots/$AGBOT_ID/patterns" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
httpCode=$(exchangePost -d "{\"businessPolOrgid\":\"$EXCHANGE_USER_ORG\",\"businessPol\":\"*\",\"nodeOrgid\":\"$EXCHANGE_USER_ORG\"}" $HZN_EXCHANGE_URL/orgs/$EXCHANGE_SYSTEM_ORG/agbots/$AGBOT_ID/businesspols)
chkHttp $? $httpCode 201,409 "adding /orgs/$EXCHANGE_SYSTEM_ORG/agbots/$AGBOT_ID/businesspols" $CURL_ERROR_FILE $CURL_OUTPUT_FILE

if [[ $restartAgbot == 'true' ]]; then
    ${DOCKER_COMPOSE_CMD} restart -t 10 agbot   # docker-compose will print that it is restarting the agbot
    chk $? 'restarting agbot service'
fi

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
else   # ubuntu and redhat
    if isUbuntu18 || isUbuntu20; then
        getUrlFile $OH_ANAX_RELEASES/$OH_ANAX_DEB_PKG_TAR $TMP_DIR/pkgs/$OH_ANAX_DEB_PKG_TAR
        tar -zxf $TMP_DIR/pkgs/$OH_ANAX_DEB_PKG_TAR -C $TMP_DIR/pkgs   # will extract files like: horizon-cli_2.27.0_amd64.deb
        chk $? 'extracting pkg tar file'
        if [[ -z $NO_AGENT ]]; then
            echo "Installing the Horizon agent and CLI packages..."
            horizonPkgs=$(ls $TMP_DIR/pkgs/horizon*.deb)
        else   # only horizon-cli
            echo "Installing the Horizon CLI package..."
            horizonPkgs=$(ls $TMP_DIR/pkgs/horizon-cli*.deb)
        fi
        runCmdQuietly ${PKG_MNGR} ${PKG_MNGR_INSTALL_QY_CMD} $horizonPkgs
    else # redhat
        getUrlFile $OH_ANAX_RELEASES/$OH_ANAX_RPM_PKG_TAR $TMP_DIR/pkgs/$OH_ANAX_RPM_PKG_TAR
        tar -zxf $TMP_DIR/pkgs/$OH_ANAX_RPM_PKG_TAR -C $TMP_DIR/pkgs   # will extract files like: horizon-cli_2.27.0_amd64.rpm
        chk $? 'extracting pkg tar file'
        echo "Installing the Horizon agent and CLI packages..."
        if [[ -z $NO_AGENT ]]; then
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
HZN_EXCHANGE_URL=http://${THIS_HOST_LISTEN_IP}:$EXCHANGE_PORT/v1
HZN_FSS_CSSURL=${HZN_TRANSPORT}://${THIS_HOST_LISTEN_IP}:$CSS_PORT/
HZN_AGBOT_URL=${HZN_TRANSPORT}://${THIS_HOST_LISTEN_IP}:$AGBOT_SECURE_PORT
HZN_SDO_SVC_URL=${HZN_TRANSPORT}://${THIS_HOST_LISTEN_IP}:$SDO_OCS_API_PORT/api
HZN_DEVICE_ID=$HZN_DEVICE_ID
EOF

if [[ $HZN_TRANSPORT == 'https' ]]; then
    echo "HZN_MGMT_HUB_CERT_PATH=$CERT_DIR/$CERT_BASE_NAME.crt" >> /etc/default/horizon

    # Now that HZN_MGMT_HUB_CERT_PATH is in /etc/default/horizon, we can use hzn mms to put the certificate in CSS
    unset HZN_EXCHANGE_URL   # use the value in /etc/default/horizon
    putOneFileInCss $CERT_DIR/$CERT_BASE_NAME.crt agent-install.crt
fi

unset HZN_EXCHANGE_URL   # use the value in /etc/default/horizon

if [[ -z $NO_AGENT ]]; then
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
HZN_EXCHANGE_URL=http://${CFG_LISTEN_IP}:$EXCHANGE_PORT/v1
HZN_FSS_CSSURL=${HZN_TRANSPORT}://${CFG_LISTEN_IP}:$CSS_PORT/
HZN_AGBOT_URL=${HZN_TRANSPORT}://${CFG_LISTEN_IP}:$AGBOT_SECURE_PORT
HZN_SDO_SVC_URL=${HZN_TRANSPORT}://${CFG_LISTEN_IP}:$SDO_OCS_API_PORT/api
EOF

if [[ $HZN_TRANSPORT == 'https' ]]; then
    echo "HZN_MGMT_HUB_CERT_PATH=$CERT_DIR/$CERT_BASE_NAME.crt" >> $TMP_DIR/agent-install.cfg
fi

putOneFileInCss $TMP_DIR/agent-install.cfg

# Prime exchange with horizon examples
echo "----------- Creating developer key pair, and installing Horizon example services, policies, and patterns..."
export EXCHANGE_ROOT_PASS="$EXCHANGE_ROOT_PW"
# HZN_EXCHANGE_USER_AUTH= and HZN_ORG_ID are set in the section above
export HZN_EXCHANGE_URL=http://${THIS_HOST_LISTEN_IP}:$EXCHANGE_PORT/v1
if [[ ! -f "$HOME/.hzn/keys/service.private.key" || ! -f "$HOME/.hzn/keys/service.public.pem" ]]; then
    $HZN key create -f 'OpenHorizon' 'open-horizon@lfedge.org'   # Note: that is not a real email address yet
    chk $? 'creating developer key pair'
fi
rm -rf /tmp/open-horizon/examples   # exchangePublish.sh will clone the examples repo to here
curl -sSL $OH_EXAMPLES_REPO/tools/exchangePublish.sh | bash -s -- -c $EXCHANGE_USER_ORG
chk $? 'publishing examples'
unset HZN_EXCHANGE_USER_AUTH HZN_ORG_ID HZN_EXCHANGE_URL   # need to set them differently for the registration below

if [[ -z $NO_AGENT ]]; then
    # Register the agent
    echo "----------- Creating and registering the edge node with policy to run the helloworld Horizon example..."
    getUrlFile $OH_EXAMPLES_REPO/edge/services/helloworld/horizon/node.policy.json node.policy.json
    waitForAgent

    # if they previously registered, then unregister
    if [[ $($HZN node list 2>&1 | jq -r '.configstate.state' 2>&1) == 'configured' ]]; then
        $HZN unregister -f $UNREGISTER_FLAGS   # this flag variable is left here because rerunning this script was resulting in the unregister failing partway thru, but now i can't reproduce it
        chk $? 'unregistration'
        waitForAgent
    fi
    $HZN register -o $EXCHANGE_USER_ORG -u "admin:$EXCHANGE_USER_ADMIN_PW" -n "$HZN_DEVICE_ID:$HZN_DEVICE_TOKEN" --policy node.policy.json -s ibm.helloworld --serviceorg $EXCHANGE_SYSTEM_ORG -t 180
    chk $? 'registration'
fi

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
if [[ -z $NO_AGENT ]]; then
    echo "  3. Installed the Horizon agent and CLI (hzn)"
else   # only cli
    echo "  3. Installed the Horizon CLI (hzn)"
fi
echo "  4. Created a Horizon developer key pair"
echo "  5. Installed the Horizon examples"
if [[ -z $NO_AGENT ]]; then
    echo "  6. Created and registered an edge node to run the helloworld example edge service"
    nextNum='7'
fi
echo "  ${nextNum:-6}. Added the hzn auto-completion file to ~/.${SHELL##*/}rc (but you need to source that again for it to take effect in this shell session)"
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
