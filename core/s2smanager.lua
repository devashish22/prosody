
local hosts = hosts;
local sessions = sessions;
local socket = require "socket";
local format = string.format;
local t_insert, t_sort = table.insert, table.sort;
local get_traceback = debug.traceback;
local tostring, pairs, ipairs, getmetatable, print, newproxy, error, tonumber
    = tostring, pairs, ipairs, getmetatable, print, newproxy, error, tonumber;

local connlisteners_get = require "net.connlisteners".get;
local wraptlsclient = require "net.server".wraptlsclient;
local modulemanager = require "core.modulemanager";
local st = require "stanza";
local stanza = st.stanza;

local uuid_gen = require "util.uuid".generate;

local logger_init = require "util.logger".init;

local log = logger_init("s2smanager");

local md5_hash = require "util.hashes".md5;

local dialback_secret = "This is very secret!!! Ha!";

local dns = require "net.dns";

module "s2smanager"

local function compare_srv_priorities(a,b) return a.priority < b.priority or a.weight < b.weight; end

function send_to_host(from_host, to_host, data)
	if data.name then data = tostring(data); end
	local host = hosts[from_host].s2sout[to_host];
	if host then
		-- We have a connection to this host already
		if host.type == "s2sout_unauthed" and ((not data.xmlns) or data.xmlns == "jabber:client" or data.xmlns == "jabber:server") then
			(host.log or log)("debug", "trying to send over unauthed s2sout to "..to_host..", authing it now...");
			if not host.notopen and not host.dialback_key then
				host.log("debug", "dialback had not been initiated");
				initiate_dialback(host);
			end
			
			-- Queue stanza until we are able to send it
			if host.sendq then t_insert(host.sendq, data);
			else host.sendq = { data }; end
		elseif host.type == "local" or host.type == "component" then
			log("error", "Trying to send a stanza to ourselves??")
			log("error", "Traceback: %s", get_traceback());
			log("error", "Stanza: %s", tostring(data));
		else
			(host.log or log)("debug", "going to send stanza to "..to_host.." from "..from_host);
			-- FIXME
			if host.from_host ~= from_host then
				log("error", "WARNING! This might, possibly, be a bug, but it might not...");
				log("error", "We are going to send from %s instead of %s", tostring(host.from_host), tostring(from_host));
			end
			host.sends2s(data);
			host.log("debug", "stanza sent over "..host.type);
		end
	else
		log("debug", "opening a new outgoing connection for this stanza");
		local host_session = new_outgoing(from_host, to_host);
		-- Store in buffer
		host_session.sendq = { data };
	end
end

local open_sessions = 0;

function new_incoming(conn)
	local session = { conn = conn, type = "s2sin_unauthed", direction = "incoming" };
	if true then
		session.trace = newproxy(true);
		getmetatable(session.trace).__gc = function () open_sessions = open_sessions - 1; print("s2s session got collected, now "..open_sessions.." s2s sessions are allocated") end;
	end
	open_sessions = open_sessions + 1;
	local w, log = conn.write, logger_init("s2sin"..tostring(conn):match("[a-f0-9]+$"));
	session.sends2s = function (t) log("debug", "sending: %s", tostring(t)); w(tostring(t)); end
	return session;
end

function new_outgoing(from_host, to_host)
		local host_session = { to_host = to_host, from_host = from_host, notopen = true, type = "s2sout_unauthed", direction = "outgoing" };
		hosts[from_host].s2sout[to_host] = host_session;
		local cl = connlisteners_get("xmppserver");
		
		local conn, handler = socket.tcp()
		
		--FIXME: Below parameters (ports/ip) are incorrect (use SRV)
		
		local connect_host, connect_port = to_host, 5269;
		
		local answer = dns.lookup("_xmpp-server._tcp."..to_host..".", "SRV");
		
		if answer then
			log("debug", to_host.." has SRV records, handling...");
			local srv_hosts = {};
			host_session.srv_hosts = srv_hosts;
			for _, record in ipairs(answer) do
				t_insert(srv_hosts, record.srv);
			end
			t_sort(srv_hosts, compare_srv_priorities);
			
			local srv_choice = srv_hosts[1];
			if srv_choice then
				connect_host, connect_port = srv_choice.target or to_host, srv_choice.port or connect_port;
				log("debug", "Best record found, will connect to %s:%d", connect_host, connect_port);
			end
		end
		
		conn:settimeout(0);
		local success, err = conn:connect(connect_host, connect_port);
		if not success and err ~= "timeout" then
			log("warn", "s2s connect() failed: %s", err);
		end
		
		conn = wraptlsclient(cl, conn, connect_host, connect_port, 0, 1, hosts[from_host].ssl_ctx );
		host_session.conn = conn;
		
		-- Register this outgoing connection so that xmppserver_listener knows about it
		-- otherwise it will assume it is a new incoming connection
		cl.register_outgoing(conn, host_session);
		
		local log;
		do
			local conn_name = "s2sout"..tostring(conn):match("[a-f0-9]*$");
			log = logger_init(conn_name);
			host_session.log = log;
		end
		
		local w = conn.write;
		host_session.sends2s = function (t) log("debug", "sending: %s", tostring(t)); w(tostring(t)); end
		
		conn.write(format([[<stream:stream xmlns='jabber:server' xmlns:db='jabber:server:dialback' xmlns:stream='http://etherx.jabber.org/streams' from='%s' to='%s' version='1.0'>]], from_host, to_host));
		 
		return host_session;
