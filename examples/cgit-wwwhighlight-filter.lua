-- Copyright (C) 2019 all contributors <meta@public-inbox.org>
-- License: GPL-2.0+ <https://www.gnu.org/licenses/gpl-2.0.txt>
--
-- This filter accesses the PublicInbox::WwwHighlight PSGI endpoint
-- (see examples/highlight.psgi)
--
-- Dependencies: lua-http
--
-- disclaimer: written by someone who does not know Lua.
--
-- This requires cgit linked with Lua
-- Usage (in your cgitrc(5) config file):
--
--   source-filter=lua:/path/to/this/script.lua
--   about-filter=lua:/path/to/this/script.lua
--
local wwwhighlight_url = 'http://127.0.0.1:9090/'
local req_timeout = 10
local too_big = false

-- match $PublicInbox::HTTP::MAX_REQUEST_BUFFER
local max_len = 10 * 1024 * 1024

-- about-filter needs surrounding <pre> tags if all we do is
-- highlight and linkify
local pre = true

function filter_open(...)
	req_body = ""

	-- detect when we're used in an about-filter
	local repo_url = os.getenv('CGIT_REPO_URL')
	if repo_url then
		local path_info = os.getenv('PATH_INFO')
		rurl = path_info:match("^/(.+)/about/?$")
		pre = rurl == repo_url
	end

	-- hand filename off for language detection
	local fn = select(1, ...)
	if fn then
		local http_util = require 'http.util'
		wwwhighlight_url = wwwhighlight_url .. http_util.encodeURI(fn)
	end
end

-- try to buffer the entire source in memory
function filter_write(str)
	if too_big then
		html(str)
	elseif (req_body:len() + str:len()) > max_len then
		too_big = true
		req_body = ""
		html(req_body)
		html(str)
	else
		req_body = req_body .. str
	end
end

function fail(err)
	io.stderr:write(tostring(err), "\n")
	if pre then
		html("<pre>")
	end
	html_txt(req_body)
	if pre then
		html("</pre>")
	end
	return 1
end

function filter_close()
	if too_big then
		return 0
	end
	local request = require 'http.request'
	local req = request.new_from_uri(wwwhighlight_url)
	req.headers:upsert(':method', 'PUT')
	req:set_body(req_body)

	-- don't wait for 100-Continue message from the PSGI app
	req.headers:delete('expect')

	local headers, stream = req:go(req_timeout)
	if headers == nil then
		return fail(stream)
	end
	local status = headers:get(':status')
	if status ~= '200' then
		return fail('status ' .. status)
	end
	local body, err = stream:get_body_as_string()
	if not body and err then
		return fail(err)
	end
	if pre then
		html("<pre>")
	end
	html(body)
	if pre then
		html("</pre>")
	end
	return 0
end
