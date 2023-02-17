# Simple makefile to invoke Ansible.

.PHONY: check_for_ansible dependencies install uninstall sync

all: install sync

# Set the Ansible inventory file to use.
HZN_MGMT_HUB_ANSIBLE_INVENTORY?=inventory.yml

# May be either Y or N
HZN_MGMT_HUB_EXPORT_VARS?=Y

# Define if you wish to load configuration partially from an environment file.
# HZN_MGMT_HUB_ENV_FILE?=

# Define if you wish to provide a vars file on the command line.
# HZN_MGMT_HUB_EXTRA_VARS_FILE?=

# ==================================
# Internal variables (do not modify)
# ==================================

ANSIBLE_GALAXY_ARGS=-r requirements.yml -p roles/

ifeq ($(HZN_MGMT_HUB_EXPORT_VARS),Y) 
	ANSIBLE_PLAY_ARGS +=-e "export_data=true"
endif

ANSIBLE_PLAY_ARGS=-i "$(HZN_MGMT_HUB_ANSIBLE_INVENTORY)"

ifdef HZN_MGMT_HUB_EXTRA_VARS_FILE
	ANSIBLE_PLAY_ARGS +=-e "@$(HZN_MGMT_HUB_EXTRA_VARS_FILE)"
endif

ifdef HZN_MGMT_HUB_ENV_FILE
	ANSIBLE_PLAY_ARGS +=-e "agent_install=true"
endif

check_for_ansible:
ifeq ($(shell which ansible-playbook),)
	$(error ansible-playbook" is not found in your PATH. Please make sure it is installed.)
endif
ifeq ($(shell which ansible-galaxy),)
	$(error ansible-galaxy" is not found in your PATH. Please make sure it is installed.)
endif

# Install required roles and collections.
dependencies: check_for_ansible
	ansible-galaxy install $(ANSIBLE_GALAXY_ARGS)

# Install the playbook.
install: dependencies
	ansible-playbook $(ANSIBLE_PLAY_ARGS) mgmt_hub.yml

uninstall: dependencies
	$(eval ANSIBLE_PLAY_ARGS +=-e "uninstall=true")
	ansible-playbook $(ANSIBLE_PLAY_ARGS) mgmt_hub.yml

sync: dependencies
	$(error Not implemented)