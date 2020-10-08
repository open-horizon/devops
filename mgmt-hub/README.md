# Horizon Management Hub

## <a id=deploy-all-in-1></a> Deploy All-in-1 Horizon Management Hub, Agent, and CLI

This enables you to quickly set up a host with all of the Horizon components to facilitate learning Horizon and doing development for it.

Run the following command to deploy the Horizon components on your current host.

**Notes:**

- This is currently **only supported on Ubuntu 18.x and macOS**
- The command below must be **run as root**. If you need to use **sudo** to become root, run `sudo -i`, and then run the command below as shown.
- If running on **macOS**:
  - You must [install docker](https://docs.docker.com/docker-for-mac/install) yourself before running this script.
  - You must install prerequisites: jq, gettext, and socat. If you have [brew](https://brew.sh/) installed, you can install these prerequisites with: `brew install jq gettext socat`
  - The macOS support is considered **experimental** because I ran into this [docker bug](https://github.com/docker/for-mac/issues/3499) while testing. I made some of the recommended changes to this script and made some recommended changes to my docker settings (removed all the File Sharing paths except /private, disabled debug and experimental, and moved up to the Edge release). This enabled me to get past the problem, but I'm not sure if others will hit it or not.
- The script can be run without any arguments and will use reasonable defaults for everything. If you prefer, there are many environment variables that can be set to customize the deployment. See the beginning of [deploy-mgmt-hub.sh](deploy-mgmt-hub.sh) (just passed the usage and command line parsing) for all of the environment variables that can be overridden. All of the `*_PW` and `*_TOKEN` environment variables can be overridden, and any variable in the form `VAR_NAME=${VAR_NAME:-defaultvalue}` can be overridden.

```bash
curl -sSL https://raw.githubusercontent.com/open-horizon/devops/master/mgmt-hub/deploy-mgmt-hub.sh | bash
```

### <a id=all-in-1-what-next></a> What To Do Next

After the Horizon components have successfully deployed, here are some commands you can run:

- View the status of your edge node: `hzn node list`
- View the agreement that was made to run the helloworld edge service example: `hzn agreement list`
- View the edge service containers that Horizon started: `docker ps`
- View the log of the helloworld edge service: `hzn service log -f ibm.helloworld`
- View the Horizon configuration: `cat /etc/default/horizon`
- View the Horizon agent daemon status: `systemctl status horizon`
- View the steps performed in the agreement negotiation process: `hzn eventlog list`
- View the node policy that was set that caused the helloworld service to deployed: `hzn policy list`

To view resources in the Horizon exchange, first export environment variables `HZN_ORG_ID` and `HZN_EXCHANGE_USER_AUTH` as instructed in the output of `deploy-mgmt-hub.sh`.

Then you can run these commands:

- View all of the `hzn` sub-commands available: `hzn --help`
  - You can view help on specific sub-commands too, for example: `hzn exchange service --help`
- View the example edge services: `hzn exchange service list IBM/`
- View the example patterns: `hzn exchange pattern list IBM/`
- View the example deployment policies: `hzn exchange deployment listpolicy`
- Verify the policy matching that resulted in the helloworld service being deployed: `hzn deploycheck all -b policy-ibm.helloworld_1.0.0`
- View your node: `hzn exchange node list`
- View your user in your org: `hzn exchange user list`
- Use the verbose flag to view the exchange REST APIs the `hzn` command calls, for example: `hzn exchange user list -v`
- Create an MMS file:

  ```bash
  cat << EOF > mms-meta.json
  {
    "objectID": "mms-file",
    "objectType": "stuff",
    "destinationOrgID": "$HZN_ORG_ID",
    "destinationType": "pattern-ibm.helloworld"
  }
  EOF
  echo -e "foo\nbar" > mms-file
  hzn mms object publish -m mms-meta.json -f mms-file
  ```

- View the meta-data of the file: `hzn mms object list -d`
- Get the file: `hzn mms object download -t stuff -i mms-file -f mms-file.downloaded`

You can view more resources in the Horizon org by changing the environment variables:

```bash
export HZN_ORG_ID=IBM   # or whatever org name you customized it to
export HZN_EXCHANGE_USER_AUTH=admin:<password>
```

Then you can run these commands:

- View the user in the Horizon org: `hzn exchange user list`
- View the agbot: `hzn exchange agbot list`
- View the deployment policies the is agbot serving: `hzn exchange agbot listdeploymentpol agbot`
- View the patterns the is agbot serving: `hzn exchange agbot listpattern agbot`

### <a id=try-sdo></a> Try Out SDO

[Intel's SDO](https://software.intel.com/en-us/secure-device-onboard) (Secure Device Onboard) technology can configure an edge device and register it with a Horizon instance automatically. Although this is not really necessary in this all-in-1 environment, because the agent has already been registered, you can easily try out SDO to see it working. **Note:** SDO doesn't make sense on a Mac, so it is only supported in this all-in-1 environment on Ubuntu 18.x.

Export these environment variables:

```bash
export HZN_ORG_ID=myorg   # or whatever org name you customized it to
export HZN_EXCHANGE_USER_AUTH=admin:<password>
```

Run the SDO test script:

```bash
./test-sdo.sh
```

You will see the script do these steps:

- Unregister the agent (so SDO can register it)
- Verify the SDO management hub component is functioning properly
- Configure this host as a simulated SDO-enabled device
- Import the voucher of this device into the SDO management hub component
- Simulate the booting of this device, which will verify the agent has already been installed, and then register it for the helloworld edge service example

### <a id=all-in-1-pause></a> "Pausing" The Services

The Horizon management hub services and edge agent use some CPU even in steady state. If you don't need them for a period of time, you can stop the containers by running:

```bash
./deploy-mgmt-hub.sh -S
```

When you want to use the Horizon management hub services and edge agent again, you can start them by running:

```bash
./deploy-mgmt-hub.sh -s
```
