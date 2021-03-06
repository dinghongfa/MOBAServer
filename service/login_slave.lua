local skynet = require "skynet"
local socket = require "skynet.socket"
local crypt = require "skynet.crypt"
local log = require "log"
local pb = require "protobuf"
local net = require "netpackage"
local protocol = require "protocol"
local cmd = require "proto.cmd"
local errcode = require "logic.retcode"
local redis = require "skynet.db.redis"
local utils = require "luautils"

local id = ...

local db
local ACCOUNT = "account"
local PLAYER = "player:"

local Context = {}

--[[
local function strtohex(str)
	local len = str:len()
	local fmt = "0X"
	for i=1,len do
		fmt = fmt .. string.format("%02x", str:byte(i))
	end
	return fmt
end
--]]

local function write_cmd_msg(fd, proto_cmd, protostr, orgdata)
	local data = pb.encode(protostr, orgdata)
	--log("write_cmd_msg cmd(%d) encode result: %s", proto_cmd, strtohex(data))
	local msg = protocol.serialize(Context[fd].session, proto_cmd, data)
	--log("write_cmd_msg cmd(%d) serialize msg result: %s", proto_cmd, strtohex(msg))
	net.write(fd, msg)
end

local function read_cmd_msg(fd, expect_cmd, protostr)
	local sess
	local req_cmd
	local data
	local ok
	local msg
	local result
	local err
	while true do
		ok, msg = net.read(fd)
		if not ok then
			log("cmd[%d] netpackage read failed: connection[%d] aborted.", 
				expect_cmd, fd)
			return false
		end
		ok, sess, req_cmd, data = protocol.unserialize(msg)
		if not ok then
			log("cmd[%d] Connection[%d] protocol unserialize error.", 
				expect_cmd, fd)
			return false
		end
		if req_cmd == cmd.HEARTBEAT then
			Context[fd].session = sess
			local s2c_heartbeat = {
				cur_timestamp = skynet.time(),
			}
			write_cmd_msg(fd, cmd.HEARTBEAT, "protocol.s2c_heartbeat", s2c_heartbeat)
		else
			break
		end
	end
	if req_cmd ~= expect_cmd then
		log("Expect cmd[%d], get cmd[%d].", expect_cmd, req_cmd)
		return false
	end
	result, err = pb.decode(protostr, data)
	if err ~= nil then
		log("cmd[%d] protobuf decode error: %s.", expect_cmd, err)
		return false
	end
	Context[fd].session = sess
	Context[fd].time = skynet.time()
	Context[fd].cmd = req_cmd
	return true, result
end

