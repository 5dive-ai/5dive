# Linode Marketplace App: 5dive

5dive runs a team of AI agents on your own server. Agents such as Claude Code
and Codex run as always-on Linux services, share one task list, hand work to
each other and check each other's results. Link the server to the free 5dive
app to hire a team and talk to it from your phone.

## Software Included

| Software | Version | Description |
| :---     | :----   | :---        |
| 5dive CLI | newest release | The agent runtime: agents, task board, team templates |
| Bun | latest | JavaScript runtime the agents' bridges use |

**Supported Distributions:**

- Ubuntu 24.04 LTS

## Linode Helpers Included

| Name  | Action  |
| :---  | :---    |
| Hostname | Assigns a hostname from the default rDNS. |
| Sudo User | Creates a limited `sudo` user from the UDF-supplied `username` and generates its password. |
| SSH Key | Writes a UDF-supplied SSH pubkey to `/home/$username/.ssh/authorized_keys`. |
| Secure SSH | Disables password auth and root login when `disable_root` is set. |
| Update Packages | Performs standard apt update and upgrade actions as root. |
| UFW | Allows 22, 80 and 443 (the server's own HTTPS secret links) and enables the firewall. |
| Fail2Ban | Installs, activates, and enables the Fail2Ban service. |
| Addons | Optional monitoring exporters. |

## Post-Deployment

- Log in over SSH as the sudo user. The login screen shows one line: open
  https://5dive.ai/self-host to link this server to your 5dive account.
- Or set up the first agent from the command line: `sudo 5dive init`.
- The sudo password is in `/home/<sudo_user>/.credentials`.

## Use our API

Before using the commands below, create an
[API token](https://techdocs.akamai.com/linode-api/reference/get-started#create-a-personal-access-token)
and substitute your own values. `stackscript_id` is assigned when the app is accepted.

SHELL:
```
curl -H "Content-Type: application/json" \
-H "Authorization: Bearer $TOKEN" \
-X POST -d '{
    "image": "linode/ubuntu24.04",
    "region": "us-ord",
    "type": "g6-standard-2",
    "label": "5dive-us-ord",
    "root_pass": "A_Secure_Password",
    "booted": true,
    "stackscript_id": 0000000,
    "stackscript_data": {
        "user_name": "admin",
        "disable_root": "No",
        "add_ons": "none"
    }
}' https://api.linode.com/v4/linode/instances
```

## Resources

- [5dive on GitHub](https://github.com/5dive-ai/5dive)
- [Link a server to the 5dive app](https://5dive.ai/self-host)