end

function streamopened(session, attr)
	local send = session.sends2s;
	
	session.version = tonumber(attr.version) or 0;
	if session.version >= 1.0 and not (attr.to and attr.from) then
		print("to: "..tostring(attr.to).." from: "..tostring(attr.from));
		log("warn", (session.to_host or "(unknown)").." failed to specify 'to' or 'from' hostname as per RFC");
	end
	
	if session.direction == "incoming" then
		-- Send a reply stream header
		
		for k,v in pairs(attr) do print("", tostring(k), ":::", tostring(v)); end
		
		session.to_host = attr.to;
		session.from_host = attr.from;
	
		session.streamid = uuid_gen();
		print(session, session.from_host, "incoming s2s stream opened");
		send("<?xml version='1.0'?>");
		send(stanza("stream:stream", { version = '1.0', xmlns='jabber:server', ["xmlns:db"]='jabber:server:dialback', ["xmlns:stream"]='http://etherx.jabber.org/streams', id=session.streamid, from=session.to_host }):top_tag());
		if session.to_host and not hosts[session.to_host] then
			-- Attempting to connect to a host we don't serve
			session:close("host-unknown");
			return;
		end
		if session.version >= 1.0 then
			send(st.stanza("stream:features")
					:tag("dialback", { xmlns='urn:xmpp:features:dialback' }):tag("optional"):up():up());
		end
	elseif session.direction == "outgoing" then
		-- If we are just using the connection for verifying dialback keys, we won't try and auth it
		if not attr.id then error("stream response did not give us a streamid!!!"); end
		session.streamid = attr.id;
	
		if not session.dialback_verifying then
			initiate_dialback(session);
		else
			mark_connected(session);
		end
	end

	session.notopen = nil;
end

function initiate_dialback(session)
	-- generate dialback key
	session.dialback_key = generate_dialback(session.streamid, session.to_host, session.from_host);
	session.sends2s(format("<db:result from='%s' to='%s'>%s</db:result>", session.from_host, session.to_host, session.dialback_key));
	session.log("info", "sent dialback key on outgoing s2s stream");
end

function generate_dialback(id, to, from)
	return md5_hash(id..to..from..dialback_secret); -- FIXME: See XEP-185 and XEP-220
end

function verify_dialback(id, to, from, key)
	return key == generate_dialback(id, to, from);
end

function make_authenticated(session)
	if session.type == "s2sout_unauthed" then
		session.type = "s2sout";
	elseif session.type == "s2sin_unauthed" then
		session.type = "s2sin";
	else
		return false;
	end
	session.log("info", "connection is now authenticated");
	
	mark_connected(session);
	
	return true;
end

function mark_connected(session)
	local sendq, send = session.sendq, session.sends2s;
	
	local from, to = session.from_host, session.to_host;
	
	session.log("debug", session.direction.." s2s connection "..from.."->"..to.." is now complete");
	
	local send_to_host = send_to_host;
	function session.send(data) send_to_host(to, from, data); end
	
	
	if session.direction == "outgoing" then
		if sendq then
			session.log("debug", "sending "..#sendq.." queued stanzas across new outgoing connection to "..session.to_host);
			for i, data in ipairs(sendq) do
				send(data);
				sendq[i] = nil;
			end
			session.sendq = nil;
		end
	end
end

function destroy_session(session)
	(session.log or log)("info", "Destroying "..tostring(session.direction).." session "..tostring(session.from_host).."->"..tostring(session.to_host));
	
	-- FIXME: Flush sendq here/report errors to originators
	
	if session.direction == "outgoing" then
		hosts[session.from_host].s2sout[session.to_host] = nil;
	end
	
	for k in pairs(session) do
		if k ~= "trace" then
			session[k] = nil;
		end
	end
end

return _M;
