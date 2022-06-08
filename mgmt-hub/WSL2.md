# Windows WSL2 Installation Instructions

## WSL2 is required

Note that WSL2 (i.e., version 2 of Windows Subsystemn for Linux) is required. Virtualization support must also be enabled for WSL2. If you do not have WSL2 installed and verified, please follow the official Windows WSL2 instructions to install and verify WSL2 with an official WSL2 ubuntu image:

	https://docs.microsoft.com/en-us/windows/wsl/install

## Docker Desktop is Required

Docker Desktop must also be installed and integrated with WSL2. If yoou have not yet configured this, please follow the official Docker instructions to install and verify Docker Desktop with WSL2:

	https://docs.docker.com/desktop/windows/install/

## Simulating `systemd`

The Open Horizon scripts use `systemd` to deploy daemon processes but the WSL2 ubuntu image uses `init.d` as PID 1 instead of `systemd`. This prevents the installation of our daemons. We found a work-around for this that simuulates a `systemd` environment in a WSL2 ubuntu environment.

In a **WSL2 terminal shell**, run these commands to modify your WSL2 ubuntu to simuulate `systemd`:

```bash
sudo apt update

cd /tmp
wget --content-disposition \
  "https://gist.githubusercontent.com/djfdyuruiry/6720faa3f9fc59bfdf6284ee1f41f950/raw/952347f805045ba0e6ef7868b18f4a9a8dd2e47a/install-sg.sh"

chmod +x /tmp/install-sg.sh

/tmp/install-sg.sh && rm /tmp/install-sg.sh
```

Exit the WSL2 terminal and shutdown the WSL2 environment by running the commnand below in a **Windows `cmd` shell**:

```wsl --shutdown```

Now you can open a new **WSL2 terminal shell** where `systemd` is being simulated:

```genie -l```

Test that the `systemd` suupport is working by running this command. It should run without error:

```sudo systemctl status time-sync.target```

### Other Required `systemd` Units?

It is recommended that you also run the command below to discover any `systemd` units that did not start up in this simulated environment:
 
```systemctl list-units --failed```

If you see any units in that list that you think are required, you may be able to fix them using recipes in this wiki:

	https://github.com/arkane-systems/genie/wiki/Systemd-units-known-to-be-problematic-under-WSL

## Prepare to Install the Management Hub

If you have previously setup a Manageement Hub on this node, use  Docker Desktop to remove all of those old containers before contiunuing.

### Become `root` to install the Management Hub

In a **WSL2 terminal shell**, run 

```
sudo -i
```

### Download, modify, then run the installer

Instead of using the command shown in the main README.md to start the All-In-One setup, it is recommnded in the WSL2 environment to first install only the Manageement Hub, then separately install the Agent, if desired. Follow these steps to install the Management Hub (as `root`): 
 
```bash
curl -sSL https://raw.githubusercontent.com/open-horizon/devops/master/mgmt-hub/deploy-mgmt-hub.sh -o deploy-mgmt-hub.sh
```
Open the script in test editor of choice, set ```EXCHANGE_WAIT_ITERATIONS``` to ```120```

Run this command (as `root`) to install the Management Hub but **not** install the Agent:

```bash
./deploy-mgmt-hub.sh -A
```

Save the output of that command so you can retrieve the credentials required to interact witth youor new Management Hub. It is recommended that you create a credential file (e.g., `mycreds`) as follows, filling in values from that output:

```bash
export HZN_EXCHANGE_URL=http://127.0.0.1:3090/v1
export HZN_FSS_CSSURL=http://127.0.0.1:3090/edge-css
export HZN_ORG_ID=myorg
export HZN_DEVICE_TOKEN=<get from output>
export EXCHANGE_ROOT_PW==<get from output>
export EXCHANGE_HUB_ADMIN_PW=<get from output>
export EXCHANGE_SYSTEM_ADMIN_PW=<get from output>
export EXCHANGE_USER_ADMIN_PW=<get from output>
export HZN_EXCHANGE_USER_AUTH=admin:<get from output>
export AGBOT_TOKEN=<get from output>
export VAULT_UNSEAL_KEY=<get from output>
export VAULT_ROOT_TOKEN=<get from output>
```

## Installing the agent

Export the credentials from above into the current shell, e.g.:

```source mycreds```

Once those variables are in your environment, you can download the Agent installer in the normal way, e.g.:

```bash
curl -u "$HZN_ORG_ID/$HZN_EXCHANGE_USER_AUTH" -k -o agent-install.sh $HZN_FSS_CSSURL/api/v1/objects/IBM/agent_files/agent-install.sh/data
chmod +x agent-install.sh
```

Then just use the normal Agent install process, e.g.:

```bash
sudo -s -E ./agent-install.sh -i 'css:' -T 120
```

## WSL2 Notes

If you are getting errors running commands in your WSL2 terminal, ensure you are inside the genie (simulated `systemd`) shell by running:

```genie -b```

## Credits

Thanks to [Demopans](https://github.com/Demopans) for figuring out how to use this tooling uunder WSL2.

