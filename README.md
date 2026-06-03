# Zabbix Agent Deployment Script

An interactive Bash script that installs and configures the Zabbix agent (or
Zabbix agent 2) on a Linux host, mirroring the workflow of the official
[Zabbix download page](https://www.zabbix.com/download) but automating the
package install **and** the agent configuration in a single run.

You pick the version, distribution, OS version, and component; the script adds
the official Zabbix repository, installs the agent, writes the connection
settings into the config file, and starts the service.

## Features

- Interactive menu selection for Zabbix version, OS distribution, OS version, and component.
- Auto-detects the OS version from `/etc/os-release` and offers it as the default.
- Probes the Zabbix repository to find the correct package URL automatically — handles the differing repo layouts across versions (e.g. `7.2`/`7.4` use a `release/` path, `7.0`/`6.0` do not) instead of hard-coding one shape.
- Applies your organization's connection settings (`Server`, `ListenPort`, `ServerActive`) from variables at the top of the script.
- Prompts interactively for the agent `Hostname`.
- Idempotent config editing: existing active directives are replaced (never duplicated), and the commented documentation in the config file is preserved.
- Backs up the original config before making changes.
- Fails fast with clear messages — a bad version/OS combination or a failed download stops the run before anything is changed.

## What it does

| Step | Action |
|------|--------|
| 1 | Interactively select **Zabbix version**, **OS distribution**, **OS version**, **component** |
| 2 | Add the Zabbix **repository** and install the **agent package** |
| 3 | Set `Server=` (passive server / allowed incoming hosts) |
| 4 | Set `ListenPort=` |
| 5 | Set `ServerActive=` (active-check server, with port) |
| 6 | Set `Hostname=` (asked interactively) |
| 7 | **Start** the agent and **enable** it at boot |

## Supported platforms

- Ubuntu / Debian (`apt`, `.deb`)
- RHEL / CentOS / Rocky Linux / AlmaLinux / Oracle Linux (`dnf` / `yum`, `.rpm`)
- SLES / openSUSE (`zypper`, `.rpm`)

## Requirements

- Root privileges (`sudo`).
- `wget` or `curl` available on the host.
- Network access to `repo.zabbix.com`.

## Usage

```bash
chmod +x zabbix-agent-install.sh
sudo ./zabbix-agent-install.sh
```

Follow the prompts. At the OS-version prompt, enter the **number only**
(e.g. `24.04`, `12`, `9`, `15`) — the detected default is usually correct, so
pressing Enter is fine.

## Configuration

The connection settings applied to every host are defined near the top of the
script. Edit them once for your environment:

```bash
PASSIVE_SERVER="zabbix.example.com"          # -> Server=
LISTEN_PORT="20050"                          # -> ListenPort=
SERVER_ACTIVE="zabbix.example.com:20051"     # -> ServerActive=
```

The `Hostname` is not set here — it is requested interactively at runtime and
defaults to the machine's short hostname. It must match the host name
configured for this host in the Zabbix frontend.

The component you choose determines the paths used:

| Component | Package | Service | Config file |
|-----------|---------|---------|-------------|
| Zabbix agent 2 | `zabbix-agent2` | `zabbix-agent2` | `/etc/zabbix/zabbix_agent2.conf` |
| Zabbix agent | `zabbix-agent` | `zabbix-agent` | `/etc/zabbix/zabbix_agentd.conf` |

## Example

```
Select Zabbix version:
  1) 7.4
  2) 7.2
  3) 7.0 (LTS)
  4) 6.0 (LTS)
Select [1-4]: 3
...
=====================  REVIEW  =====================
  Zabbix version : 7.0
  Distribution   : Debian 12
  Component       : Zabbix agent 2
  Package        : zabbix-agent2
  Service        : zabbix-agent2
  Config file    : /etc/zabbix/zabbix_agent2.conf
  Repo package   : https://repo.zabbix.com/.../zabbix-release_latest_7.0+debian12_all.deb
  Config to apply:
    Server        = zabbix.example.com
    ListenPort    = 20050
    ServerActive  = zabbix.example.com:20051
    Hostname      = TUG-PVE
====================================================
Proceed? (yes/no) [yes]:
```

## Notes

- **Firewall:** passive checks reach the agent on `ListenPort` (default `20050`
  in this script). If a firewall is active, allow that port from the Zabbix
  server, e.g. `ufw allow 20050/tcp` or the `firewalld` equivalent.
- **Agent 2 plugins:** on some versions the `zabbix-agent2-plugin-*` packages
  do not exist (the functionality is built in). The script attempts to install
  them and only warns if they are unavailable — the core agent still installs.
- **Re-running:** the config editor is idempotent, so running the script again
  will not create duplicate directives.

## Disclaimer

Provided as-is. Review the script and test on a non-production host before
rolling it out across a fleet.
