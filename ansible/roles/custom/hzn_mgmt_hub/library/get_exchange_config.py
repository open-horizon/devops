from ansible.module_utils.basic import AnsibleModule
import subprocess
from typing import List, Dict, Tuple
import json

DOCUMENTATION = r"""
---
module: load_from_env

short_description: Loads the management hub configuration from env.

description: |-
    This module is used to load needed configuration information
    from the Exchange.

author:
    - Adam Hassick (@loudonlune)

"""

MODULE_ARGUMENTS = {
    "root_credentials": {"type": str, "required": True},
    "config": {"type": dict, "required": True},
}


class ExchangeConfigAggregator(object):
    __root_credentials: str

    def make_exchange_call(self, *args, serialize_stdout=True):
        """
        Call into OpenHorizon with some arguments.
        """
        real_args = ["hzn", "exchange"]
        real_args.extend(list(args))

        result: subprocess.CompletedProcess = subprocess.run(
            real_args,
            env={"HZN_EXCHANGE_USER_AUTH": self.__root_credentials},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        result.check_returncode()

        if serialize_stdout:
            return json.loads(result.stdout)
        else:
            return result.stdout

    def __init__(self, root_credentials: str):
        self.__root_credentials = root_credentials

    def get_users_and_orgs(self) -> Dict[str, List[str]]:
        orgs: List[str] = self.make_exchange_call("org", "list")
        final_config: Dict[str, List[str]] = dict()

        for org in orgs:
            users = self.make_exchange_call("user", "list", "-o", org, "--all")
            final_config[org] = users

        return final_config


def run_module():
    module = AnsibleModule(argument_spec=MODULE_ARGUMENTS, supports_check_mode=False)

    delta = {}

    root_credentials = module.params["root_credentials"]
    expected_config = module.params["config"]

    expected_orgs = dict(map(lambda x: (x["name"], x), expected_config["orgs"]))

    aggregator = ExchangeConfigAggregator(root_credentials)

    try:
        config = aggregator.get_users_and_orgs()
    except subprocess.CalledProcessError as e:
        module.fail_json(
            "Failed to interact with the exchange",
            stdout=e.stdout,
            stderr=e.stderr,
            returncode=e.returncode,
        )

    # Get organizations to remove (organizations in exchange that are not in the config)
    delta["remove_orgs"] = list(
        filter(lambda x: x not in expected_orgs and x != "root", config.keys())
    )
    # Get organizations to add (organizations in the config that are not in the exchange)
    delta["add_orgs"] = list(
        map(
            lambda x: x[1],
            filter(lambda x: x[0] not in config.keys(), expected_orgs.items()),
        )
    )

    remove_users = []
    add_users = []

    for org, users in config.items():
        if org in delta["remove_orgs"] or org == "root":
            continue

        expected_org_state: Dict = expected_orgs[org]["users"]
        expected_usernames: List[Tuple[Dict, str]] = list(
            map(lambda x: ({**x, "org": {"name": org}}, f"{org}/{x['name']}"), expected_org_state)
        )

        add_users.extend([x[0] for x in expected_usernames if x[1] not in users.keys()])

        for user_id, properties in users.items():
            if user_id not in expected_usernames:
                remove_users.append({"name": user_id, "org": org})
            else:  # See if user specific settings have changed (as in, admin being set to false and the present account has it set to true)
                pass

    delta["remove_users"] = remove_users
    delta["add_users"] = add_users

    module.exit_json(
        **{"changed": False, "present_configuration": config, "delta": delta}
    )


if __name__ == "__main__":
    run_module()
