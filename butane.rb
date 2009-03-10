#!/usr/bin/ruby
require 'rubygems'
require 'tinder'
require 'yaml'

def monitor_room(room, regex = nil)
  room.listen do |m|
    # Ignore any pings from campfire to determine if I'm still
    # here
    next if m[:person].strip.empty?  # Ignore anything from a nil / empty person

    delay = 5000 # in milliseconds (time to display the notification)

    # If we're to monitor something in particular in this room, set the 
    # delay notification to zero which will leave the message up until
    # clicked away.
    if regex
      delay = 0 if m[:message] =~ /#{regex}/i
    end

    `notify-send -t #{delay} -i /home/rick/Pictures/cf.gif \"#{m[:person]}\n#{m[:message]}\"`
  end
end

config = YAML::load_file("#{ENV['HOME']}/.butanerc")
account_names = config.keys

threads = []
account_names.each do |account_name|
  rooms = config[account_name][:rooms]
  if rooms && rooms.size > 0
    campfire = Tinder::Campfire.new account_name
    campfire.login config[account_name][:login], config[account_name][:password]
    # Start up a thread for each room we are going to monitor
    rooms.keys.each do |room_name|
      room = campfire.find_room_by_name room_name
      if room
        threads << Thread.new(room, rooms[room_name][:monitor]) do |r, rx|
          monitor_room(r, rx)
        end
      end
    end
  end
end

threads.each { |t| t.join }
