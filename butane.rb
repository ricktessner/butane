#!/usr/bin/env ruby
require 'rubygems'
require 'tinder'
require 'yaml'

# Add a new class method to have the EventMachine reactor listen to multiple
# rooms.  Basically just an implementation of the Room#listen instance method
# from the 'tinder' gem.  This was done since each Room instance defines its
# own EM reactor and really only want a single reactor running.

module Tinder
  class Room
    attr_accessor :stream

    def self.listen_to_rooms(rooms, options = {})
      raise ArgumentError, "no block provided" unless block_given?

      require 'twitter/json_stream'

      EventMachine::run do
        rooms.each do |room|
          room.join # you have to be in the room to listen
          auth = room.send(:connection).basic_auth_settings
          room_options = {
            :host => "streaming.#{Connection::HOST}",
            :path => room.send(:room_url_for, :live),
            :auth => "#{auth[:username]}:#{auth[:password]}",
            :timeout => 6,
            :ssl => room.send(:connection).options[:ssl]
          }.merge(options)
          room.stream = Twitter::JSONStream.connect(room_options)
          room.stream.each_item do |message|
            message = HashWithIndifferentAccess.new(ActiveSupport::JSON.decode(message))
            message[:user] = room.user(message.delete(:user_id))
            message[:created_at] = Time.parse(message[:created_at])
            yield(room, message)
          end

          room.stream.on_error do |message|
            raise ListenFailed.new("got an error! #{message.inspect}!")
          end

          room.stream.on_max_reconnects do |timeout, retries|
            raise ListenFailed.new("Tried #{retries} times to connect. Got disconnected from #{room.name}!")
          end

          # if we really get disconnected
          raise ListenFailed.new("got disconnected from #{room.name}!") if !EventMachine.reactor_running?
        end
      end
    end
  end
end

def notify(title, message = "", options = {})
  return if message.nil?

  img_opt = "-i #{options[:image]}" if options[:image]
  delay_opt = ""
  if options[:delay]
    delay_opt = "-t #{options[:delay]}"
  end

  # Cleanse the message
  msg = message.dup
  msg.gsub! /'/, ''       # Get rid of single quotes since we use 'em to delimit msg
  msg.gsub! '\u003E', '>'
  msg.gsub! '\u003C', '<'
  msg.gsub! '\u0026', '&'
  msg.gsub! '\"', '"'
  msg.gsub! '&hellip;', '...'   # notify-send don't like this

  # And let's remove all but the href attribute in any anchors
  # in the msg.  Assumes that in href=stuff, stuff has no whitespace.
  msg.gsub! /<a[^>]+(href=[^(\s|>)]+)[^>]*>/, '<a \1>'

  %x{ notify-send #{delay_opt} #{img_opt} "#{title}" '#{msg}' }
end

config = YAML::load_file("#{ENV['HOME']}/.butanerc")
account_names = config.keys

tinder_rooms = []
room_configs = {}

# Build up an array of Tinder::Room and a hash of ignore/sticky/image options
# indexed by the name of each room for use in the block passed to the new
# listen_to_rooms() method.
account_names.each do |account_name|
  rooms = config[account_name][:rooms]
  account_img = config[account_name][:image]
  if rooms && rooms.size > 0
    begin
      auth = { :ssl => config[account_name][:ssl]}
      if config[account_name][:token]
        auth.merge!({ :token => config[account_name][:token] })
      else
        auth.merge!({ :username => config[account_name][:login],
                      :password => config[account_name][:password] })
      end

      campfire = Tinder::Campfire.new(account_name, auth)
    rescue Tinder::Error => e
      notify "Problem logging in to #{account_name}", "#{e.message}"
      next
    end
    notify "Successfully logged in to #{account_name}", "", :image => account_img

    rooms.keys.each do |room_name|
      room = campfire.find_room_by_name room_name
      if room
        room_configs[room.name] = rooms[room.name] || {}
        room_configs[room.name][:image] ||= account_img
        room_configs[room.name][:self_name] ||= config[account_name][:self_name]
        tinder_rooms << room
        notify "Now monitoring #{room.name}", "", :image => room_configs[room.name][:image]
      else
        notify "Did not find #{room_name}, not monitoring"
      end
    end
  end
end

last_message_id = Hash.new(0)

Tinder::Room.listen_to_rooms(tinder_rooms) do |tinder_room, m|
  next if !m[:user] || m[:user][:name].strip.empty?  # Ignore anything from a nil / empty person

  next if m[:id].to_i <= last_message_id[tinder_room.id]
  last_message_id[tinder_room.id] = m[:id].to_i

  delay = 5000 # in milliseconds (time to display the notification)

  sticky = room_configs[tinder_room.name][:sticky]
  ignore = room_configs[tinder_room.name][:ignore]
  image  = room_configs[tinder_room.name][:image]

  # If we're to monitor something in particular in this room, set the
  # delay notification to zero which will leave the message up until
  # clicked away.
  if sticky
    delay = 0 if m[:body] =~ /#{sticky}/i
  end

  if ignore
    next if ignore.any? do |ignore|
      m[:body] =~ /#{ignore}/
    end
  end

  # Get rid of any dquotes since we use 'em to delimit person
  person = m[:user][:name].gsub /"/, ''
  next if person.include? room_configs[tinder_room.name][:self_name]

  notify("#{person} in #{tinder_room.name}", m[:body], :delay => delay, :image => image)
end
