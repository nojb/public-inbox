-- Copyright (C) 2015-2021 all contributors <meta@public-inbox.org>
-- License: GPLv2 or later <https://www.gnu.org/licenses/gpl-2.0.txt>
-- This commit filter maps a subject line to a search URL of a public-inbox
-- disclaimer: written by someone who does not know Lua.
--
-- This requires cgit linked with Lua
-- Usage (in your cgitrc(5) config file):
--
--   commit-filter=lua:/path/to/this/script.lua
--
-- Example site: https://80x24.org/public-inbox.git/

local urls = {}
urls['public-inbox.git'] = 'https://public-inbox.org/meta/'
-- additional URLs here...
-- TODO we should be able to auto-generate this based on "coderepo"
-- directives in the public-inbox config file; but keep in mind
-- the mapping is M:N between inboxes and coderepos

function filter_open(...)
	lineno = 0
	buffer = ""
end

function filter_close()
	-- cgit opens and closes this filter for the commit subject
	-- and body separately, and we only generate the link based
	-- on the commit subject:
	if lineno == 1 and string.find(buffer, "\n") == nil then
		u = urls[os.getenv('CGIT_REPO_URL')]
		if u == nil then
			html(buffer)
		else
			html("<a\ntitle='mail thread'\n")
			html('href="' .. u .. '?x=t&amp;q=')
			s = string.gsub(buffer, '"', '""')
			html_url_arg('"' .. s .. '"')
			html('">')
			html_txt(buffer)
			html('</a>')
		end
	else
		-- pass the body-through as-is
		-- TODO: optionally use WwwHighlight for linkification like
		-- cgit-wwwhighlight-filter.lua
		html(buffer)
	end
	return 0
end

function filter_write(str)
	lineno = lineno + 1
	buffer = buffer .. str
end
