#!/bin/bash

# Test FDO in this all-in-1 Horizon installation by:
#  - Verify fdo-owner-services is functioning properly
#  - Configure this host as a simulated FDO-enabled device
#  - Import the voucher of this device into fdo-owner-services
#  - Simulate the booting of this device, which will verify the agent has already been installed, and then register it for the helloworld edge service example

usage() {
    exitCode=${1:-0}
    cat << EndOfMessage
Usage: ${0##*/} [-c <config-file>] [-h] [-v]

Configure this host as a simulated FDO-enabled device, then simulate booting it to have FDO configure it as an edge device registered to this management hub. Note: It is assumed that you pass in the same variable customizations that you did to deploy-mgmt-hub.sh (either via environment variables or config file).

Flags:
  -c <config-file>   A config file with lines in the form variable=value that set any of the environment variables supported by this script. Takes precedence over the same variables passed in through the environment.
  -v    Verbose output.
  -h    Show this usage.

Required Environment Variables:
  HZN_EXCHANGE_USER_AUTH - user credentials to use to import the FDO voucher.

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

generateToken() { head -c 1024 /dev/urandom | base64 | tr -cd "[:alpha:][:digit:]"  | head -c $1; }

# These environment variables can be overridden
export FDO_MFG_SVC_AUTH=${FDO_MFG_SVC_AUTH:-apiUser:$(generateToken 30)}
export FDO_MFG_SVC_PORT=${FDO_MFG_SVC_PORT:-8039}
export FDO_OWN_COMP_SVC_PORT=${FDO_OWN_COMP_SVC_PORT:-9008}
export FDO_OWN_SVC_PORT=${FDO_OWN_SVC_PORT:-8042}
export FDO_RV_URL=${FDO_RV_URL:-http://fdorv.com} # set to the production domain by default. Development domain is Owner's service public key protected.
export FDO_SAMPLE_MFG_KEEP_SVCS=${FDO_SAMPLE_MFG_KEEP_SVCS:-true}
FDO_SUPPORT_RELEASE=${FDO_SUPPORT_RELEASE:-https://raw.githubusercontent.com/open-horizon/FDO-support/main/sample-mfg/start-mfg.sh}
#FDO_SUPPORT_RELEASE=${FDO_SUPPORT_RELEASE:-https://github.com/open-horizon/FDO-support/releases/latest/download}
FDO_RV_PORT=${FDO_RV_PORT:-80}
FDO_AGREEMENT_WAIT=${FDO_AGREEMENT_WAIT:-30}
FDO_TO0_WAIT=${FDO_TO0_WAIT:-10}   # number of seconds to sleep to give to0scheduler a chance to register the voucher with the RV
export FIDO_DEVICE_ONBOARD_REL_VER=${FIDO_DEVICE_ONBOARD_REL_VER:-1.1.7}
OH_EXAMPLES_REPO=${OH_EXAMPLES_REPO:-https://raw.githubusercontent.com/open-horizon/examples/master}
export SUPPORTED_REDHAT_VERSION_APPEND=${SUPPORTED_REDHAT_VERSION_APPEND:-39}
export HZN_ORG_ID=${HZN_ORG_ID:-myorg}
export HZN_LISTEN_IP=${HZN_LISTEN_IP:-127.0.0.1}
export HZN_TRANSPORT=${HZN_TRANSPORT:-http}

# Global variables for this script (not intended to be overridden)
TMP_DIR=/tmp/horizon-all-in-1
mkdir -p $TMP_DIR
CURL_OUTPUT_FILE=$TMP_DIR/curlExchangeOutput
CURL_ERROR_FILE=$TMP_DIR/curlExchangeErrors
DISTRO=${DISTRO:-$(. /etc/os-release 2>/dev/null;echo $ID $VERSION_ID)}
deviceBinaryDir='pri-fidoiot-v'$FIDO_DEVICE_ONBOARD_REL_VER

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

isUbuntu2x() {
    if [[ "$DISTRO" =~ ubuntu\ 2[0-4]\.* ]]; then
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

if [[ ${FDO_MFG_SVC_AUTH} != *"apiUser:"* || ${FDO_MFG_SVC_AUTH} == *$'\n'* || ${FDO_MFG_SVC_AUTH} == *'|'* ]]; then
    # newlines and vertical bars aren't allowed in the pw, because they cause the sed cmds below to fail
    echo "Error: FDO_MFG_SVC_AUTH must include 'apiUser:' as a prefix and not contain newlines or '|'"
    exit 1
fi

# Verify input and host
ensureWeAreRoot
if ! (isFedora || isUbuntu2x); then
    fatal 1 "the host must be Fedora 36+ or Ubuntu 2x.x"
fi

# Get some values from /etc/default/horizon
exchUrl=$(grep -m 1 -E '^ *HZN_EXCHANGE_URL=' /etc/default/horizon)
chk $? 'querying HZN_EXCHANGE_URL in /etc/default/horizon'
mgmtHubHost=${exchUrl#*//}   # remove the HZN_EXCHANGE_URL=http[s]:// from the front
mgmtHubHost=${mgmtHubHost%%:*}  # remove the trailing info starting at :<port>...
ocsApiUrl=$(grep -m 1 -E '^ *HZN_FDO_SVC_URL=' /etc/default/horizon)
chk $? 'querying HZN_FDO_SVC_URL in /etc/default/horizon'
ocsApiUrl=${ocsApiUrl#*HZN_FDO_SVC_URL=}
#export FDO_RV_URL="http://$mgmtHubHost:$FDO_RV_PORT"
export FDO_RV_URL=${FDO_RV_URL:-http://test.fdorv.com}

# deploy-mgmt-hub.sh registered this host as an edge node, so unregister it
if [[ $(hzn node list 2>&1 | jq -r '.configstate.state' 2>&1) == 'configured' ]]; then
    echo "Unregistering this host, because FDO will end up registering it..."
    hzn unregister -f
    chk $? 'unregistration'
    echo ''
fi

if [[ -d fdo || -e public_key.pem || -e owner_voucher.txt ]]; then
  rm -fr fdo public_key.pem owner_voucher.txt
fi

echo -e "======================== Verifying the FDO management hub component is functioning..."
httpCode=$(curl -sS -w "%{http_code}" -k -o $CURL_OUTPUT_FILE "$ocsApiUrl/version" 2>$CURL_ERROR_FILE)
chkHttp $? "$httpCode" 200 "getting OCS-API version" $CURL_ERROR_FILE $CURL_OUTPUT_FILE
echo "OCS-API version: $(cat $CURL_OUTPUT_FILE)"

echo "Imported vouchers (empty list is expected initially):"
hzn fdo voucher list
chk $? "getting imported vouchers"

echo -e "\n======================== Verifying FDO Rendezvous Service is functioning..."
httpCode=$(curl -sS -w "%{http_code}" -o /dev/null "$FDO_RV_URL:$FDO_RV_PORT/health" 2>$CURL_ERROR_FILE)
chkHttp $? "$httpCode" 200 "pinging rendezvous server"

echo -e "\n======================== Configuring this host as a simulated FDO device..."
echo -e "  FDO Manufacturer Service authentication credentials:"
echo -e "    export FDO_MFG_SVC_AUTH=${FDO_MFG_SVC_AUTH}"
echo -e ""
getUrlFile "$FDO_SUPPORT_RELEASE" start-mfg.sh
chmod +x start-mfg.sh
chk $? 'making simulate-mfg.sh executable'
./start-mfg.sh   # the output of this is the /var/fdo/voucher.json file
chk $? 'running simulate-mfg.sh'

echo -e "\n======================== Importing the device voucher..."
if [[ ! -f node.policy.json ]]; then
    getUrlFile "$OH_EXAMPLES_REPO/edge/services/helloworld/horizon/node.policy.json node.policy.json"
fi
hzn fdo voucher import ./owner_voucher.txt --policy node.policy.json
chk $? 'importing the voucher'
echo "Waiting for $FDO_TO0_WAIT seconds for fdo-owner-services to register the voucher with the rendezvous server..."
sleep "$FDO_TO0_WAIT"

echo -e "\n======================== Initiating TO0..."
response=$(curl -s -w "\\n%{http_code}" --digest -u "$FDO_MFG_SVC_AUTH" --location --request GET "$HZN_TRANSPORT://$HZN_LISTEN_IP:$FDO_MFG_SVC_PORT/api/v1/deviceinfo/10000" --header 'Content-Type: text/plain')
guid=$(echo $response | grep -o '"uuid":"[^"]*' | grep -o '[^"]*$')

httpCode=$(curl -sS -w "%{http_code}" -u "$HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH" --location --request GET "$HZN_TRANSPORT://$HZN_LISTEN_IP:$FDO_OWN_COMP_SVC_PORT/api/orgs/$HZN_ORG_ID/fdo/to0/$guid" --header 'Content-Type: text/plain')

echo -e "\n======================== Simulating booting the FDO device and device transfer..."
unset HZN_DEVICE_ID   # this would conflict with the agent-install.sh -n flag
cd ./fdo/$deviceBinaryDir/device || exit 1
java -jar device.jar
chk $? 'simulating booting the device'

echo -e "\n======================== Checking for an agreement..."
sleep "$FDO_AGREEMENT_WAIT"
hzn agreement list
chk $? 'agreement check'
