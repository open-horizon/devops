import os
from typing import List, Dict, Optional, Any
from enum import unique, Enum

import dotenv

from ansible.module_utils.basic import AnsibleModule

DOCUMENTATION = r"""
---
module: load_from_env

short_description: Loads the management hub configuration from env.

description: |-
    This module will search the remote environment for
    configuration information, and then add it to the
    ansible variables.

author:
    - Adam Hassick (@loudonlune)

"""

MODULE_ARGUMENTS = {
    # Facts from the initial (setup) module.
    "ansible_facts": {"type": dict, "required": True},
    # The management hub config.
    "mgmt_hub": {"type": dict, "required": True},
    "env_file": {"type": str, "required": False},
    "agent_install": {"type": str, "required": False},
}

@unique
class ConfFieldType(Enum):
    secrets = "secrets"
    config = "config"
    net = "net"

    def get_kwords(self):
        """
        Get keywords associated with the current variant.
        """
        if self == ConfFieldType.secrets:
            return ["pw", "pass", "password", "key", "auth", "token"]
        if self == ConfFieldType.net:
            return ["port", "ip", "hostname", "host"]

        return []

    @classmethod
    def get_field_type(cls, tokens: List[str]):
        """
        Resolve, for a tokenized ekey, which field type it should fall under.
        Returns a variant of this enum.
        """
        # For each variant
        for variant in cls:
            # For each keyword
            for kw in variant.get_kwords():
                # Check if it appears in the tokens.
                if kw in tokens:
                    return variant

        # The config field type is the default
        return ConfFieldType.config


class ConfPath(object):
    ACCEPT_BASE_KEYS: List[str] = [
        "anax_log_level",
        "compose_project_name",
        "hc_docker_tag",
    ]
    field_type: ConfFieldType
    key: str
    component: Optional[str] = None

    def should_ignore(self) -> bool:
        return not (
            self.component
            or self.field_type != ConfFieldType.config
            or self.key in ConfPath.ACCEPT_BASE_KEYS
        )

    def __init__(self, ekey: str):
        # Tokenize the environment key.
        tokens = ekey.lower().split("_")

        component_token = tokens[0]

        for component in ConfigLoader.COMPONENTS:
            if component_token == component:
                self.component = component

        if self.component:
            tokens = tokens[1:]

        self.field_type = ConfFieldType.get_field_type(tokens)
        self.key = "_".join(tokens)

