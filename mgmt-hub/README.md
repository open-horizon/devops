# Horizon Management Hub

## <a id=deploy-all-in-1></a> Deploy All-in-1 Horizon Management Hub, Agent, and CLI

This enables you to quickly set up a host with all of the Horizon components to facilitate learning Horizon and doing development for it.

Read the notes, and then run the following command to deploy the Horizon components on your current host.

**Notes:**

- Currently **only supported on Ubuntu 18.x, Ubuntu 20.x, and macOS**
- This script is not yet compatible with docker installed via Snap. If docker has already been installed via Snap, remove the existing docker snap and allow the script to reinstall the latest version of docker.
- The macOS support is considered **experimental** because I ran into this [docker bug](https://github.com/docker/for-mac/issues/3499) while testing. Making some of the recommended changes to my docker version and settings enabled me to get past the problem, but I'm not sure if others will hit it or not.
- The script can be run as shown without any arguments and will use reasonable defaults for everything. If you prefer, there are many environment variables that can be set to customize the deployment. See the beginning of [deploy-mgmt-hub.sh](deploy-mgmt-hub.sh) (just passed the usage and command line parsing) for all of the environment variables that can be overridden. All of the `*_PW` and `*_TOKEN` environment variables can be overridden, and any variable in the form `VAR_NAME=${VAR_NAME:-defaultvalue}` can be overridden.

As **root** run:

```bash
curl -sSL https://raw.githubusercontent.com/open-horizon/devops/master/mgmt-hub/deploy-mgmt-hub.sh | bash
```

### <a id=all-in-1-what-next></a> What To Do Next

After the Horizon components have successfully deployed, here are some commands you can run:

#### Horizon Agent Commands

- View the status of your edge node: `hzn node list`
- View the agreement that was made to run the helloworld edge service example: `hzn agreement list`
- View the edge service containers that Horizon started: `docker ps`
- View the log of the helloworld edge service: `hzn service log -f ibm.helloworld`
- View the Horizon configuration: `cat /etc/default/horizon`
- View the Horizon agent daemon status: `systemctl status horizon`
- View the steps performed in the agreement negotiation process: `hzn eventlog list`
- View the node policy that was set that caused the helloworld service to deployed: `hzn policy list`

#### Horizon Exchange Commands

To view resources in the Horizon exchange, first export environment variables `HZN_ORG_ID` and `HZN_EXCHANGE_USER_AUTH` as instructed in the output of `deploy-mgmt-hub.sh`. Then you can run these commands:

- View all of the `hzn exchange` sub-commands available: `hzn exchange --help`
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

#### Horizon Exchange System Org Commands

You can view more resources in the system org by switching to the admin user in that org:

```bash
export HZN_ORG_ID=IBM   # or whatever org name you customized EXCHANGE_SYSTEM_ORG to
export HZN_EXCHANGE_USER_AUTH=admin:<password>   # the pw the script displayed, or what you set EXCHANGE_SYSTEM_ADMIN_PW to
```

Then you can run these commands:

- View the user in the system org: `hzn exchange user list`
- View the agbot: `hzn exchange agbot list`
- View the deployment policies the agbot is serving: `hzn exchange agbot listdeploymentpol agbot`
- View the patterns the agbot is serving: `hzn exchange agbot listpattern agbot`

#### Horizon Hub Admin Commands

The hub admin can manage Horizon organizations (creating, reading, updating, and deleting them). Switch to the hub admin user:

```bash
export HZN_ORG_ID=root
export HZN_EXCHANGE_USER_AUTH=hubadmin:<password>   # the pw the script displayed, or what you set EXCHANGE_HUB_ADMIN_PW to
```

Then you can run these commands:

- List the organizations: `hzn exchange org list`
- Create a new organization: `hzn exchange org create -d 'my new org' -a IBM/agbot myneworg`
- Configure the agbot to be able to use the example services from this org: `hzn exchange agbot addpattern IBM/agbot IBM '*' myneworg`
- View the patterns the agbot is serving: `hzn exchange agbot listpattern IBM/agbot`
- View the deployment policies the agbot is serving: `hzn exchange agbot listdeploymentpol IBM/agbot`

### <a id=try-sdo></a> Try Out SDO

[Intel's SDO](https://software.intel.com/en-us/secure-device-onboard) (Secure Device Onboard) technology can configure an edge device and register it with a Horizon instance automatically. Although this is not really necessary in this all-in-1 environment (because the agent has already been registered), you can easily try out SDO to see it working.

**Note:** SDO is currently only supported in this all-in-1 environment on Ubuntu.

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
