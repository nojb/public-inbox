-- Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
-- License: GPLv2 or later <https://www.gnu.org/licenses/gpl-2.0.txt>
-- This commit filter maps a subject line to a search URL of a public-inbox
-- disclaimer: written by someone who does not know Lua.
--
-- This requires cgit linked with Lua
-- Usage (in your cgitrc(5) config file):
--
--   commit-filter=lua:/path/to/this/script.lua
--
-- Example: http://bogomips.org/public-inbox.git/

local urls = {}
urls['public-inbox.git'] = 'http://public-inbox.org/meta/'
-- additional URLs here...

function filter_open(...)
	lineno = 0
	buffer = ""
	subject = ""
end

function filter_close()
	if lineno == 1 and string.find(buffer, "\n") == nil then
		u = urls[os.getenv('CGIT_REPO_URL')]
		if u == nil then
			html(buffer)
		else
			html('<a href="' .. u .. '?x=t&q=')
			html_url_arg('"' .. buffer .. '"')
			html('"><tt>')
			html_txt(buffer)
			html('</tt></a>')
		end
	else
		html(buffer)
	end
	return 0
end

function filter_write(str)
	lineno = lineno + 1
	buffer = buffer .. str
end
