# Multiple SQL Server instances on one Linux host, with plain systemd

Microsoft does not support more than one SQL Server instance per Linux host:

> **Does SQL Server on Linux support multiple instances on the same host?** No, we don't
> support multiple instances on the same host machine. If you need to run multiple instances
> on the same host, we recommend using multiple containers.
> — [SQL Server on Linux FAQ](https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-faq)

There is also no Windows-style "named instance" concept: `sqlservr` has no `InstanceName`
and `mssql-conf` has no `setup` mode for a second instance. What it *does* have is a single
hard-coded root directory for everything it owns:

```
ConfigFile=/var/opt/mssql/mssql.conf
SystemDirectory=/var/opt/mssql/.system
/var/opt/mssql/data/master.mdf
/var/opt/mssql/log/errorlog
,var/opt/mssql/secrets/
/var/opt/mssql/security/ca-certificates
```

Those paths are compiled into `/opt/mssql/bin/sqlservr`. So instead of trying to convince the
engine to use different directories, this setup gives each extra instance a **private mount
namespace** in which its own directory is mounted *at* `/var/opt/mssql`. Every hard-coded path
then resolves inside that instance's own tree, and the engine never sees the other instances.
That is one systemd directive:

```ini
BindPaths=/var/opt/mssql-instances/%i:/var/opt/mssql
```

No Docker, no VMs, no patched binaries, one shared read-only copy of `/opt/mssql`.

---

## Files

| File                         | Purpose                                                                                                          |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `mssql-server@.service`    | Template unit for additional instances (`mssql-server@<name>.service`). Installed to `/etc/systemd/system/`. |
| `mssql-base-install.sh`    | Installs and initializes the packaged ("base") instance on a host that does not have it yet.                      |
| `mssql-base-remove.sh`     | Uninstalls everything again: instances, package, data and the Microsoft apt source.                                |
| `mssql-instance-add.sh`    | Creates and initializes a new instance.                                                                          |
| `mssql-instance-manage.sh` | Lists instances and does start / stop / restart / logs, interactively or from the command line.                  |
| `mssql-instance-conf.sh`   | Runs`mssql-conf` against a specific instance instead of the packaged one.                                      |
| `mssql-instance-remove.sh` | Stops/disables an instance, optionally deleting its data.                                                        |

Keep the files in the same directory — `mssql-instance-add.sh` locates the unit template next to itself.

## Fresh host: install the base instance

The rest of this README assumes the packaged instance is already there. On a new machine
`mssql-base-install.sh` puts it there — it adds the Microsoft apt repository and signing key when
apt has no candidate, installs `mssql-server`, and runs the usual non-interactive setup:

```bash
sudo MSSQL_SA_PASSWORD='Str0ng!Passw0rd' ./mssql-base-install.sh      # install + set up
sudo ./mssql-base-install.sh                                          # later: report only
sudo MSSQL_SA_PASSWORD='Str0ng!Passw0rd' ./mssql-base-install.sh --pid Developer --port 1433 --yes
sudo ./mssql-base-install.sh --version 2022 --repo ubuntu/22.04        # hand-pick the repo
sudo ./mssql-base-install.sh --force                                   # run setup again
```

It auto-detects the distro release and installs the newest SQL Server release Microsoft publishes
for it — Ubuntu 24.04 and 22.04 get `mssql-server-2025`, 20.04 gets `mssql-server-2022`, 18.04
gets `mssql-server-2019` (pin a specific one with `--version`). The extra instances are stopped for
the duration of the install, because they share `/opt/mssql`, and started again afterwards.
Options: `--pid`, `--port`, `--password`, `--version`, `--repo`, `--force`, `--yes`; the same
values can come from `MSSQL_PID`, `MSSQL_TCP_PORT`, `MSSQL_SA_PASSWORD` and `MSSQL_VERSION`.

