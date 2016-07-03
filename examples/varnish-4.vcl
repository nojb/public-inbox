# Example VCL for Varnish 4.0 with public-inbox WWW code
# This is based on what shipped for 3.x a long time ago (I think)
# and I'm hardly an expert in VCL (nor should we expect anybody
# who maintains a public-inbox HTTP interface to be).
#
# It seems to work for providing some protection from traffic
# bursts; but perhaps the public-inbox WWW interface can someday
# provide enough out-of-the-box performance that configuration
# of an extra component is pointless.

vcl 4.0;
backend default {
	.host = "127.0.0.1";
	.port = "280";
}

sub vcl_recv {
	if (req.method != "GET" &&
			req.method != "HEAD" &&
			req.method != "PUT" &&
			req.method != "POST" &&
			req.method != "TRACE" &&
			req.method != "OPTIONS" &&
			req.method != "DELETE") {
		/* Non-RFC2616 or CONNECT which is weird. */
		return (pipe);
	}
	if (req.method != "GET" && req.method != "HEAD") {
		/* We only deal with GET and HEAD by default */
		return (pass);
	}
	if (req.http.Authorization || req.http.Cookie) {
		/* Not cacheable by default */
		return (pass);
	}
	return (hash);
}

sub vcl_hash {
	hash_data(req.url);
	if (req.http.host) {
		hash_data(req.http.host);
	} else {
		hash_data(server.ip);
	}
	if (req.http.X-Forwarded-Proto) {
		hash_data(req.http.X-Forwarded-Proto);
	}
	return (lookup);
}

sub vcl_backend_response {
	set beresp.grace = 60s;
	set beresp.do_stream = true;
	if (beresp.ttl <= 0s ||
		beresp.http.Set-Cookie ||
		beresp.http.Vary == "*") {
		/* Mark as "Hit-For-Pass" for the next 2 minutes */
		set beresp.ttl = 120 s;
		set beresp.uncacheable = true;
		return (deliver);
	} else {
		set beresp.ttl = 10s;
	}
	return (deliver);
}
