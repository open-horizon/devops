# Horizon Management Hub

## <a id=deploy-all-in-1></a> Deploy All-in-1 Horizon Management Hub, Agent, and CLI

This enables you to quickly set up a host with all of the Horizon components to facilitate learning Horizon and doing development for it.

Note: before deploying Horizon, you can set the passwords that should be used if you want to have easy to remember passwords. (If you don't set them, random passwords will be generated and displayed to you.) See the beginning of [deploy-mgmt-hub.sh](deploy-mgmt-hub.sh) for all of the settings that can be customized.

Deploy the Horizon components on your current host (currently **only Ubuntu 18.04** is supported for this method of deployment):

```bash
curl -sSL https://raw.githubusercontent.com/open-horizon/devops/master/mgmt-hub/deploy-mgmt-hub.sh | bash -
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
- Verify the policy matching that resulted in the helloworld service being deployed: `hzn deploycheck all`

To view resources in the Horizon exchange, first export these environment variables:

```bash
HZN_ORG_ID=myorg   # or whatever org name you customized it to
HZN_EXCHANGE_USER_AUTH=admin:<password>
```

Then you can run these commands:

- View all of the `hzn` sub-commands available: `hzn --help`
  - You can view help on specific sub-commands too, for example: `hzn exchange service --help`
- View the example edge services: `hzn exchange service list IBM/`
- View the example patterns: `hzn exchange pattern list IBM/`
- View the example deployment policies: `hzn exchange deployment listpolicy`
- View your node: `hzn exchange node list`
- View your user in your org: `hzn exchange user list`
- Use the verbose flag to view the exchange REST APIs the `hzn` command calls, for example: `hzn exchange user list -v`

You can view more resources in the Horizon org by changing the environment variables:

```bash
HZN_ORG_ID=IBM   # or whatever org name you customized it to
HZN_EXCHANGE_USER_AUTH=admin:<password>
```

Then you can run these commands:

- View the user in the Horizon org: `hzn exchange user list`
- View the agbot: `hzn exchange agbot list`
- View the deployment policies the is agbot serving: `hzn exchange agbot listdeploymentpol agbot`
- View the patterns the is agbot serving: `hzn exchange agbot listpattern agbot`
