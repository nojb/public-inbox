#!/usr/bin/env ruby
# Sample configuration using WEBrick, mainly intended dev/testing
# for folks familiar with Ruby and not various Perl webserver
# deployment options.  For those familiar with Perl web servers,
# plackup(1) is recommended for development and public-inbox-httpd(1)
# is our production deployment server.
require 'webrick'
require 'logger'
options = {
  :BindAddress => '127.0.0.1',
  :Port => 8080,
  :Logger => Logger.new($stderr),
  :CGIPathEnv => ENV['PATH'], # need to run 'git' commands
  :AccessLog => [
    [ Logger.new($stdout), WEBrick::AccessLog::COMBINED_LOG_FORMAT ]
  ],
}
server = WEBrick::HTTPServer.new(options)
server.mount("/",
             WEBrick::HTTPServlet::CGIHandler,
            "/var/www/cgi-bin/public-inbox.cgi")
['INT', 'TERM'].each do |signal|
  trap(signal) {exit!(0)}
end
server.start
