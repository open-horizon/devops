# Simple makefile to invoke Ansible.

.PHONY: check_for_ansible dependencies install uninstall sync

all: install

# Set the Ansible inventory file to use.
HZN_MGMT_HUB_ANSIBLE_INVENTORY?=inventory.ini

# May be either Y or N
HZN_MGMT_HUB_EXPORT_VARS?=Y

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

# Install the management hub.
install: dependencies
	$(eval ANSIBLE_PLAY_ARGS +=-e "install=true")
	ansible-playbook $(ANSIBLE_PLAY_ARGS) mgmt_hub.yml

# Uninstall the management hub (this is a destructive operation)
uninstall: dependencies
	$(eval ANSIBLE_PLAY_ARGS +=-e "uninstall=true")
	ansible-playbook $(ANSIBLE_PLAY_ARGS) mgmt_hub.yml

# Upgrade the management hub's containers
upgrade: dependencies
	$(eval ANSIBLE_PLAY_ARGS +=-e "upgrade=true")
	ansible-playbook $(ANSIBLE_PLAY_ARGS) mgmt_hub.yml

# Sync an existing deployment.
# Intended for updating users and groups
sync: dependencies
	ansible-playbook $(ANSIBLE_PLAY_ARGS) mgmt_hub.yml