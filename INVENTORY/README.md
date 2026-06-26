# INVENTORY

Inventory Collector installs a local, offline command for generating a JSON inventory report on a client server.

## Install layout

The public installer places files under:

- `/home/itgo/UTILITY/INVENTORY/bin`
- `/home/itgo/UTILITY/INVENTORY/reports`
- `/home/itgo/UTILITY/INVENTORY/logs`
- `/home/itgo/UTILITY/INVENTORY/config`

It also creates `/usr/local/bin/itgo-inv` as a symlink to the installed wrapper.

## Usage

Generate a local report:

```bash
itgo-inv
```

Show the newest local report:

```bash
itgo-inv latest
```

Show installed versions:

```bash
itgo-inv version
```

Reports are stored in `/home/itgo/UTILITY/INVENTORY/reports`.