Repo setup is skipped when apt already offers `mssql-server` (the normal case on a host that has
this package from a previous install) and the official Microsoft repo config is used otherwise.
Note that the engine is only packaged for the distributions Microsoft supports — Debian gets the
tools but not `mssql-server`, so pass `--repo <family>/<release>` if you know better.

On a host that is already installed *and* configured it prints the current state and exits without
touching anything; `--force` is what re-runs `mssql-conf setup` (that resets the sa password and
re-applies the edition and port).

## Starting over: remove the base instance

`mssql-base-remove.sh` is the counterpart, for testing the install script on a host that already
has SQL Server, or for cleaning a machine up:

```bash
sudo ./mssql-base-remove.sh --dry-run      # print the plan, change nothing
sudo ./mssql-base-remove.sh                # asks you to type 'erase' before deleting data
sudo ./mssql-base-remove.sh --yes          # no questions
sudo ./mssql-base-remove.sh --keep-data    # uninstall the package, keep every database
```

It stops and disables the base instance and every `mssql-server@*` instance, purges the package
(which removes `/opt/mssql`), deletes the unit template, and removes the apt source and signing key
so that the next install also exercises the repository setup. Unless `--keep-data` is given it also
deletes `/var/opt/mssql` and `/var/opt/mssql-instances` — **that is every database on the host**.
It leaves the `mssql` user/group and any `sqlcmd` packages alone, and it refuses to delete a keyring
that another apt source (VS Code, for instance) still refers to.

## Quick start

```bash
cd mssql-multi-instance
chmod +x mssql-*.sh

# create instance "mssql2" listening on 1434 (Express by default)
sudo MSSQL_SA_PASSWORD='Str0ng!Passw0rd' ./mssql-instance-add.sh mssql2 1434

# a third one
sudo MSSQL_SA_PASSWORD='An0ther!Passw0rd' ./mssql-instance-add.sh mssql3 1435
```

The script:

1. creates `/var/opt/mssql-instances/<name>` (owned `mssql:mssql`, mode 770),
2. stops the packaged `mssql-server` (mandatory — `mssql-conf` refuses to initialize while
   an instance is running; it is started again at the end),
3. runs `mssql-conf -n setup` inside a transient unit with the same `BindPaths=`, passing
   `ACCEPT_EULA=Y`, `MSSQL_PID`, `MSSQL_SA_PASSWORD` and `MSSQL_TCP_PORT`,
4. installs the template unit and does `systemctl enable --now mssql-server@<name>`,
5. waits for the port to come up and prints a summary.

Each instance ends up with its own `mssql.conf`, `master`/`model`/`msdb`/`tempdb`, machine
key, certificates and error log. Nothing is shared but the binaries.

## Verify

```bash
sudo ./mssql-instance-manage.sh list          # all instances, state, port, PID
sudo systemctl status mssql-server mssql-server@mssql2
ss -lntp | grep -E '1433|1434'

sudo apt-get install -y mssql-tools18 unixodbc-dev   # if sqlcmd is missing
/opt/mssql-tools18/bin/sqlcmd -S localhost,1433 -U sa -C -Q "SELECT @@VERSION"
/opt/mssql-tools18/bin/sqlcmd -S localhost,1434 -U sa -C -Q "SELECT @@VERSION"
```

Note the `,1434` — on Linux you always address an instance by **port**, never by
`host\instance`.

## Day-to-day operations

`mssql-instance-manage.sh` wraps the systemd calls. The packaged instance is called `base`,
extra instances by their name, and `all` means every instance:

```bash
sudo ./mssql-instance-manage.sh                  # interactive: pick instance, then action
sudo ./mssql-instance-manage.sh list             # NAME UNIT STATE ENABLED PORT PID DATA-DIRECTORY
sudo ./mssql-instance-manage.sh status mssql2
sudo ./mssql-instance-manage.sh start   all
sudo ./mssql-instance-manage.sh stop    mssql2
sudo ./mssql-instance-manage.sh restart mssql2
sudo ./mssql-instance-manage.sh logs    mssql2 -f          # journal for the unit
sudo ./mssql-instance-manage.sh logs    mssql2 -e -n 200   # engine errorlog
```