local function handshake(fd)
	local data
	local ok
	local msg
	local result

	-- send challenge
	local challenge = crypt.randomkey()
	local s2c_challenge = {
		challenge = crypt.base64encode(challenge),
	}
	data = pb.encode("protocol.s2c_challenge", s2c_challenge)
	msg = protocol.serialize(0, cmd.LOGIN_CHALLENGE, data)
	net.write(fd, msg)

	-- exchange key
	ok, result = read_cmd_msg(fd, cmd.LOGIN_EXCHANGEKEY, "protocol.c2s_exchangekey")
	if not ok then
		return false
	end
	local s2c_serverkey = {
		code = errcode.SUCCESS,
	}
	local clientkey = crypt.base64decode(result.clientkey)
	--log("clientkey: %s.\n", strtohex(clientkey))
	if #clientkey ~= 8 then
		log("client key is not 8 byte length, got %d byte length.", #clientkey)
		s2c_serverkey.code = errcode.LOGIN_CLIENT_KEY_LEN_ILLEGAL
		write_cmd_msg(fd, cmd.LOGIN_EXCHANGEKEY, "protocol.s2c_exchangekey", s2c_serverkey)
		return false
	end
	local serverkey = crypt.randomkey()
	--log("serverkey: %s.\n", strtohex(serverkey))
	s2c_serverkey.serverkey = crypt.base64encode(crypt.dhexchange(serverkey))
	--log("client will recieve serverkey: %s.\n", strtohex(crypt.dhexchange(serverkey)))
	write_cmd_msg(fd, cmd.LOGIN_EXCHANGEKEY, "protocol.s2c_exchangekey", s2c_serverkey)

	-- handshake
	local secret = crypt.dhsecret(clientkey, serverkey)
	--log("secret: %s.\n", strtohex(secret))
	--log("base64(secret) : %s.\n", crypt.base64encode(secret))
	ok, result = read_cmd_msg(fd, cmd.LOGIN_HANDSHAKE, "protocol.c2s_handshake")
	if not ok then
		return false
	end
	local v = crypt.base64decode(result.encode_challenge)
	local hmac = crypt.hmac64_md5(challenge, secret)
	local s2c_handshake = {
		code = errcode.SUCCESS,
	}
	if v ~= hmac then
		s2c_handshake.code = errcode.LOGIN_HANDSHAKE_FAILED
		write_cmd_msg(fd, cmd.LOGIN_HANDSHAKE, "protocol.s2c_handshake", s2c_handshake)
		return false
	end
	write_cmd_msg(fd, cmd.LOGIN_HANDSHAKE, "protocol.s2c_handshake", s2c_handshake)

	Context[fd].secret = secret
	return true
end

local function dblogin(logininfo)
	local account = logininfo.openid
	local account_info
	local account_info_str
	local player
	local player_str
	local key
	local ret = db:hexists(ACCOUNT, account)
	if ret == 0 then
		-- register
		local uuidserver = skynet.queryservice("uuidserver")
		local uid = skynet.call(uuidserver, "lua", "get_player_uuid")
		account_info = {
			uid = uid,
			platformid = logininfo.platformid,
			openid = account,
			unionid = logininfo.unionid,
		}
		account_info_str = utils.table_to_str(account_info)
		ret = db:hset(ACCOUNT, account, account_info_str)
		if ret == 0 then
			return errcode.REGISTER_DB_ERR
		end
		local name
		if logininfo.nickname == "" then
			name = "player" .. tostring(os.time())
		else
			name = logininfo.nickname
		end
		player = {
			id = account_info.uid, 
			name = name,
			headimgurl = logininfo.headimgurl,
			level = 1,
			gold = 0,
			exp = 0,
		}
		player_str = utils.table_to_str(player)
		key = PLAYER .. tostring(account_info.uid)
		ret = db:setnx(key, player_str)
		if ret == 0 then
			return errcode.CREATE_PLAYER_DB_ERR
		end
	else
		-- login
		account_info_str = db:hget(ACCOUNT, account)
		account_info = utils.str_to_table(account_info_str)
	end
	return errcode.SUCCESS, account_info.uid
end

local function login(fd)
	local ok
	local result
	local secret = Context[fd].secret

	-- login 
	ok, result = read_cmd_msg(fd, cmd.LOGIN, "protocol.c2s_login")
	if not ok then
		return false
	end
	local s2c_login = {
		code = errcode.SUCCESS,
	}

	local openid = result.openid
	--[[
	local etoken = crypt.base64decode(result.token)
	local tokenstr = crypt.desdecode(secret, etoken)
	local token, platform = tokenstr:match("([^@]+)@(.+)")
	token = crypt.base64decode(token)
	platform = crypt.base64decode(platform)
	-- 去第三方验证token
	-- 暂时直接将token@platform作为Account存储
	--]]
	local login_manager = skynet.localname(".manager")
	local err, gate = skynet.call(login_manager, "lua", "prelogin", openid)
	if err ~= errcode.SUCCESS then
		s2c_login.code = err
		write_cmd_msg(fd, cmd.LOGIN, "protocol.s2c_login", s2c_login)
		return false
	end
	local uid 
	err, uid = dblogin(result)
	if err ~= errcode.SUCCESS then
		skynet.call(login_manager, "lua", "loginfailed", openid)
		s2c_login.code = err
		write_cmd_msg(fd, cmd.LOGIN, "protocol.s2c_login", s2c_login)
		return false
	end
	local subid
	local server_addr
	err, subid, server_addr = skynet.call(gate, "lua", "login", openid, uid, secret)
	if err ~= errcode.SUCCESS then
		skynet.call(login_manager, "lua", "loginfailed", openid)
		s2c_login.code = err
		write_cmd_msg(fd, cmd.LOGIN, "protocol.s2c_login", s2c_login)
		return false
	end
	skynet.call(login_manager, "lua", "login", openid, gate)
	s2c_login.info = {
		subid = crypt.base64encode(subid),
		server_addr = crypt.base64encode(server_addr),
	}
	write_cmd_msg(fd, cmd.LOGIN, "protocol.s2c_login", s2c_login)

	return true
end

local function handle(fd)
	Context[fd] = {
		session = 0,
		time = skynet.time(),
	}
	socket.start(fd)

	local ok = handshake(fd)
	if not ok then
		log("fd[%d] handshake failed!", fd)
		socket.close(fd)
		return
	end

	ok = login(fd)
	if not ok then
		log("fd[%d] login failed!", fd)
		socket.close(fd)
		return
	end

	socket.close(fd)
end

local CMD = {}

function CMD.handle(fd)
	skynet.fork(handle, fd)
end

skynet.init( function ()
	local load_file = {
		"common/heartbeat.pb",
		"login/challenge.pb",
		"login/exchangekey.pb",
		"login/handshake.pb",
		"login/login.pb",
		"login/launch.pb",
	}
	for _,file in ipairs(load_file) do
		pb.register_file(skynet.getenv("root") .. "proto/" .. file)
	end
	db = redis.connect {
		host = "127.0.0.1" ,
		port = 6379 ,
		db = 0 ,
	}
end)

skynet.start( function ()
	skynet.dispatch("lua", function (sess, src, command, ...)
		local f = CMD[command]
		if f then
			if sess ~= 0 then
				skynet.ret(skynet.pack(f(...)))
			else
				f(...)
			end
		else
			log("Unknown login slave command: %s.", command)
			skynet.response()(false)
		end
	end)
end)
