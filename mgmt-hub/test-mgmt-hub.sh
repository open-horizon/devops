#!/bin/bash

# Test the current all-in-1 management hub and agent

usage() {
    exitCode=${1:-0}
    cat << EndOfMessage
Usage: ${0##*/} [-c <config-file>] [-h] [-v]

Test the current all-in-1 management hub and agent.

Preconditions for running this test script:
- Currently only supported on ubuntu
- You must pass in the same variable customizations that you did to deploy-mgmt-hub.sh (either via environment variables or config file).

Flags:
  -c <config-file>   A config file with lines in the form variable=value that set any of the environment variables supported by this script. Takes precedence over the same variables passed in through the environment.
  -v    Verbose output.
  -h    Show this usage.

Required Environment Variables:
  HZN_EXCHANGE_USER_AUTH - user credentials to use to import the SDO voucher.
EndOfMessage
    exit $exitCode
}

# Parse cmd line
while getopts ":c:vh" opt; do
	case $opt in
		c)  CONFIG_FILE="$OPTARG"
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
shift $#   # shunit2 that is run below won't understand these args
#echo "Number of args: $#, args: $*"

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

: ${EXCHANGE_HUB_ADMIN_PW:?} ${EXCHANGE_SYSTEM_ADMIN_PW:?} ${EXCHANGE_USER_ADMIN_PW:?}   # required

# Default environment variables that can be overridden.
export EXCHANGE_SYSTEM_ORG=${EXCHANGE_SYSTEM_ORG:-IBM}
export EXCHANGE_USER_ORG=${EXCHANGE_USER_ORG:-myorg}

# Global variables for this script (not intended to be overridden)
TMP_DIR=/tmp/horizon-all-in-1
mkdir -p $TMP_DIR
CURL_OUTPUT_FILE=$TMP_DIR/curlExchangeOutput
CURL_ERROR_FILE=$TMP_DIR/curlExchangeErrors
SEMVER_REGEX='^[0-9]+\.[0-9]+(\.[0-9]+)+'   # matches a version like 1.2.3 (must be at least 3 fields). Also allows a bld num on the end like: 1.2.3-RC1

#====================== Geneeral Functions ======================

# Only echo this if VERBOSE is 1 or true
verbose() {
    if [[ "$VERBOSE" == '1' || "$VERBOSE" == 'true' ]]; then
        echo 'verbose:' $*
    fi
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

isWordInString() {   # returns true (0) if the specified word is in the space-separated string
    local word=${1:?} string=$2
    if [[ $string =~ (^|[[:space:]])$word($|[[:space:]]) ]]; then
        return 0
    else
        return 1
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

assertStartsWith() {
    assertNotEquals "$1" "${1#$2}"
}

assertEndsWith() {
    assertNotEquals "$1" "${1%$2}"
}

#====================== Test Functions ======================

testDefaultsFile() {
    assertTrue "grep -q -E '^HZN_EXCHANGE_URL=http' /etc/default/horizon"
    assertTrue "grep -q -E '^HZN_FSS_CSSURL=http' /etc/default/horizon"
    assertTrue "grep -q -E '^HZN_AGBOT_URL=http' /etc/default/horizon"
    assertTrue "grep -q -E '^HZN_SDO_SVC_URL=http' /etc/default/horizon"
    assertTrue "grep -q -E '^HZN_DEVICE_ID=.+' /etc/default/horizon"
    if grep -q -E '^HZN_FSS_CSSURL=https:' /etc/default/horizon; then
        assertTrue "grep -q -E '^HZN_MGMT_HUB_CERT_PATH=.+' /etc/default/horizon"
    fi
}

testSystemctlStatus() {
    assertTrue "systemctl status horizon | grep -q -E '^ *Active: active \(running\)'"
}

testHznNodeList() {
    local nodeList=$(hzn node list 2>&1)
    local exchVersion=$(jq -r .configuration.exchange_version <<< $nodeList)
    assertTrue "[[ $exchVersion =~ $SEMVER_REGEX ]]"
    assertEquals "$(jq -r .configstate.state <<< $nodeList)" 'configured'
}

testPolicyList() {
    assertEquals "$(hzn policy list | jq -r '.properties[] | select(.name=="openhorizon.example") | .value')" 'helloworld'
}

testHznAgreementList() {
    assertNotEquals "$(hzn agreement list)" '[]'
}

testEventLog() {
    # this isn't done in a re-registration: assertTrue "hzn eventlog list | grep -q 'Complete policy advertising with the Exchange for service IBM/ibm.helloworld' "
    assertTrue "hzn eventlog list | grep -q -E 'Node received Proposal message using agreement \S+ for service IBM/ibm.helloworld' "
    assertTrue "hzn eventlog list | grep -q 'Agreement reached for service ibm.helloworld' "
    assertTrue "hzn eventlog list | grep -q 'Image loaded for IBM/ibm.helloworld' "
    assertTrue "hzn eventlog list | grep -q 'Workload service containers for IBM/ibm.helloworld are up and running' "
}

testDockerPs() {
    assertTrue "docker ps --format '{{ .Names }}' | grep -q -E '\-ibm.helloworld$' "
    assertTrue "docker ps --format '{{ .Names }}' | grep -q -E '^sdo-owner-services$' "
    assertTrue "docker ps --format '{{ .Names }}' | grep -q -E '^agbot$' "
    assertTrue "docker ps --format '{{ .Names }}' | grep -q -E '^css-api$' "
    assertTrue "docker ps --format '{{ .Names }}' | grep -q -E '^exchange-api$' "
    assertTrue "docker ps --format '{{ .Names }}' | grep -q -E '^mongo$' "
    assertTrue "docker ps --format '{{ .Names }}' | grep -q -E '^postgres$' "
}

testServiceLog() {
    assertTrue "hzn service log ibm.helloworld | grep -q 'says: Hello ' "
}

testExchangeUserOrg() {
    export HZN_ORG_ID=$EXCHANGE_USER_ORG
    export HZN_EXCHANGE_USER_AUTH=admin:$EXCHANGE_USER_ADMIN_PW
    assertTrue "hzn exchange service list IBM/ | grep -q 'IBM/ibm.helloworld_1.0.0_amd64' "
}

#====================== Main ======================

if [[ ! -f shunit2 ]]; then   # hasn't changed in 14 months, so don't need to download it every time
    getUrlFile https://raw.githubusercontent.com/kward/shunit2/master/shunit2 shunit2
    #chmod +x shunit2   # we are sourcing it, so it doesn't need to be executable
fi

. ./shunit2   # run every function that starts with 'test'
