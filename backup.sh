#!/bin/sh

cd /home/minecraft/scripts
export GEM_HOME=/home/minecraft/.rubygems
exec $GEM_HOME/bin/bundle exec ./backup.rb
