#!/bin/bash

# Test SDO in this all-in-1 Horizon installation by:
#  - Verify sdo-owner-services is functioning properly
#  - Configure this host as a simulated SDO-enabled device
#  - Import the voucher of this device into sdo-owner-services
#  - Simulate the booting of this device, which will verify the agent has already been installed, and then register it for the helloworld edge service example

usage() {
    exitCode=${1:-0}
    cat << EndOfMessage
Usage: ${0##*/} [-c <config-file>] [-h] [-v]

Configure this host as a simulated SDO-enabled device, then simulate booting it to have SDO configure it as an edge device registered to this management hub. Note: It is assumed that you pass in the same variable customizations that you did to deploy-mgmt-hub.sh (either via environment variables or config file).

Flags:
  -c <config-file>   A config file with lines in the form variable=value that set any of the environment variables supported by this script. Takes precedence over the same variables passed in through the environment.
  -v    Verbose output.
  -h    Show this usage.

Required Environment Variables:
  HZN_EXCHANGE_USER_AUTH - user credentials to use to import the SDO voucher.

Optional Environment Variables:
  HZN_ORG_ID - the exchange org to impport the device into. Defaults to myorg.
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

: ${HZN_EXCHANGE_USER_AUTH:?}   # required

# These environment variables can be overridden
export HZN_ORG_ID=${HZN_ORG_ID:-myorg}
export SDO_SAMPLE_MFG_KEEP_SVCS=${SDO_SAMPLE_MFG_KEEP_SVCS:-true}
export SDO_MFG_IMAGE_TAG=${SDO_MFG_IMAGE_TAG:-latest}
#export SDO_SUPPORT_REPO=${SDO_SUPPORT_REPO:-https://raw.githubusercontent.com/open-horizon/SDO-support/master}
SDO_SUPPORT_RELEASE=${SDO_SUPPORT_RELEASE:-https://github.com/open-horizon/SDO-support/releases/latest/download}
SDO_RV_PORT=${SDO_RV_PORT:-8040}
SDO_TO0_WAIT=${SDO_TO0_WAIT:-10}   # number of seconds to sleep to give to0scheduler a chance to register the voucher with the RV
OH_EXAMPLES_REPO=${OH_EXAMPLES_REPO:-https://raw.githubusercontent.com/open-horizon/examples/master}

# Global variables for this script (not intended to be overridden)
TMP_DIR=/tmp/horizon-all-in-1
mkdir -p $TMP_DIR
CURL_OUTPUT_FILE=$TMP_DIR/curlExchangeOutput
CURL_ERROR_FILE=$TMP_DIR/curlExchangeErrors

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
    chk $exitCode "$task"
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

isUbuntu18() {
    if [[ "$(lsb_release -d 2>/dev/null | awk '{print $2" "$3}')" == 'Ubuntu 18.'* ]]; then
		return 0
	else
		return 1
	fi
}

isUbuntu20() {
    if [[ "$(lsb_release -d 2>/dev/null | awk '{print $2" "$3}')" == 'Ubuntu 20.'* ]]; then
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
        chkHttp $? "$httpCode" 200 "downloading $url" $CURL_ERROR_FILE $localFile
    fi
}

#====================== Main Code ======================

# Verify input and host
ensureWeAreRoot
if ! isUbuntu18 && ! isUbuntu20; then
    fatal 1 "the host must be Ubuntu 18.x or 20.x"
fi

# Get some values from /etc/default/horizon
exchUrl=$(grep -m 1 -E '^ *HZN_EXCHANGE_URL=' /etc/default/horizon)
chk $? 'querying HZN_EXCHANGE_URL in /etc/default/horizon'
mgmtHubHost=${exchUrl#*//}   # remove the HZN_EXCHANGE_URL=http[s]:// from the front
mgmtHubHost=${mgmtHubHost%%:*}  # remove the trailing info starting at :<port>...
ocsApiUrl=$(grep -m 1 -E '^ *HZN_SDO_SVC_URL=' /etc/default/horizon)
chk $? 'querying HZN_SDO_SVC_URL in /etc/default/horizon'
ocsApiUrl=${ocsApiUrl#*HZN_SDO_SVC_URL=}
export SDO_RV_URL="http://$mgmtHubHost:$SDO_RV_PORT"

# deploy-mgmt-hub.sh registered this host as an edge node, so unregister it
if [[ $(hzn node list 2>&1 | jq -r '.configstate.state' 2>&1) == 'configured' ]]; then
    echo "Unregistering this host, because SDO will end up registering it..."
    hzn unregister -f
    chk $? 'unregistration'
    echo ''
fi

echo -e "======================== Verifying the SDO management hub component is functioning..."
httpCode=$(curl -sS -w "%{http_code}" -k -o $CURL_OUTPUT_FILE $ocsApiUrl/version 2>$CURL_ERROR_FILE)
chkHttp $? "$httpCode" 200 "getting OCS-API version" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
echo "OCS-API version: $(cat $CURL_OUTPUT_FILE)"

echo "Imported vouchers (empty list is expected initially):"
hzn sdo voucher list
chk $? "getting imported vouchers"

httpCode=$(curl -sS -w "%{http_code}" -X POST -o $CURL_OUTPUT_FILE $SDO_RV_URL/mp/113/msg/20 2>$CURL_ERROR_FILE)
chkHttp $? "$httpCode" 200 "pinging rendezvous server" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
echo "Ping response from rendezvous server:"
jq . $CURL_OUTPUT_FILE

echo -e "\n======================== Configuring this host as a simulated SDO device..."
#getUrlFile $SDO_SUPPORT_REPO/sample-mfg/simulate-mfg.sh simulate-mfg.sh
getUrlFile $SDO_SUPPORT_RELEASE/simulate-mfg.sh simulate-mfg.sh
chmod +x simulate-mfg.sh
chk $? 'making simulate-mfg.sh executable'
./simulate-mfg.sh   # the output of this is the /var/sdo/voucher.json file
chk $? 'running simulate-mfg.sh'

echo -e "\n======================== Importing the device voucher..."
if [[ ! -f node.policy.json ]]; then
    getUrlFile $OH_EXAMPLES_REPO/edge/services/helloworld/horizon/node.policy.json node.policy.json
fi
hzn sdo voucher import /var/sdo/voucher.json --policy node.policy.json
chk $? 'importing the voucher'
echo "Waiting for $SDO_TO0_WAIT seconds for sdo-owner-services to register the voucher with the rendezvous server..."
sleep $SDO_TO0_WAIT

echo -e "\n======================== Simulating booting the SDO device..."
unset HZN_DEVICE_ID   # this would conflict with the agent-install.sh -n flag
/usr/sdo/bin/owner-boot-device ibm.helloworld
chk $? 'simulating booting the device'
