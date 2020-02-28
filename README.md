minecraft-scripts
=================

A collection of scripts for running a Minecraft server.

Features
--------

* server monitoring with [Datadog](http://datadoghq.com)
* automated hourly incremental backups via [WMB](http://github.com/wisq/wmb)
* only requires a minor options to your server config

Installation
------------

1. Run `mix deps.get`
2. Set up RCON access on your server.  (See "[RCON access](#rcon-access)" below.)
3. Run `mix run bin/test-rcon.exs` to check if RCON access is set up correctly.
  * You'll probably need to specify some command line options, especially `--rcon-password`.
  * You can see a complete list of options with `mix run bin/test-rcon.exs --help`.

And you're ready to go!  See either the "[Monitoring](#monitoring)" or "[Backups](#backups)" sections below for details on each.

Security concerns
-----------------

When specifying options on the command line — especially passwords like `--rcon-password` — remeber that **every user on your server** can see the options you're using.  This may not seem like a big problem if you're running a small private server, but it's still a good idea not to put passwords on the command line.

However, there's a solution for this: All command-line parameters can be specified via environment variables instead.  So for example, if you do ...

```sh
export RCON_PASSWORD=some_password
mix run bin/monitor.exs
```

... you can keep your password private, since nobody (except your server administrator) can see environment variables for other users.  (Just remember that if you're putting this in a script, you should run `chmod 700` on the script to make sure nobody else can read it.)

RCON access
-----------

Both scripts require RCON access to your Minecraft server.  That means you'll need to open up your server's `server.properties` file and edit or add the following options:

* `enable-rcon` — set this to `true`
* `rcon.port` — the default of 25575 is fine
* `rcon.password` — you'll want to set something here
* `broadcast-rcon-to-ops` — if you don't mind your ops seeing a few messages whenever you do a backup, you can leave this set to `true`

Restart your server after changing this file.

You may also need to install a server mod to fix a [very old RCON bug](https://bugs.mojang.com/browse/MC-7569).  The `test-rcon.exs` script (see "[Installation](#installation)" above) will check this for you.

If your server suffers from this bug, there are server mods you can install to fix it; see either

* [this mod page](https://www.curseforge.com/minecraft/mc-mods/rcon-newline-fix) (which I've tested),
* [this GitHub project](https://github.com/fraenkelc/RCONNewlineFix/releases) (which I've not tested),
* or just search the web for "minecraft rcon newline".

If none of the above work with your version of Minecraft, then you'll need to either bother the Minecraft developers to finally fix that bug, or (gently!) poke one of the mod authors to update their mod.

Monitoring
----------

To monitor your server, you can run `mix run bin/monitor.exs` along with any necessary options.  (Try the `--help` option for details.)

The monitoring script issues informational commands to the Minecraft server, then parses the output and sends the results to [Datadog](http://datadoghq.com).  They assume you have a Datadog agent already running on your machine.  If you don't, they'll sit there running their commands, but the output will go nowhere.

Currently, this script tracks the following data:

### Performance data

The script runs the `forge tps` command to get information about server performance.

For each dimension, it will report ...

* `minecraft.server.tick.ms` — how long the average tick takes (in milliseconds)
* `minecraft.server.tick.tps` — how many ticks are performed (per second) on average

These stats are tagged by dimension number, so you can see which dimensions are running fine and which may be causing problems.  Additionally, there are `.overall` versions of the above stats that log how the server as a whole is doing.

Normally, you should be seeing exactly 20.0 ticks per second, and any number lower than this indicates that your server is suffering from lag.  You may want to set up a Datadog alert that triggers if ticks per second drops below 20.

### Players online

The script runs the `list` command to get information about which players are online.

It will report ...

* `minecraft.server.players.current` — how many players are online
* `minecraft.server.players.max` — the maximum number of players allowed online at once
* `minecraft.server.players.unattended` — how many players are online without any operators (i.e. server administrators or moderators) present

Larger servers can use the `unattended` figure to watch for gaps in their moderation coverage.  Or, if you're just running a small server for you and your friends, you can use this to alert you when other players are online without you, so you can go join them. 😊

#### Individual player tracking

If the `--monitor-track-players` option is specified, an additional metric is recorded:

* `minecraft.server.players.online` (tagged by player name) — the online status of each player in your server whitelist

This can be useful for tracking your friends' activity, for seeing who logs on at what hours, or just for making a pretty stacked graph of exactly who's online when.

**You should only use this if your server whitelist is relatively small** (e.g. under 50 players or so).  Tagged metrics in Datadog are not designed to handle hundreds of tag values, and you'll quickly run out of available metrics quota if you try this on a large server.

Backups
-------

Backups use [WMB](http://github.com/wisq/wmb), a set of scripts I created to do simple incremental backups with `rsync`.  You don't need to set up any of the server stuff unless you want to back up to a separate server — though, of course, if you care about your server / world / players, that's not a bad idea.  (Personally, I just use the backups in case something goes horribly wrong **in** the world, so I don't mind that they're local only.)

Every backup tree is a complete copy of the files you've selected for backup.  However, whenever those files have *not* changed since the last backup, it creates a *hard link* to the old file.  Hard links are two different names for the same file on disk.  So, if you have a large world but some parts are never updated, you won't see much actual disk usage.

In order to back up your server, the backup script issues several commands (via the shell and via RCON):

1. It runs WMB's `cycle` script to cycle the backup directory (so no need for a separate cron entry)
2. If `--announce-backups` is set, It announces the backup to players in-game
3. It runs `save-all flush` to make sure the world is flushed to disk
4. It runs `save-off` to disable saving, so the world doesn't update while it's backing up
5. It runs WMB's `sync` script to perform the actual backup
6. If `--announce-backups` is set, it announces the end of the backup to players in-game
7. It runs `save-on` to turn saving back on

It also records in Datadog how long each of the major steps took (`save-all` and the WMB sync), and ~~records how much space the latest backup took and how much space all backups are using~~ (TODO; missing after rewrite).

In the case of a failure, it always announces the error to the players (regardless of the `--announce-backups` setting) so they can contact an admin.

### Setup

To get this working, you'll need to do the following:

1. `git clone` the [WMB](http://github.com/wisq/wmb) repository somewhere
  * the default location is `/home/minecraft/wmb`
2. create a backup directory
  * the default location is `/home/minecraft/backups`
3. create a `wmb.yml` file (see below)
  * the default location is `/home/minecraft/backups/wmb.yml`

A typical `wmb.yml` file might looks like this:

```yaml
/home/minecraft/server:
  world: include
  config: include
  server.properties: include
  '*.json': include
```

This backs up only the `world` and `config` directories, plus the `server.properties` and all `.json` files (like the whitelist and ops list).

To make it easier to run this from a `crontab` file, there's a `backup-cron.sh.example` file that should help.  Copy the file somewhere, edit it as needed (e.g. to set options), then use `crontab -e` to add it to your crontab.  For example, I use this to back up every six hours, on the hour:

```crontab
MAILTO=my_email@example.com
PATH=/usr/bin:/bin
# m h dom mon dow   command
0 */6 *   *   *     /home/minecraft/scripts/backup-cron.sh > /home/minecraft/backups/cron.log 2>&1
```

Note: At some point, you'll probably want to start cleaning out old backups; I haven't written anything to automate that yet.  Keep an eye on `du` ("disk usage"), and don't forget to check `du -i` (inodes) too; hardlinking files tends to use up a lot of inodes without using up a lot of space.

Legal stuff
-----------

Copyright © 2020, Adrian Irving-Beer.

These scripts are released under the [Apache 2 License](../../blob/master/LICENSE) and are provided with **no warranty**.  It's unlikely that you could seriously mess anything up with this without making some pretty big mistakes, but if you do, I'm not responsible or liable.