Running with no arguments gives a menu — instance list with live state and port, then
`status / start / stop / restart / logs` for the one you pick. `sudo` is needed for the
`start`/`stop`/`restart` entries and to read the data directories; without it the list still
shows state from systemd but ports appear as `?`, since `/var/opt/mssql*` is `0770
mssql:mssql` and `ss -p` needs root to map a socket to a PID.

The raw equivalents, if you prefer them:

```bash
sudo systemctl restart mssql-server@mssql2      # restart just that instance
sudo systemctl stop/start mssql-server@mssql2
journalctl -u mssql-server@mssql2 -f
tail -f /var/opt/mssql-instances/mssql2/log/errorlog
```

Changing settings: plain `mssql-conf` only ever edits the packaged instance's
`/var/opt/mssql/mssql.conf`. Use the wrapper, which runs it inside the target instance's
namespace:

```bash
sudo ./mssql-instance-conf.sh mssql2 set network.tcpport 1435
sudo ./mssql-instance-conf.sh mssql2 set memory.memorylimitmb 2048
sudo ./mssql-instance-conf.sh mssql2 get network
sudo systemctl restart mssql-server@mssql2
```

Backups, logins and databases are per instance and behave normally, e.g.:

```sql
BACKUP DATABASE mydb TO DISK = '/var/opt/mssql-instances/mssql2/backup/mydb.bak';
```

…except that from inside the engine the path is just `/var/opt/mssql/backup/mydb.bak`,
because that is what the namespace shows it. Use the host path when touching files from the
shell, the `/var/opt/mssql/...` path when talking to the engine.

## Removing an instance

```bash
sudo ./mssql-instance-remove.sh mssql2           # keeps the data directory
sudo ./mssql-instance-remove.sh mssql2 --purge   # deletes it too
```

## Troubleshooting

- Re-running `mssql-instance-add.sh` after a failed attempt stops at "already exists".
  Remove the half-created tree first: `sudo rm -rf /var/opt/mssql-instances/<name>`.
- Set up a transient unit by hand to poke at an instance's view of the filesystem:
  ```bash
  sudo systemd-run --pipe --unit=peek -p BindPaths=/var/opt/mssql-instances/mssql2:/var/opt/mssql \
       -p WorkingDirectory=/var/opt/mssql ls -l /var/opt/mssql
  ```
- `systemd-analyze verify mssql-server@.service` validates the unit file if you edit it.

## Caveats — read these

- **Unsupported by Microsoft.** This is a systemd-level workaround, not a supported
  configuration. Do not run it in production and do not open support cases about it.
- **Estimate resources.** Every instance is a full engine process. Your host has 18 GB RAM
  and 8 CPUs; the packaged instance is already using ~1.8 GB. Express caps each instance at
  1410 MB of buffer pool, 1 socket / 4 cores and 10 GB per database, and those caps are per
  instance — which is usually the real reason to want several.
- **`mssql-conf` defaults to the packaged instance.** Always use
  `mssql-instance-conf.sh` (or edit `…/mssql.conf` directly) or you will silently change
  instance 1.
- **Package upgrades apply to all instances at once**, since they share `/opt/mssql`. Stop
  the extra instances before `apt upgrade mssql-server` if you want to be careful.
- **Never point two instances at the same directory.** The namespace is what keeps them
  apart; `BindPaths` on the wrong directory would corrupt data.
- **Only `/var/opt/mssql` is isolated.** `/tmp` and `/dev/shm` are shared. Container shared
  memory is off by default in this build, so this is fine in practice, but a second native
  instance is not as isolated as a container or a VM.
- **A reinstall of `mssql-server` does not touch `/var/opt/mssql-instances`** or the template
  unit, but `apt purge mssql-server` will not clean them up either.
- If you later change your mind, the supported equivalent is one container per instance
  (`mcr.microsoft.com/mssql/server` with `MSSQL_PID=Express`, a different `-p` each).
