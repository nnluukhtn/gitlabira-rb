require 'dotenv'
Dotenv.load

require 'raven'
require './gitlabira'

Raven.configure do |config|
  config.server = ENV['SENTRY_DSN']
end
use Raven::Rack

$stdout.sync = true

run Gitlabira.run!
