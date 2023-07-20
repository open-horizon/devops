OpenHorizon Management Hub Ansible Role
=======================================

This directory contains a role and playbook to deploy the OpenHorizon Management Hub on a host.
Provided the correct environment variables and/or variables defined as a datastructure in a file,
it will stand up an OpenHorizon Management Hub deployment with little to no user input.

Introduction and Rationale
---------

Ansible is an automation tool built for use in IT environments.
It takes in variables and a "playbook", and using these, it performs the tasks on the
target hosts as needed. Variables customize the tasks, and the playbook defines a
sequence of tasks to be run on a host. Individually, tasks look much like 
a function call, where they take values as input and can emit a value as output.

Ansible is a good alternative to other installation methods because it enables the
integration of third party collections and roles into your installation codebase.
This enables you, the developer, to offload the Docker automation in your scripting
off to a community maintained project.

Ansible roles can be found on the [Ansible Galaxy](https://galaxy.ansible.com/) website.
Details of how to write Ansible playbooks and roles can be found on the
[Ansible Docs](https://docs.ansible.com/ansible/latest/index.html) site.


Requirements
------------

### For All Users

 - `ansible` 2.1 or newer
 - `python` 3.6 or newer

### For Developers

The following are reccomended:
 - `ansible-lint`
 - Visual Studio Code with the Ansible extension installed. This will use `ansible-lint` as the language server.

Using the Ansible Playbook
--------------------------

### Setting Variables

By default, passwords will be generated and defaults will be chosen based on the role's default variable file.
This is fine for testing and trying out the OpenHorizon management hub, but this isn't ideal for production.
If you want to customize the deployment, then you will need to provide your own variable file and pass it in on the command line.

Define custom variables as needed in a YAML file, call it `vars.yml`. 
For reference, see the default vars file at `roles/custom/hzn_mgmt_hub/vars/main.yml` to see the structure of vars that you can set.
 - Note: You do not need to define every variable. Ones you do not set will be initialized using the default var file.

More details about the role variables can be found in the role's README file.

You may also define these variables in the environment.
For example, to set the exchange root password, the environment variable `EXCHANGE_ROOT_PW` sets the Ansible variable `hzn_mgmt_hub.exchange.root_pw`.

### Running the Playbook

This repository contains a makefile to simplify executing ansible.
The makefile will handle the invocation of the playbook for you, as well as installing external dependencies.

#### `make install`

This will run the role in the installation mode, which installs a new instance of the management hub on the target system.

#### `make uninstall`

This will uninstall the management hub from the target system.

#### `make sync`

This will sync settings with whatever variables you pass into Ansible.
It is required that the management be installed prior to running the playbook in this mode.

### After Running

Ansible will package a file containing the generated variables encrypted in a vault after running.
The passkey to unlock the vault will be printed to the terminal.