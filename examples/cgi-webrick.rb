#!/usr/bin/env ruby
# Sample configuration using WEBrick, mainly intended dev/testing
# for folks familiar with Ruby and not various Perl webserver
# deployment options.
require 'webrick'
require 'logger'
options = {
  :BindAddress => '127.0.0.1',
  :Port => 8080,
  :Logger => Logger.new($stderr),
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
