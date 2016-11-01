minecraft-scripts
=================

A collection of scripts for running a Minecraft server.

Features
--------

* background operation with automatic restarts via runit
* easy console access via "mconsole" command
* server monitoring with [Datadog](http://datadoghq.com)
* automated hourly incremental backups via [WMB](http://github.com/wisq/wmb)

Assumptions
-----------

These scripts were written with the following assumptions (i.e. my server uses the following setup):

* a separate `minecraft` user to run the server
* their home is `/home/minecraft`
* `/home/minecraft/current` is the Minecraft server tree
  * I use `/home/minecraft/<packname>` and symlink it to `current`
* `/home/minecraft/current/server.jar` is the JAR file to run
  * I put a symlink here to the actual server JAR in the same directory, e.g. `FTBServer-1.6.4-965.jar`

If monitoring:

* you're using a whitelist-only server
* you're running a version of Forge that supports the `forge tps` command

If doing backups:

* WMB is checked out to `/home/minecraft/wmb`
* `/home/minecraft/backups/current` is the backup tree for your current server config
  * I use `/home/minecraft/backups/<packname>` and symlink it to `current`

Also, all scripts assume you're using runit, with `/etc/service/minecraft` being the path / link to the Minecraft service tree.  See the "runit" section below.

runit
-----

While the scripts included here can be run however you like, I recommend using [runit](http://smarden.org/runit/).  It should be available in your Linux distribution of choice.  The scripts were written assuming that they can find your server logs and input FIFO in `/etc/service/minecraft`, which is where you would put them to be managed by runit.

I'm not going to document runit too much here; there should be plenty of primers out there on the net.  To make a long story short, the idea of runit is that you have service directories that are symlinked to `/etc/service`.  Inside these directories, you have a `run` script, which defines the command (run as root) to launch your program, and `log/run`, which defines the command to log the output of your program.  runit just sits there running these over and over every time they exit.  Pretty simple.

I've included a sample `runit` tree here.  You can copy these somewhere — I usually put them in `/etc/sv`, e.g. `/etc/sv/minecraft` — and then symlink them in to `/etc/service` once set up.  (Before you do that, you'll probably want to try out the `run` scripts to make sure they work; if they don't, runit will sit there running them over and over until they do.)

Wrapper
-------

In `runit/minecraft`, the `run` script calls the `wrap.rb` script.  This expects you to have made a FIFO (via `mkfifo`) called `input` inside the service directory.  It should be readable by the user that runs the Minecraft server (my scripts assume the user is `minecraft`), and it should be writable by any user that you want to have access to the console.

The FIFO is used to read commands to run.  Both the console access (`mconsole`) and monitoring (`monitor.rb`) depend on this wrapper being used, since they need to be able to issue commands to the server.

Console access
--------------

The `mconsole` script will `tail` the runit log (for output) and send your commands to the `input` FIFO.  It expects you to have `rlwrap` installed, which means the constant spam from the log won't mess up the commands you're entering.

Monitoring
----------

The `monitor.rb` script (and `mc-monitor` runit service) are designed to connect to the `input` FIFO above and issue informational commands, then parse the output and send the results to [Datadog](http://datadoghq.com).  They assume you have a Datadog agent already running on your machine.  If you don't, they'll sit there running their commands, but the output will go nowhere.

Currently, this script alternates between running `forge tps` to get tick timing data, and `list` to get a list of players.

For each dimension (plus overall), it will log and report to Datadog how long the tick took, and how many ticks are running per second.  I've got a Datadog alert that goes off whenever ticks-per-second drops below 20.

It also logs how many players are online, who they are, and whether the players are "unattended" (no ops online).  I have an alert on "unattended" just so I know when my friends log in and I can go join them. ;)

The player listing functionality assumes you're using a whitelist-only server; it will need some tweaking if you don't.

Backups
-------

Backups use [WMB](http://github.com/wisq/wmb), a set of scripts I created to do simple incremental backups with `rsync`.  You don't need to set up any of the server stuff unless you want to back up to a separate server — though, of course, if you care about your server / world / players, that's not a bad idea.  (Personally, I just use the backups in case something goes horribly wrong **in** the world, so I don't mind that they're local only.)

Every backup tree is a complete copy of the files you've selected for backup.  However, whenever those files have *not* changed since the last backup, it creates a *hard link* to the old file.  Hard links are two different names for the same file on disk.  So, if you have a large world but some parts are never updated, you hopefully won't see much actual disk usage.

In order to back up your server, the backup script also connects to the `wrap.rb` script via the `input` FIFO.  It issues several commands and waits to see their effects:

1. It cycles the WMB directory automatically (no need for a separate cron entry)
2. It announces the backup to players in-game
3. It runs `save-all` to make sure the world is flushed to disk
4. It runs `save-off` to disable saving, so the world doesn't update while it's backing up
5. It runs the backup itself via WMB
6. It announces the end of the backup to players in-game
7. It runs `save-on` to turn saving back on

In the case of a failure, it announces the error to the players so they can contact an admin.  It also records in Datadog how long each of the major steps took (`save-all` and the WMB sync), and records how much space the latest backup took and how much space all backups are using.

Within `/home/minecraft/backups/current`, it expects to find a `wmb.yml` file that details what to back up.  Mine looks like this:

```yaml
/home/minecraft/horizons:
  world: include
  config: include
  server.properties: include
  '*.txt': include
```

This backs up only the `world` and `config` directories, plus the `server.properties` and all `.txt` files (like the whitelist / ops list).

(It also expects an `upload` directory within `backups/current`.  I believe it will handle the `current` and `prior` symlinks within that directory, though it may complain for a bit that you have no prior backup to compare against.)

Once you've done this, you can put `backup.sh` in your `minecraft` user's crontab (via `crontab -e` as that user).  For example, I use this to back up hourly, at 3 minutes past the hour:

```crontab
MAILTO=my_email@example.com
PATH=/usr/bin:/bin

# m h  dom mon dow   command
03  *  *   *   *     /home/minecraft/scripts/backup.sh
```

Note: At some point, you'll probably want to start cleaning out old backups; I haven't included anything for that.  Keep an eye on `du` ("disk usage"), and don't forget to check `du -i` (inodes) too; hardlinking files tends to use up a lot of inodes without using up a lot of space.

License & Disclaimer
--------------------

This is just a dump of the scripts from my existing Minecraft server.  I may have missed scripts, or setup steps.  This is released in the public domain, so you can do whatever you want with it, but it comes with NO WARRANTY.  It's unlikely that you could seriously mess anything up with this without making some pretty big mistakes, but if you do, I'm not responsible or liable.

(Of course, I'm happy to be credited if you do use my work elsewhere.)
