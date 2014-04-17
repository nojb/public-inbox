#!/usr/bin/env ruby
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
            "#{Dir.pwd}/blib/script/public-inbox.cgi")
['INT', 'TERM'].each do |signal|
  trap(signal) {exit}
end
server.start