"""
Object for manipulating the OpenHorizon Management Hub configuration variables.
It can produce a structured configuration from environment variables,
and turn a structured configuration back into environment variables, providing
some compatibility between the Ansible way of storing configuration and
the existing method for configuring OpenHorizon via the all-in-one script.

It uses some established, de facto patterns about the naming convention for
creating a structured document out of the environment variables. Most importantly, the fact that
environment variables are preceded with the name of the component they are related to.
"""
class ConfigLoader(object):
    COMPONENTS: List[str] = [
        "agbot",
        "agbot2",
        "agent",
        "css",
        "exchange",
        "hzn",
        "mongo",
        "postgres",
        "fdo",
        "oh",
        "vault",
    ]

    # Assignable fields.
    config: Dict[str, Any]
    facts: Dict[str, Any]
    arch: str
    changed: bool

    """
    Get a configuration value located at a path.
    Returns None if the value could not be found.
    """
    def get(self, path: ConfPath) -> Optional[Any]:
        sec = self.config.get(path.component) if path.component else self.config

        if type(sec) == dict \
            and (cmp := sec.get(path.field_type.value)) \
            and (val := cmp.get(path.key)):
            return val
        else:
            return None

    """
    Insert a value into the configuration.
    """
    def insert(self, path: ConfPath, value: Any):
        idict = self.config

        if path.component:
            idict = idict[path.component]

        if path.field_type.value not in idict:
            idict[path.field_type.value] = {}

        idict = idict[path.field_type.value]
        idict[path.key] = value

    def insert_environment_keys(self, env_file: str):
        # Copy the current list of environment keys.
        blacklist = list(os.environ.keys())

        dotenv.load_dotenv(env_file)

        filtered_raw_keys = filter(lambda x: x[0] not in blacklist, os.environ.items())
        unfiltered_keys = map(lambda x: (ConfPath(x[0]), x[1]), filtered_raw_keys)

        for ekey, evalue in filter(lambda x: not x[0].should_ignore(), unfiltered_keys):
            self.insert(ekey, evalue)

    def validate_config(self) -> List[str]:
        errors = []
        exchange: Dict = self.config.get("exchange")

        # If the exchange block is present...
        if exchange:
            secrets = exchange.get("secrets")

            # If the exchange block is specifying secrets...
            if secrets:
                if (
                    ("root_pw" in secrets)
                    or ("root_pw_bcrypted" in secrets)
                    and (
                        secrets.get("root_pw") is None
                        or secrets.get("root_pw_bcrypted") is None
                    )
                ):
                    errors.append(
                        "root_pw and root_pw_bcrypted must both be non-null \
                            strings, or absent from the configuration"
                    )

    def __init__(self, facts: Dict, config: Dict):
        self.config = config
        self.facts = facts
        self.changed = False

    def settings_into_env(
        self, name: Optional[str], settings: Dict[str, Any], export: bool = False
    ) -> List[str]:
        if name:
            prefix = f"{name.upper()}_"
        else:
            prefix = ""

        return list(
            map(
                lambda i: f"export {prefix}{i[0].upper()}='{i[1]}'" if export else f"{prefix}{i[0].upper()}='{i[1]}'",
                filter(lambda i: not i[1] is None, settings.items()),
            )
        )

    def component_into_env(self, name: str, config: Dict, export: bool = False) -> List[str]:
        lines: List[str] = []

        for value in config.values():
            if type(value) is dict:
                lines.extend(self.settings_into_env(name, value, export))

        return lines

    """
    Make the administrator's environment using the entire configuration.
    Returns the contents of a generated environment file.
    """
    def make_administrator_environment(self) -> str:
        lines: List[str] = [
            "# Administrator's environment file used to run deploy-mgmt-hub.sh",
            "# Usage: source <this-file>",
            "# MANAGED BY ANSIBLE! DO NOT EDIT! Edits applied to this file will not be persistent.",
            "",
        ]

        for key, value in self.config.items():
            if not type(value) is dict:
                continue

            if key in self.COMPONENTS:
                lines.extend(self.component_into_env(key, value, True))
            else:
                lines.extend(self.settings_into_env(None, value, True))

        lines.append("") # Add newline at end of file

        return "\n".join(lines)
    
    """
    Make the agent-install.cfg using only a subset of the configuration.
    Returns the contents of a generated environment file.
    """
    def make_agent_install(self) -> str:
        lines: List[str] = [
            "# agent-install.cfg",
            "# MANAGED BY ANSIBLE! DO NOT EDIT! Edits applied to this file will not be persistent.",
            "",
        ]

        # These environment variable names will be included in the agent-install.cfg only if they are present in the config.
        AGENT_INSTALL_KEYS = [
            "HZN_LISTEN_IP",
            "HZN_LISTEN_PUBLIC_IP",
            "HZN_ORG_ID",
            "HZN_EXCHANGE_URL",
            "HZN_FSS_CSSURL",
            "HZN_AGBOT_URL",
            "HZN_FDO_SVC_URL",
        ]

        # Include only needed keys in agent-install.cfg
        def cond_append(ekey: str):        
            if org_id := self.get(ConfPath(ekey)):
                lines.append(f"{ekey}='{org_id}'")
        
        for key in AGENT_INSTALL_KEYS:
            cond_append(key)

        lines.append("") # Add newline at end of file

        return "\n".join(lines)


def run_module():
    module = AnsibleModule(argument_spec=MODULE_ARGUMENTS, supports_check_mode=False)

    config: Dict = module.params["mgmt_hub"]
    facts: Dict = module.params["ansible_facts"]
    env_file: Optional[str] = module.params.get("env_file")
    agent_install: Optional[str] = module.params.get("agent_install")

    if "architecture" not in facts:
        module.fail_json("System arch not in facts.")

    loader = ConfigLoader(facts, config)

    val_msgs = loader.validate_config()
    if val_msgs:
        module.fail_json("Configuration validation failed", validation_errors=val_msgs)

    # Load the environment file.
    if env_file and os.path.isfile(env_file):
        loader.insert_environment_keys(env_file)

    # Load the agent-install (another source of environment variables).
    # The provided agent-install takes highest precedence.
    if agent_install and os.path.isfile(agent_install):
        loader.insert_environment_keys(agent_install)

    # This environment is used to run the installer.
    env_str = loader.make_administrator_environment()

    # This environment is the agent-install.cfg, safe for distribution.
    agent_install = loader.make_agent_install()

    module.exit_json(
        **{
            "changed": loader.changed,
            "hzn_mgmt_hub": loader.config,
            "administrator_env": env_str,
            "agent_install": agent_install,
        }
    )


if __name__ == "__main__":
    run_module()
