#!/usr/bin/env ruby
# coding: utf-8
#
# Usage: ./getcmd.rb consul:8500 10.10.10.10/app
# Forms cmd to run docker container with the same settings as service "app",
# running on host 10.10.10.10.

require "json"
require "open-uri"

if ARGV.length < 2
  STDERR.write "Usage: ./getcmd.rb consuladdr consulkey\n"
  exit 1
end

if ARGV[0].start_with?("http://") || ARGV[0].start_with?("https://")
  consul_addr = ARGV[0]
else
  consul_addr = "http://#{ARGV[0]}"
end

if consul_addr.count(":") < 2
  consul_addr = "#{consul_addr}:8500"
end

if ARGV[1].start_with?("/")
  consul_key = ARGV[1].slice(1, ARGV[1].length)
else
  consul_key = ARGV[1]
end

service_url = "#{consul_addr}/v1/kv/services/#{consul_key}?raw"

desc = JSON.parse(open(service_url).read)

envs = []

desc['Envs'].each do |e|
  envs << "-e #{e['Name']}=#{e['Value']}"
end

(desc['Discoveries'] || []).each do |d|
  url = "#{consul_addr}/v1/health/service/#{d['Service']}?passing"
  if d['Tag'] && d['Tag'] != ''
    url += "&tag=#{d['Tag']}"
  end
  res = JSON.parse(open(url).read)
  services = res.map do |v|
    v['Node']['Address'] + ":" + v['Service']['Port'].to_s
  end
  env = if d['Multiple']
          services * ','
        else
          services.first
        end

  envs << "-e #{d['Env']}=#{env}"
end

puts "docker run -ti #{envs * ' '} #{desc['Image']['Name']}:#{desc['Image']['Tag']}"
