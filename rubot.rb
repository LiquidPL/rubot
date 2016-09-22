# frozen_string_literal: true

require 'sinatra'
require 'discordrb'
require 'json'

module RubotHandlers; end

$handlers = {}

# Method to load handlers
def deploy!
  # Load all the module code files.
  Dir.glob('handlers/*.rb') { |mod| load mod }

  RubotHandlers.constants.each do |name|
    const = RubotHandlers.const_get name
    if const.is_a? Module
      $handlers[name.to_s.downcase] = const
    end
  end
end

deploy!

# Read the file of existing links so we don't have to re-add everything all the time
$links = JSON.parse(File.read('rubot-links'))

token, app_id, secret, server_id, admin_role_name, bot_name = File.read('rubot-config').lines
bot = Discordrb::Bot.new token: token, application_id: app_id.to_i
puts bot.invite_url

# remove the newline character from the secret, admin_role_name and bot_name
secret = secret.strip
admin_role_name = admin_role_name.strip
bot_name = bot_name.strip

admin_role = nil
server = nil

bot.ready do |event|
  server = bot.servers[server_id.to_i]
  admin_role = server.roles.find { |role| role.name == admin_role_name }
end

bot.message(starting_with: "#{bot_name}, link this:") do |event|
  # if user has admin role?
  if event.user.on(server).role?(admin_role)
    name = event.content.split(':')[1].strip
    $links[name] ||= []
    $links[name] << event.channel.id
    File.write('rubot-links', $links.to_json)
    event.respond "Linked repo #{name} to #{event.channel.mention} (`#{event.channel.id}`)"
  end
end

bot.message(starting_with: "#{bot_name}, reload handlers") do |event|
  deploy!
  event.respond("Loaded #{$handlers.length} handlers")
end

bot.run :async

class WSPayload
  attr_reader :data

  def initialize(payload)
    @data = payload
  end

  def repo_name
    @data['repository']['full_name']
  end

  def sender_name
    @data['sender']['login']
  end

  def issue
    @data['issue']
  end

  def pull_request
    @data['pull_request']
  end

  def tiny_issue
    "**##{issue['number']}** (" + %(**#{issue['title']}**) + issue['labels'].map { |e| " `[#{e['name']}]`"}.join + ')'
  end

  def tiny_pull_request
    "**##{pull_request['number']}** (" + %(**#{pull_request['title']}**) + ')'
  end

  def action
    @data['action']
  end

  def [](key)
    @data[key]
  end
end

def handle(event_type, payload)
  event_type = event_type.delete('_')
  payload = WSPayload.new(payload)
  if $handlers[event_type]
    $handlers[event_type].handle(payload)
  else
    nil
  end
end

get '/webhook' do
  "Hooray! The bot works. #{$links.length} links are currently registered."
end

post '/webhook' do
  request.body.rewind

  body = request.body.read

  signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), secret, body)
  return halt 500, "Signatures didn't match!" unless Rack::Utils.secure_compare(signature, request.env['HTTP_X_HUB_SIGNATURE'])

  event_type = request.env['HTTP_X_GITHUB_EVENT'] # The event type is a custom request header
  payload = JSON.parse(body)
  repo_name = payload['repository']['full_name']

  channels = $links[repo_name]

  return halt 404, 'Unknown repo' unless channels

  channels.each do |e|
    response = handle(event_type, payload)
    if response
      bot.send_message(e, "**#{repo_name}**: **#{payload['sender']['login']}** " + response)
    else
      puts %(Got a "#{event_type}" event for repo #{repo_name} that is not supported - ignoring)
    end
  end

  204
end
