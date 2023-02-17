
DOCUMENTATION = r'''
---
module: load_from_env

short_description: Loads the management hub configuration from env.

description: |-
    This module will search the remote environment for
    configuration information, and then add it to the
    ansible variables.

author:
    - Adam Hassick (@loudonlune)

'''

MODULE_ARGUMENTS = {
    # Facts from the initial (setup) module.
    'ansible_facts': {
        'type': dict,
        'required': True
    },
    # The management hub config.
    'mgmt_hub': {
        'type': dict,
        'required': True
    },
    'env_file': {
        'type': str,
        'required': False
    }
}

import os
import random
import string
from typing import List, Dict, Union, Optional, Callable, Any

import dotenv

from ansible.module_utils.basic import AnsibleModule

def key_to_env(key: str, prefix: Optional[str]) -> str:
    if prefix:
        return f"{prefix.upper()}_{key.upper()}"
    else:
        return key.upper()


PASSWD_DOMAIN = string.ascii_letters + string.digits

MkdefaultFn = Optional[Callable[[ Dict ], str]]

class ConfigLoader(object):
    # Static fields.
    SECRET_FIELD: str = 'secrets'
    DOCKER_FIELD: str = 'docker'
    CONFIG_FIELD: str = 'config'
    COMPONENTS: List[str] = [
        'agbot',
        'agbot2',
        'agent',
        'css',
        'exchange',
        'hzn',
        'mongo',
        'postgres',
        'sdo',
        'vault'
    ]

    # Assignable fields.
    config: Dict[str, Any]
    facts: Dict[str, Any]
    arch: str
    changed: bool

    # Generate a random password from the input list above.
    @staticmethod
    def gen_secret(length: int) -> str:
        return ''.join([ random.choice(PASSWD_DOMAIN) for _ in range(0, length) ])


    def get_or_else(self, 
                    #parent: Dict, 
                    key: str, 
                    value: Optional[str], 
                    mkdefault: MkdefaultFn) -> Optional[str]:
        field = os.environ.get(key)

        if field:       # Environment takes top precedence.
            return field
        elif value:     # Then the configuration.
            return value
        elif mkdefault: # Then try making a default.
            # Set the generated flag.
            # parent[f"{key}_generated"] = "1"
            return mkdefault(self.facts)
        else:           # Otherwise just return null.
            return None


    def validate_config(self) -> List[str]:
        errors = []
        exchange = self.config.get('exchange')

        # If the exchange block is present...
        if exchange:
            secrets = self.config.get('secrets')
            
            # If the exchange block is specifying secrets...
            if secrets:
                if (('root_pw' in secrets) or ('root_pw_bcrypted' in secrets)
                    and (secrets.get('root_pw') == None or secrets.get('root_pw_bcrypted') == None)):
                    errors.append(
                        'root_pw and root_pw_bcrypted must both be non-null strings, or absent from the configuration'
                    )

    def __init__(self, facts: Dict, config: Dict):
        self.config = config
        self.facts = facts
        self.changed = False


    def update_settings(self, name: Optional[str], settings: Dict[str, str], mkdefault: MkdefaultFn = None):
        for key in settings.keys():
            settings.update(**{key: self.get_or_else(
                #settings, 
                key_to_env(key, name), 
                settings[key], 
                mkdefault)})


    def update_component(self, name: str, config: Dict[str, Union[str, Dict[str, str]]]):
        gen_secret_lambda = lambda _: ConfigLoader.gen_secret(30)

        for (key, value) in config.items():
            if key == self.SECRET_FIELD:
                self.update_settings(name, value, mkdefault=gen_secret_lambda)
            elif type(value) is dict:
                self.update_settings(name, value)


    def update(self):
        for (key, value) in self.config.items():
            if not type(value) is dict:
                continue

            if key in self.COMPONENTS:
                self.update_component(key, value)
            else:
                self.update_settings(None, value)


    def settings_into_env(self, name: Optional[str], settings: Dict[str, Any]) -> List[str]:
        if name:
            prefix = f"{name.upper()}_"
        else:
            prefix = ""

        return list(
            map(
                lambda i: f"{prefix}{i[0].upper()}=\"{i[1]}\"",
                filter(
                    lambda i: not i[1] is None,
                    settings.items()
                )
            )
        )

    def component_into_env(self, name: str, config: Dict) -> List[str]:
        lines: List[str] = []

        for value in config.values():
            if type(value) is dict:
                lines.extend(self.settings_into_env(name, value))

        return lines

    def into_env(self) -> str:
        lines: List[str] = []

        for (key, value) in self.config.items():
            if not type(value) is dict:
                continue

            if key in self.COMPONENTS:
                lines.extend(self.component_into_env(key, value))
            else:
                lines.extend(self.settings_into_env(None, value))

        return '\n'.join(lines)        
        

def run_module():
    module = AnsibleModule(
        argument_spec=MODULE_ARGUMENTS,
        supports_check_mode=False
    )

    config: Dict = module.params['mgmt_hub']
    facts: Dict = module.params['ansible_facts']
    env_file: Optional[str] = module.params.get('env_file')

    if not 'architecture' in facts:
        module.fail_json('System arch not in facts.')

    loader = ConfigLoader(facts, config)

    validation_msgs = loader.validate_config()
    if validation_msgs:
        module.fail_json('Configuration validation failed', validation_errors=validation_msgs)

    # If the env_file is present, load it into the environment and update the config.
    if env_file and os.path.isfile(env_file):
        dotenv.load_dotenv(env_file)
        loader.update()
    

    env_str = loader.into_env()

    module.exit_json(**{
        'changed': loader.changed,
        'hzn_mgmt_hub': loader.config,
        'env_script': env_str
    })

if __name__ == "__main__":
    run_module()
