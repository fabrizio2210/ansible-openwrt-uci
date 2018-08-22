#!/usr/bin/lua
-- WANT_JSON
	
do
	local _ENV = _ENV
	package.preload["ansible"] = function( ... )
		local arg = _G.arg;
		_ENV = _ENV;

		local Ansible = {}

local io   = require("io")
local json = require("dkjson")
local ubus = require("ubus")

Ansible.__index = Ansible

function Ansible.new(spec) 
	local self = setmetatable({}, Ansible)
	self.spec = spec
	for k,v in pairs(spec) do
		v['name'] = k
	end
	self.params = nil
	return self
end

local function split(str, delimiter)
	local toks = {}

	for tok in string.gmatch(str, "[^".. delimiter .. "]+") do
		toks[#toks + 1] = tok
	end

	return toks
end

local function append(t1, t2)
	for k,v in ipairs(t2) do
		t1[#t1 + 1] = v
	end
	return t1
end

function Ansible.contains(needle, haystack)
	for _,v in pairs(haystack) do
		if needle == v then
			return true
		end
	end

	return false
end

local function findspec(name, spec)
	if spec[name] then
		return spec[name]
	end

	-- check whether an alias exists
	for k,v in pairs(spec) do
		if type(v) == "table" and v['aliases'] then
			if Ansible.contains(name, v['aliases']) then
				return v
			end
		end
	end

	return nil
end

local function canonicalize(params, spec)
	local copy = {}
	for k,v in pairs(params) do
		local desc = findspec(k, spec)
		if not desc then
			-- ignore _ansible parameters
			if 1 ~= string.find(k, "_ansible") then
				return nil, "no such parameter " .. k
			end
		else
			if copy[desc['name']] then
				return nil, "duplicate parameter " .. desc['name']
			end
			copy[desc['name']] = v
		end
	end

	params = copy

	return copy
end

function Ansible:slurp(path)
	local f, err = io.open(path, "r")
	if f == nil then
		Ansible.fail_json({msg="failed to open file " .. path .. ": " .. err})
	end
	local content = f:read("*a")
	if content == nil then
		self:fail_json({msg="read from file " .. path .. "failed"})
	end
	f:close()
	return content
end

function Ansible:unslurp(path, content)
	local f, err = io.open(path, "w+")
	if f == nil then
		Ansible.fail_json({msg="failed to open file " .. path .. ": " .. err})
	end
	
	local res = f:write(content)

	if not res then
		self:fail_json({msg="read from file " .. path .. "failed"})
	end
	f:close()
	return res
end

local function parse_dict_from_string(str)
	if 1 == string.find(str, "{") then
		-- assume json, try to decode it
		local dict, pos, err = json.decode(str)
		if not err then
			return dict
		end
	elseif string.find(str, "=") then
		fields = {}
		field_buffer = ""
		in_quote = nil
		in_escape = false
		for c in str:gmatch(".") do
			if in_escape then
				field_buffer = field_buffer .. c
				in_escape = false
			elseif c == '\\' then
				in_escape = true
			elseif not in_quote and ('\'' == c or '"' == c) then
				in_quote = c
			elseif in_quote and in_quote == c then
				in_quote = nil
			elseif not in_quote and (',' == c or ' ' == c) then
				if string.len(field_buffer) > 0 then
					fields[#fields + 1] = field_buffer
				end
				field_buffer=""
			else
				field_buffer = field_buffer .. c
			end
		end
		-- append the final field
		fields[#fields + 1] = field_buffer

		local dict = {}

		for _,v in ipairs(fields) do
			local key, val = string.match(v, "^([^=]+)=(.*)")

			if key and val then
				dict[key] = val
			end
		end

		return dict
	end

	return nil, str ..  " dictionary requested, could not parse JSON or key=value"
end

local function check_transform_type(variable, ansibletype)
	-- Types: str list dict bool int float path raw jsonarg
	if     "str"     == ansibletype then
		if type(variable) == "string" then
			return variable
		end
	elseif "list"    == ansibletype then
		if type(variable) == "table" then
			return variable
		end

		if type(variable) == "string" then
			return split(variable, ",")
		elseif type(variable) == "number" then
			return {variable}
		end
	elseif "dict"    == ansibletype then
		if type(variable) == "table" then
			return variable
		elseif type(variable) == "string" then
			return parse_dict_from_string(variable)
		end
	elseif "bool"    == ansibletype then
		if "boolean" == type(variable) then
			return variable
		elseif "number" == type(variable) then
			return not (0 == variable)
		elseif "string" == type(variable) then
			local BOOLEANS_TRUE  = {'yes', 'on', '1', 'true', 'True'}
			local BOOLEANS_FALSE = {'no', 'off', '0', 'false', 'False'}

			if Ansible.contains(variable, BOOLEANS_TRUE) then
				return true
			elseif Ansible.contains(variable, BOOLEANS_FALSE) then
				return false
			end
		end
	elseif "int"     == ansibletype or "float"   == ansibletype then
		if type(variable) == "string" then
			local var = tonumber(variable)
			if var then
				return var
			end
		elseif type(variable) == "number" then
			return variable
		end
	elseif "path"    == ansibletype then
		-- A bit basic, i know
		if type(variable) == "string" then
			return variable
		end
	elseif "raw"     == ansibletype then
		return variable
	elseif "jsonarg" == ansibletype then
		if     "table" == type(variable) then
			return variable
		elseif "string" == type(variable) then
			local dict, pos, err = json.decode(variable)
			if not err then
				return dict
			end
		end
	else
		return nil, ansibletype .. " is not a known type"
	end

	return nil, tostring(variable) .. " does not conform to type " .. ansibletype
end

function Ansible:parse(inputfile)
	local params, pos, err = json.decode(self:slurp(inputfile))

	if err then
		self:fail_json({msg="INTERNAL: Illegal json input received"})
	end

	-- resolve aliases
	params, err = canonicalize(params, self.spec)

	if not params then
		self:fail_json({msg="Err: " .. tostring(err)})
	end

	for k,v in pairs(self.spec) do
		-- setup defaults
		if v['default'] then
			if nil == params[k] then
				params[k] = v['default']
			end
		end

		-- assert requires
		if v['required'] then
			if not params[k] then
				self:fail_json({msg="Required parameter " .. k .. " not provided"})
			end
		end
	end
	
	-- check types/choices
	for k,v in pairs(params) do
		local typedesc = self.spec[k]['type']
		if typedesc then
			local val, err = check_transform_type(v, typedesc)
			if nil ~= val then
				params[k] = val
			else
				self:fail_json({msg="Err: " .. tostring(err)})
			end
		end

		local choices = self.spec[k]['choices']
		if choices then
			if not Ansible.contains(v, choices) then
				self:fail_json({msg=v .. " not a valid choice for " .. k})
			end
		end
	end

	self.params = params

	return params
end

local function file_exists(path)
	local f=io.open(path,"r")
	if f~=nil then
		io.close(f)
		return true
	else
		return false
	end
end

function Ansible:get_bin_path(name, required, candidates)
	if not candidates then
		candidates = {}
	end

	local path = os.getenv("PATH")
	if path then
		candidates = append(candidates, split(path, ":"))
	end

	for _,dir in pairs(candidates) do
		local fpath = dir .. "/" .. name
		if file_exists(fpath) then
			return fpath
		end
	end

	if required then
		self:fail_json({msg="No executable " .. name .. " found in PATH or candidates"})
	end
	
	return nil
end

function Ansible:remove_file(path)
	local rc, err = os.remove(path)
	if nil == rc then
		self:fail_json({msg="Internal, execute: failed to remove file " .. path})
	end
	return rc
end

local function get_version()
	local version = assert(string.match(_VERSION, "Lua (%d+.%d+)"))
	return tonumber(version) -- Aaaah, it hurts to use floating point like this...
end

function Ansible:run_command(command)
	local stdout = os.tmpname()
	local stderr = os.tmpname()

	local cmd = string.format("%s >%q 2>%q", command, stdout, stderr)

	local rc = nil
	if 5.1 < get_version() then
		_, _, rc = os.execute(cmd)
	else
		rc       = os.execute(cmd)
	end

	local out = self:slurp(stdout)
	local err = self:slurp(stderr)
	
	self:remove_file(stdout)
	self:remove_file(stderr)

	return rc, out, err
end

function Ansible:copy(src, dest)
	local command = string.format("cp -f %q %q", src, dest)
	local rc, _,  err = self:run_command(command)

	if rc ~= 0 then
		return false, err
	else
		return true, err
	end
end

function Ansible:move(src, dest)
	local command = string.format("mv -f %q %q", src, dest)
	local rc, _,  err = self:run_command(command)

	if rc ~= 0 then
		return false, err
	else
		return true, err
	end
end

function Ansible:fail_json(kwargs)
	assert(kwargs['msg'])
	kwargs['failed'] = true
	if nil == kwargs['changed'] then
		kwargs['changed'] = false
	end
	if nil == kwargs['invocation'] then
		kwargs['invocations'] = {module_args=self.params}
	end

	io.write(json.encode(kwargs))
	os.exit(1)
end

function Ansible:exit_json(kwargs)
	assert(kwargs['msg'])
	if nil == kwargs['changed'] then
		kwargs['changed'] = false
	end
	if nil == kwargs['invocation'] then
		kwargs['invocations'] = {module_args=self:get_params()}
	end

	io.write(json.encode(kwargs))
	os.exit(0)
end

function Ansible:get_params()
	return self.params
end

function Ansible:ubus_connect()
	local p = self:get_params()
	local timeout = p['timeout']
	if not timeout then
		timeout = 30
	end
	local socket = p['socket']

	local conn = ubus.connect(socket, timeout)
	if not conn then
		self:fail_json({msg="Failed to connect to ubus"})
	end

	return conn
end

function Ansible:ubus_call(conn, namespace, procedure, arg)
	local res, status = conn:call(namespace, procedure, arg)

	if nil ~= status and 0 ~= status then
		self:fail_json({msg="Ubus call failed", call={namespace=namespace, procedure=procedure, arg=arg, status=status}})
	end

	return res
end

function Ansible:backup_local(file)
	local backupdest

	if file_exits(file) then
		local ext = os.time("%Y-%m-%d@H:%M:%S~")

		backupdest = string.format("%s.%s", file, ext)

		local content = self:slurp(file)
		local res = self:unslurp(backupdest, content)
	end

	return backupdest
end

function Ansible:is_dir(path)
	local f, err, code = io.open(path, "r")

	if nil == f then
		return false, err, code
	end

	local ok, err, code = f:read(1)
	f:close()
	return code == 21, nil, nil
end

function Ansible:check_mode()
	-- FIXME
	return false
end

return Ansible

	end
	package.preload["fileutils"] = function( ... )
		local arg = _G.arg;
		_ENV = _ENV;

		local FileUtil = {}

local unistd  = require("posix.unistd")
local stat    = require("posix.sys.stat")
local stdlib  = require("posix.stdlib")
local libgen  = require("posix.libgen")
local pwd     = require("posix.pwd")
local grp     = require("posix.grp")
local os      = require("os")
local bm      = require("BinDecHex")
local perrno  = require("posix.errno")
local utime   = require("posix.utime")
local stdio   = require("posix.stdio")
local dirent  = require("posix.dirent")

FileUtil.__index = FileUtil

function FileUtil.md5(module, path)
	local command = string.format("md5sum %q", path)
	local res, out, err = module:run_command(command)

	if res ~= 0 then
		module:fail_json({msg="Failed to determine the md5sum for " .. path, error=err})
	end

	local md5sum = string.match(out, "^[^%s\n]+")

	return md5sum
end

function FileUtil.sha1(module, path)
	local command = string.format("sha1sum %q", path)
	local res, out, err = module:run_command(command)

	if res ~= 0 then
		module:fail_json({msg="Failed to determine the sha1sum for " .. path, error=err})
	end

	local sha1sum = string.match(out, "^[^%s\n]+")

	return sha1sum
end

function FileUtil.expanduser(path)
	if path == nil then
		return nil
	end
	local home = os.getenv("HOME")

	return string.gsub(path, "^~", home)
end

function FileUtil.lexists(path)
	local status, errstr, errno = unistd.access(path, "f")

	return 0 == status, errstr, errno
end

function FileUtil.exists(path)
	local status, errstr, errno = unistd.access(path, "f")

	return 0 == status, errstr, errno
end

function FileUtil.readable(path)
	local status, errstr, errno = unistd.access(path, "r")

	return 0 == status, errstr, errno
end

function FileUtil.writeable(path)
	local status, errstr, errno = unistd.access(path, "w")

	return 0 == status, errstr, errno
end

function FileUtil.isdir(path)
	local pstat = stat.stat(path)

	if pstat then
		return 0 ~= stat.S_ISDIR(pstat['st_mode'])
	else
		return false
	end
end

function FileUtil.islnk(path)
	local pstat = stat.lstat(path)

	if pstat then
		return 0 ~= stat.S_ISLNK(pstat['st_mode'])
	else
		return false
	end
end

function FileUtil.stat(path)
	return stat.stat(path)
end

function FileUtil.lstat(path)
	return stat.lstat(path)
end

function FileUtil.realpath(path)
	return stdlib.realpath(path)
end

function FileUtil.readlink(path)
	return unistd.readlink(path)
end

function FileUtil.basename(path)
	return libgen.basename(path)
end

function FileUtil.dirname(path)
	return libgen.dirname(path)
end

function FileUtil.rmtree(path, opts)
	local args = "-r"

	if opts['ignore_errors'] then
		args = args .. "f"
	end

	local cmd = string.format("rm %s %q", args, path)

	local rc = nil
	if 5.1 < get_version() then
		_, _, rc = os.execute(cmd)
	else
		rc       = os.execute(cmd)
	end

	return rc ~= 0
end

function FileUtil.unlink(path)
	local status, errstr, errno = unistd.unlink(path)

	return 0 == status, errstr, errno
end

function FileUtil.get_user_and_group(path)
	local stat = FileUtil.stat(path)
	if stat then
		return stat['st_uid'], stat['st_gid']
	else
		return nil, nil
	end
end

function FileUtil.parse_owner(owner)
	local uid = tonumber(owner)
	if (uid == nil) then
		local pwnam = pwd.getpwnam(owner)
		if pwnam ~= nil then
			uid = pwnam['pw_uid']
		end
	end
	return uid
end

function FileUtil.parse_group(group)
	local gid = tonumber(group)
	if (gid == nil) then
		local grnam = grp.getgrnam(group)
		if grnam ~= nil then
			gid = grnam['gr_gid']
		end
	end
	return gid
end

function FileUtil.lchown(path, uid, gid)
	local ret, errstr, errno
	-- lchown is only present in luaposix since 30.07.2016
	if unistd['lchown'] then
		ret, errstr, errno = unistd.lchown(path, uid, gid)
	else
		ret, errstr, errno = unistd.chown(path, uid, gid)
	end
	return ret == 0, errstr, errno
end

function FileUtil.set_owner_if_different(module, path, owner, changed, diff)
	path = FileUtil.expanduser(path)
	if owner == nil then
		return changed
	end
	local orig_uid, orig_gid = FileUtil.get_user_and_group(path)
	local uid = FileUtil.parse_owner(owner)
	if nil == uid then
		module:fail_json({path=path, msg='chown failed: failed to look up user ' .. tostring(owner)})
	end
	if orig_uid ~= uid then
		if nil ~= diff then
			if nil == diff['before'] then
				diff['before'] = {}
			end
			diff['before']['owner'] = orig_uid
			if nil == diff['after'] then
				diff['after'] = {}
			end
			diff['after']['owner'] = uid
		end
	
		if module:check_mode() then
			return true
		end
		-- FIXME: sorry if there is no chown we fail the sematic slightly... but i don't care
		if not FileUtil.lchown(path, uid, -1) then
			module:fail_json({path=path, msg='chown failed'})
		end
		changed = true
	end
	return changed
end

function FileUtil.set_group_if_different(module, path, group, changed, diff)
	path = FileUtil.expanduser(path)
	if group == nil then
		return changed
	end
	local orig_uid, orig_gid = FileUtil.get_user_and_group(path)
	local gid = FileUtil.parse_group(group)
	if nil == gid then
		module:fail_json({path=path, msg='chgrp failed: failed to look up group ' .. tostring(group)})
	end
	if orig_gid ~= gid then
		if nil ~= diff then
			if nil == diff['before'] then
				diff['before'] = {}
			end
			diff['before']['group'] = orig_gid
			if nil == diff['after'] then
				diff['after'] = {}
			end
			diff['after']['group'] = gid
		end
	
		if module:check_mode() then
			return true
		end
		-- FIXME: sorry if there is no chown we fail the sematic slightly... but i don't care
		if not FileUtil.lchown(path, -1, gid) then
			module:fail_json({path=path, msg='chgrp failed'})
		end
		changed = true
	end
	return changed
end

local function tohex(int)
	return bm.Dec2Hex(string.format("%d", int))
end

function FileUtil.S_IMODE(mode)
	-- man 2 stat
	-- "... and the least significant 9 bits (0777) as the file permission bits"
	return tonumber(bm.Hex2Dec(bm.BMAnd(tohex(mode), tohex(0x1ff))))
end

function FileUtil.lchmod(path, mode)
	if not FileUtil.islnk(path) then
		local ret, errstr, errno = stat.chmod(path, mode)
		return ret == 0, errstr, errno
	end
	return true, nil, nil
end

function FileUtil.set_mode_if_different(module, path, mode, changed, diff)
	path = FileUtil.expanduser(path)
	local path_stat = FileUtil.lstat(path)

	if mode == nil then
		return changed
	end

	if type(mode) ~= "number" then
		mode = tonumber(mode, 8)
		if nil == mode then
			module:fail_json({path=path, msg="mode must be in octal form (currently symbolic form is not supported, sorry)"})
		end
	end
	if mode ~= FileUtil.S_IMODE(mode) then
		-- prevent mode from having extra info or being invald long number
		module:fail_json({path=path, msg="Invalid mode supplied, only permission info is allowed", details=mode})
	end

	local prev_mode = FileUtil.S_IMODE(path_stat['st_mode'])

	if prev_mode ~= mode then
		if nil ~= diff then
			if nil == diff['before'] then
				diff['before'] = {}
			end
			diff['before']['mode'] = string.format("%o", prev_mode)
			if nil == diff['after'] then
				diff['after'] = {}
			end
			diff['after']['mode'] = string.format("%o", mode)
		end

		if module:check_mode() then
			return true
		end

		local res, errstr, errno = FileUtil.lchmod(path, mode)
		if not res then
			if errno ~= perrno['EPERM'] and errno ~= perrno['ELOOP'] then
				module:fail_json({path=path, msg='chmod failed', details=errstr})
			end
		end

		path_stat = FileUtil.lstat(path)
		local new_mode = FileUtil.S_IMODE(path_stat['st_mode'])
		
		if new_mode ~= prev_mode then
			changed = true
		end
	end
	return changed
end

function FileUtil.set_fs_attributes_if_different(module, file_args, changed, diff)
	changed = FileUtil.set_owner_if_different(module, file_args['path'], file_args['owner'], changed, diff)
	changed = FileUtil.set_group_if_different(module, file_args['path'], file_args['group'], changed, diff)
	changed = FileUtil.set_mode_if_different(module, file_args['path'], file_args['mode'], changed, diff)
	return changed
end

function FileUtil.isabs(path)
	return 1 == string.find(path, "/")
end

function FileUtil.mkdir(path)
	local status, errstr, errno = stat.mkdir(path)
	return 0 == status, errstr, errno
end

function FileUtil.walk(path, follow)
	local entries = {}
	local stack   = {path}
	local i = 1
	while i <= #stack do
		local cur = stack[i]
		
		local ok, dir = pcall(dirent.dir, cur)

		local entry = { root=cur }
		local dirs = {}
		local files = {}
		if ok and dir ~= nil then
			for _, entry in ipairs(dir) do
				if "." ~= entry and ".." ~= entry then
					local child = cur .. "/" .. entry
					if follow and FileUtil.islnk(child) then
						local dst = FileUtil.realpath(child)
						dirs[#dirs + 1]   = entry
						stack[#stack + 1] = dst
					elseif FileUtil.isdir(child) then
						dirs[#dirs + 1]   = entry
						stack[#stack + 1] = child
					else
						files[#files + 1] = entry
					end
				end
			end
		end
		entry['dirs']  = dirs
		entry['files'] = files
		entries[#entries + 1] = entry
		i = i + 1
	end

	return entries
end

function FileUtil.listdir(path)
	local ok, dir = pcall(dirent.dir, path)
	if not ok then
		return nil
	end

	local entries = {}

	for _, k in ipairs(dir) do
		if k ~= "." and k ~= ".."  then
			entries[#entries + 1] = k
		end
	end

	return entries
end

function FileUtil.rmdir(path)
	local status, errstr, errno = unistd.rmdir(path)

	return 0 == status, errstr, errno
end

function FileUtil.link(target, link)
	local status, errstr, errno = unistd.link(target, link, false)

	return 0 == status, errstr, errno
end

function FileUtil.symlink(target, link)
	local status, errstr, errno = unistd.link(target, link, true)

	return 0 == status, errstr, errno
end

function FileUtil.unlink(path)
	local status, errstr, errno = unistd.unlink(path)

	return 0 == status, errstr, errno
end

function FileUtil.touch(path)
	local file, errmsg = io.open(path, "w")
	if file ~= nil then
		io.close(file)
	end
	return file ~= nil, errmsg
end

function FileUtil.utime(path)
	local status, errstr, errno = utime.utime(path)

	return 0 == status, errstr, errno
end

function FileUtil.join(path, paths)
	for _, segment in ipairs(paths) do
		if segment ~= nil then
			if FileUtil.isabs(segment) then
				path = segment
			else
				path = path .. "/" .. segment
			end
		end
	end

	return path
end

function FileUtil.rename(oldpath, newpath)
	local status, errstr, errno
	if nil ~= stdio['rename'] then
		status, errstr, errno = stdio.rename(oldpath, newpath)
		status = status == 0
	else
		status, errstr, errno = os.rename(oldpath, newpath)
	end

	return status, errstr, errno
end

function FileUtil.split(path)
	local tail = FileUtil.basename(path)
	local head = FileUtil.dirname(path)
	return head, tail
end

function FileUtil.split_pre_existing_dir(dirname)
	-- Return the first pre-existing directory and a list of the new directories that will be created
	local head, tail = FileUtil.split(dirname)

	local pre_existing_dir, new_directory_list
	if not FileUtil.exists(head) then
		pre_existing_dir, new_directory_list = FileUtil.split_pre_existing_dir(head)
	else
		return head, {tail}
	end
	new_directory_list[#new_directory_list + 1] = tail
	return pre_existing_dir, new_directory_list
end

function FileUtil.mkdirs(path)
	local exists, new = FileUtil.split_pre_existing_dir(path)

	for _, seg in ipairs(new) do
		exists = exists .. "/" .. seg
		local res, errstr, errno = FileUtil.mkdir(exists)
		if not res then
			return res, errstr, errno
		end
	end
	return true
end

function FileUtil.mkstemp(pattern)
	local fd, path = stdlib.mkstemp(pattern)
	if -1 ~= fd and type(fd) == "number" then
		unistd.close(fd)
		return path
	else
		return nil, path -- path is a errmsg in this case
	end
end

return FileUtil

	end
	package.preload["dkjson"] = function( ... )
		local arg = _G.arg;
		_ENV = _ENV;

		-- Module options:
local always_try_using_lpeg = true
local register_global_module_table = false
local global_module_name = 'json'

--[==[

David Kolf's JSON module for Lua 5.1/5.2

Version 2.5


For the documentation see the corresponding readme.txt or visit
<http://dkolf.de/src/dkjson-lua.fsl/>.

You can contact the author by sending an e-mail to 'david' at the
domain 'dkolf.de'.


Copyright (C) 2010-2013 David Heiko Kolf

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

--]==]

-- global dependencies:
local pairs, type, tostring, tonumber, getmetatable, setmetatable, rawset =
      pairs, type, tostring, tonumber, getmetatable, setmetatable, rawset
local error, require, pcall, select = error, require, pcall, select
local floor, huge = math.floor, math.huge
local strrep, gsub, strsub, strbyte, strchar, strfind, strlen, strformat =
      string.rep, string.gsub, string.sub, string.byte, string.char,
      string.find, string.len, string.format
local strmatch = string.match
local concat = table.concat

local json = { version = "dkjson 2.5" }

if register_global_module_table then
  _G[global_module_name] = json
end

local _ENV = nil -- blocking globals in Lua 5.2

pcall (function()
  -- Enable access to blocked metatables.
  -- Don't worry, this module doesn't change anything in them.
  local debmeta = require "debug".getmetatable
  if debmeta then getmetatable = debmeta end
end)

json.null = setmetatable ({}, {
  __tojson = function () return "null" end
})

local function isarray (tbl)
  local max, n, arraylen = 0, 0, 0
  for k,v in pairs (tbl) do
    if k == 'n' and type(v) == 'number' then
      arraylen = v
      if v > max then
        max = v
      end
    else
      if type(k) ~= 'number' or k < 1 or floor(k) ~= k then
        return false
      end
      if k > max then
        max = k
      end
      n = n + 1
    end
  end
  if max > 10 and max > arraylen and max > n * 2 then
    return false -- don't create an array with too many holes
  end
  return true, max
end

local escapecodes = {
  ["\""] = "\\\"", ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n",  ["\r"] = "\\r",  ["\t"] = "\\t"
}

local function escapeutf8 (uchar)
  local value = escapecodes[uchar]
  if value then
    return value
  end
  local a, b, c, d = strbyte (uchar, 1, 4)
  a, b, c, d = a or 0, b or 0, c or 0, d or 0
  if a <= 0x7f then
    value = a
  elseif 0xc0 <= a and a <= 0xdf and b >= 0x80 then
    value = (a - 0xc0) * 0x40 + b - 0x80
  elseif 0xe0 <= a and a <= 0xef and b >= 0x80 and c >= 0x80 then
    value = ((a - 0xe0) * 0x40 + b - 0x80) * 0x40 + c - 0x80
  elseif 0xf0 <= a and a <= 0xf7 and b >= 0x80 and c >= 0x80 and d >= 0x80 then
    value = (((a - 0xf0) * 0x40 + b - 0x80) * 0x40 + c - 0x80) * 0x40 + d - 0x80
  else
    return ""
  end
  if value <= 0xffff then
    return strformat ("\\u%.4x", value)
  elseif value <= 0x10ffff then
    -- encode as UTF-16 surrogate pair
    value = value - 0x10000
    local highsur, lowsur = 0xD800 + floor (value/0x400), 0xDC00 + (value % 0x400)
    return strformat ("\\u%.4x\\u%.4x", highsur, lowsur)
  else
    return ""
  end
end

local function fsub (str, pattern, repl)
  -- gsub always builds a new string in a buffer, even when no match
  -- exists. First using find should be more efficient when most strings
  -- don't contain the pattern.
  if strfind (str, pattern) then
    return gsub (str, pattern, repl)
  else
    return str
  end
end

local function quotestring (value)
  -- based on the regexp "escapable" in https://github.com/douglascrockford/JSON-js
  value = fsub (value, "[%z\1-\31\"\\\127]", escapeutf8)
  if strfind (value, "[\194\216\220\225\226\239]") then
    value = fsub (value, "\194[\128-\159\173]", escapeutf8)
    value = fsub (value, "\216[\128-\132]", escapeutf8)
    value = fsub (value, "\220\143", escapeutf8)
    value = fsub (value, "\225\158[\180\181]", escapeutf8)
    value = fsub (value, "\226\128[\140-\143\168-\175]", escapeutf8)
    value = fsub (value, "\226\129[\160-\175]", escapeutf8)
    value = fsub (value, "\239\187\191", escapeutf8)
    value = fsub (value, "\239\191[\176-\191]", escapeutf8)
  end
  return "\"" .. value .. "\""
end
json.quotestring = quotestring

local function replace(str, o, n)
  local i, j = strfind (str, o, 1, true)
  if i then
    return strsub(str, 1, i-1) .. n .. strsub(str, j+1, -1)
  else
    return str
  end
end

-- locale independent num2str and str2num functions
local decpoint, numfilter

local function updatedecpoint ()
  decpoint = strmatch(tostring(0.5), "([^05+])")
  -- build a filter that can be used to remove group separators
  numfilter = "[^0-9%-%+eE" .. gsub(decpoint, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0") .. "]+"
end

updatedecpoint()

local function num2str (num)
  return replace(fsub(tostring(num), numfilter, ""), decpoint, ".")
end

local function str2num (str)
  local num = tonumber(replace(str, ".", decpoint))
  if not num then
    updatedecpoint()
    num = tonumber(replace(str, ".", decpoint))
  end
  return num
end

local function addnewline2 (level, buffer, buflen)
  buffer[buflen+1] = "\n"
  buffer[buflen+2] = strrep ("  ", level)
  buflen = buflen + 2
  return buflen
end

function json.addnewline (state)
  if state.indent then
    state.bufferlen = addnewline2 (state.level or 0,
                           state.buffer, state.bufferlen or #(state.buffer))
  end
end

local encode2 -- forward declaration

local function addpair (key, value, prev, indent, level, buffer, buflen, tables, globalorder, state)
  local kt = type (key)
  if kt ~= 'string' and kt ~= 'number' then
    return nil, "type '" .. kt .. "' is not supported as a key by JSON."
  end
  if prev then
    buflen = buflen + 1
    buffer[buflen] = ","
  end
  if indent then
    buflen = addnewline2 (level, buffer, buflen)
  end
  buffer[buflen+1] = quotestring (key)
  buffer[buflen+2] = ":"
  return encode2 (value, indent, level, buffer, buflen + 2, tables, globalorder, state)
end

local function appendcustom(res, buffer, state)
  local buflen = state.bufferlen
  if type (res) == 'string' then
    buflen = buflen + 1
    buffer[buflen] = res
  end
  return buflen
end

local function exception(reason, value, state, buffer, buflen, defaultmessage)
  defaultmessage = defaultmessage or reason
  local handler = state.exception
  if not handler then
    return nil, defaultmessage
  else
    state.bufferlen = buflen
    local ret, msg = handler (reason, value, state, defaultmessage)
    if not ret then return nil, msg or defaultmessage end
    return appendcustom(ret, buffer, state)
  end
end

function json.encodeexception(reason, value, state, defaultmessage)
  return quotestring("<" .. defaultmessage .. ">")
end

encode2 = function (value, indent, level, buffer, buflen, tables, globalorder, state)
  local valtype = type (value)
  local valmeta = getmetatable (value)
  valmeta = type (valmeta) == 'table' and valmeta -- only tables
  local valtojson = valmeta and valmeta.__tojson
  if valtojson then
    if tables[value] then
      return exception('reference cycle', value, state, buffer, buflen)
    end
    tables[value] = true
    state.bufferlen = buflen
    local ret, msg = valtojson (value, state)
    if not ret then return exception('custom encoder failed', value, state, buffer, buflen, msg) end
    tables[value] = nil
    buflen = appendcustom(ret, buffer, state)
  elseif value == nil then
    buflen = buflen + 1
    buffer[buflen] = "null"
  elseif valtype == 'number' then
    local s
    if value ~= value or value >= huge or -value >= huge then
      -- This is the behaviour of the original JSON implementation.
      s = "null"
    else
      s = num2str (value)
    end
    buflen = buflen + 1
    buffer[buflen] = s
  elseif valtype == 'boolean' then
    buflen = buflen + 1
    buffer[buflen] = value and "true" or "false"
  elseif valtype == 'string' then
    buflen = buflen + 1
    buffer[buflen] = quotestring (value)
  elseif valtype == 'table' then
    if tables[value] then
      return exception('reference cycle', value, state, buffer, buflen)
    end
    tables[value] = true
    level = level + 1
    local isa, n = isarray (value)
    if n == 0 and valmeta and valmeta.__jsontype == 'object' then
      isa = false
    end
    local msg
    if isa then -- JSON array
      buflen = buflen + 1
      buffer[buflen] = "["
      for i = 1, n do
        buflen, msg = encode2 (value[i], indent, level, buffer, buflen, tables, globalorder, state)
        if not buflen then return nil, msg end
        if i < n then
          buflen = buflen + 1
          buffer[buflen] = ","
        end
      end
      buflen = buflen + 1
      buffer[buflen] = "]"
    else -- JSON object
      local prev = false
      buflen = buflen + 1
      buffer[buflen] = "{"
      local order = valmeta and valmeta.__jsonorder or globalorder
      if order then
        local used = {}
        n = #order
        for i = 1, n do
          local k = order[i]
          local v = value[k]
          if v then
            used[k] = true
            buflen, msg = addpair (k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
            prev = true -- add a seperator before the next element
          end
        end
        for k,v in pairs (value) do
          if not used[k] then
            buflen, msg = addpair (k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
            if not buflen then return nil, msg end
            prev = true -- add a seperator before the next element
          end
        end
      else -- unordered
        for k,v in pairs (value) do
          buflen, msg = addpair (k, v, prev, indent, level, buffer, buflen, tables, globalorder, state)
          if not buflen then return nil, msg end
          prev = true -- add a seperator before the next element
        end
      end
      if indent then
        buflen = addnewline2 (level - 1, buffer, buflen)
      end
      buflen = buflen + 1
      buffer[buflen] = "}"
    end
    tables[value] = nil
  else
    return exception ('unsupported type', value, state, buffer, buflen,
      "type '" .. valtype .. "' is not supported by JSON.")
  end
  return buflen
end

function json.encode (value, state)
  state = state or {}
  local oldbuffer = state.buffer
  local buffer = oldbuffer or {}
  state.buffer = buffer
  updatedecpoint()
  local ret, msg = encode2 (value, state.indent, state.level or 0,
                   buffer, state.bufferlen or 0, state.tables or {}, state.keyorder, state)
  if not ret then
    error (msg, 2)
  elseif oldbuffer == buffer then
    state.bufferlen = ret
    return true
  else
    state.bufferlen = nil
    state.buffer = nil
    return concat (buffer)
  end
end

local function loc (str, where)
  local line, pos, linepos = 1, 1, 0
  while true do
    pos = strfind (str, "\n", pos, true)
    if pos and pos < where then
      line = line + 1
      linepos = pos
      pos = pos + 1
    else
      break
    end
  end
  return "line " .. line .. ", column " .. (where - linepos)
end

local function unterminated (str, what, where)
  return nil, strlen (str) + 1, "unterminated " .. what .. " at " .. loc (str, where)
end

local function scanwhite (str, pos)
  while true do
    pos = strfind (str, "%S", pos)
    if not pos then return nil end
    local sub2 = strsub (str, pos, pos + 1)
    if sub2 == "\239\187" and strsub (str, pos + 2, pos + 2) == "\191" then
      -- UTF-8 Byte Order Mark
      pos = pos + 3
    elseif sub2 == "//" then
      pos = strfind (str, "[\n\r]", pos + 2)
      if not pos then return nil end
    elseif sub2 == "/*" then
      pos = strfind (str, "*/", pos + 2)
      if not pos then return nil end
      pos = pos + 2
    else
      return pos
    end
  end
end

local escapechars = {
  ["\""] = "\"", ["\\"] = "\\", ["/"] = "/", ["b"] = "\b", ["f"] = "\f",
  ["n"] = "\n", ["r"] = "\r", ["t"] = "\t"
}

local function unichar (value)
  if value < 0 then
    return nil
  elseif value <= 0x007f then
    return strchar (value)
  elseif value <= 0x07ff then
    return strchar (0xc0 + floor(value/0x40),
                    0x80 + (floor(value) % 0x40))
  elseif value <= 0xffff then
    return strchar (0xe0 + floor(value/0x1000),
                    0x80 + (floor(value/0x40) % 0x40),
                    0x80 + (floor(value) % 0x40))
  elseif value <= 0x10ffff then
    return strchar (0xf0 + floor(value/0x40000),
                    0x80 + (floor(value/0x1000) % 0x40),
                    0x80 + (floor(value/0x40) % 0x40),
                    0x80 + (floor(value) % 0x40))
  else
    return nil
  end
end

local function scanstring (str, pos)
  local lastpos = pos + 1
  local buffer, n = {}, 0
  while true do
    local nextpos = strfind (str, "[\"\\]", lastpos)
    if not nextpos then
      return unterminated (str, "string", pos)
    end
    if nextpos > lastpos then
      n = n + 1
      buffer[n] = strsub (str, lastpos, nextpos - 1)
    end
    if strsub (str, nextpos, nextpos) == "\"" then
      lastpos = nextpos + 1
      break
    else
      local escchar = strsub (str, nextpos + 1, nextpos + 1)
      local value
      if escchar == "u" then
        value = tonumber (strsub (str, nextpos + 2, nextpos + 5), 16)
        if value then
          local value2
          if 0xD800 <= value and value <= 0xDBff then
            -- we have the high surrogate of UTF-16. Check if there is a
            -- low surrogate escaped nearby to combine them.
            if strsub (str, nextpos + 6, nextpos + 7) == "\\u" then
              value2 = tonumber (strsub (str, nextpos + 8, nextpos + 11), 16)
              if value2 and 0xDC00 <= value2 and value2 <= 0xDFFF then
                value = (value - 0xD800)  * 0x400 + (value2 - 0xDC00) + 0x10000
              else
                value2 = nil -- in case it was out of range for a low surrogate
              end
            end
          end
          value = value and unichar (value)
          if value then
            if value2 then
              lastpos = nextpos + 12
            else
              lastpos = nextpos + 6
            end
          end
        end
      end
      if not value then
        value = escapechars[escchar] or escchar
        lastpos = nextpos + 2
      end
      n = n + 1
      buffer[n] = value
    end
  end
  if n == 1 then
    return buffer[1], lastpos
  elseif n > 1 then
    return concat (buffer), lastpos
  else
    return "", lastpos
  end
end

local scanvalue -- forward declaration

local function scantable (what, closechar, str, startpos, nullval, objectmeta, arraymeta)
  local len = strlen (str)
  local tbl, n = {}, 0
  local pos = startpos + 1
  if what == 'object' then
    setmetatable (tbl, objectmeta)
  else
    setmetatable (tbl, arraymeta)
  end
  while true do
    pos = scanwhite (str, pos)
    if not pos then return unterminated (str, what, startpos) end
    local char = strsub (str, pos, pos)
    if char == closechar then
      return tbl, pos + 1
    end
    local val1, err
    val1, pos, err = scanvalue (str, pos, nullval, objectmeta, arraymeta)
    if err then return nil, pos, err end
    pos = scanwhite (str, pos)
    if not pos then return unterminated (str, what, startpos) end
    char = strsub (str, pos, pos)
    if char == ":" then
      if val1 == nil then
        return nil, pos, "cannot use nil as table index (at " .. loc (str, pos) .. ")"
      end
      pos = scanwhite (str, pos + 1)
      if not pos then return unterminated (str, what, startpos) end
      local val2
      val2, pos, err = scanvalue (str, pos, nullval, objectmeta, arraymeta)
      if err then return nil, pos, err end
      tbl[val1] = val2
      pos = scanwhite (str, pos)
      if not pos then return unterminated (str, what, startpos) end
      char = strsub (str, pos, pos)
    else
      n = n + 1
      tbl[n] = val1
    end
    if char == "," then
      pos = pos + 1
    end
  end
end

scanvalue = function (str, pos, nullval, objectmeta, arraymeta)
  pos = pos or 1
  pos = scanwhite (str, pos)
  if not pos then
    return nil, strlen (str) + 1, "no valid JSON value (reached the end)"
  end
  local char = strsub (str, pos, pos)
  if char == "{" then
    return scantable ('object', "}", str, pos, nullval, objectmeta, arraymeta)
  elseif char == "[" then
    return scantable ('array', "]", str, pos, nullval, objectmeta, arraymeta)
  elseif char == "\"" then
    return scanstring (str, pos)
  else
    local pstart, pend = strfind (str, "^%-?[%d%.]+[eE]?[%+%-]?%d*", pos)
    if pstart then
      local number = str2num (strsub (str, pstart, pend))
      if number then
        return number, pend + 1
      end
    end
    pstart, pend = strfind (str, "^%a%w*", pos)
    if pstart then
      local name = strsub (str, pstart, pend)
      if name == "true" then
        return true, pend + 1
      elseif name == "false" then
        return false, pend + 1
      elseif name == "null" then
        return nullval, pend + 1
      end
    end
    return nil, pos, "no valid JSON value at " .. loc (str, pos)
  end
end

local function optionalmetatables(...)
  if select("#", ...) > 0 then
    return ...
  else
    return {__jsontype = 'object'}, {__jsontype = 'array'}
  end
end

function json.decode (str, pos, nullval, ...)
  local objectmeta, arraymeta = optionalmetatables(...)
  return scanvalue (str, pos, nullval, objectmeta, arraymeta)
end

function json.use_lpeg ()
  local g = require ("lpeg")

  if g.version() == "0.11" then
    error "due to a bug in LPeg 0.11, it cannot be used for JSON matching"
  end

  local pegmatch = g.match
  local P, S, R = g.P, g.S, g.R

  local function ErrorCall (str, pos, msg, state)
    if not state.msg then
      state.msg = msg .. " at " .. loc (str, pos)
      state.pos = pos
    end
    return false
  end

  local function Err (msg)
    return g.Cmt (g.Cc (msg) * g.Carg (2), ErrorCall)
  end

  local SingleLineComment = P"//" * (1 - S"\n\r")^0
  local MultiLineComment = P"/*" * (1 - P"*/")^0 * P"*/"
  local Space = (S" \n\r\t" + P"\239\187\191" + SingleLineComment + MultiLineComment)^0

  local PlainChar = 1 - S"\"\\\n\r"
  local EscapeSequence = (P"\\" * g.C (S"\"\\/bfnrt" + Err "unsupported escape sequence")) / escapechars
  local HexDigit = R("09", "af", "AF")
  local function UTF16Surrogate (match, pos, high, low)
    high, low = tonumber (high, 16), tonumber (low, 16)
    if 0xD800 <= high and high <= 0xDBff and 0xDC00 <= low and low <= 0xDFFF then
      return true, unichar ((high - 0xD800)  * 0x400 + (low - 0xDC00) + 0x10000)
    else
      return false
    end
  end
  local function UTF16BMP (hex)
    return unichar (tonumber (hex, 16))
  end
  local U16Sequence = (P"\\u" * g.C (HexDigit * HexDigit * HexDigit * HexDigit))
  local UnicodeEscape = g.Cmt (U16Sequence * U16Sequence, UTF16Surrogate) + U16Sequence/UTF16BMP
  local Char = UnicodeEscape + EscapeSequence + PlainChar
  local String = P"\"" * g.Cs (Char ^ 0) * (P"\"" + Err "unterminated string")
  local Integer = P"-"^(-1) * (P"0" + (R"19" * R"09"^0))
  local Fractal = P"." * R"09"^0
  local Exponent = (S"eE") * (S"+-")^(-1) * R"09"^1
  local Number = (Integer * Fractal^(-1) * Exponent^(-1))/str2num
  local Constant = P"true" * g.Cc (true) + P"false" * g.Cc (false) + P"null" * g.Carg (1)
  local SimpleValue = Number + String + Constant
  local ArrayContent, ObjectContent

  -- The functions parsearray and parseobject parse only a single value/pair
  -- at a time and store them directly to avoid hitting the LPeg limits.
  local function parsearray (str, pos, nullval, state)
    local obj, cont
    local npos
    local t, nt = {}, 0
    repeat
      obj, cont, npos = pegmatch (ArrayContent, str, pos, nullval, state)
      if not npos then break end
      pos = npos
      nt = nt + 1
      t[nt] = obj
    until cont == 'last'
    return pos, setmetatable (t, state.arraymeta)
  end

  local function parseobject (str, pos, nullval, state)
    local obj, key, cont
    local npos
    local t = {}
    repeat
      key, obj, cont, npos = pegmatch (ObjectContent, str, pos, nullval, state)
      if not npos then break end
      pos = npos
      t[key] = obj
    until cont == 'last'
    return pos, setmetatable (t, state.objectmeta)
  end

  local Array = P"[" * g.Cmt (g.Carg(1) * g.Carg(2), parsearray) * Space * (P"]" + Err "']' expected")
  local Object = P"{" * g.Cmt (g.Carg(1) * g.Carg(2), parseobject) * Space * (P"}" + Err "'}' expected")
  local Value = Space * (Array + Object + SimpleValue)
  local ExpectedValue = Value + Space * Err "value expected"
  ArrayContent = Value * Space * (P"," * g.Cc'cont' + g.Cc'last') * g.Cp()
  local Pair = g.Cg (Space * String * Space * (P":" + Err "colon expected") * ExpectedValue)
  ObjectContent = Pair * Space * (P"," * g.Cc'cont' + g.Cc'last') * g.Cp()
  local DecodeValue = ExpectedValue * g.Cp ()

  function json.decode (str, pos, nullval, ...)
    local state = {}
    state.objectmeta, state.arraymeta = optionalmetatables(...)
    local obj, retpos = pegmatch (DecodeValue, str, pos, nullval, state)
    if state.msg then
      return nil, state.pos, state.msg
    else
      return obj, retpos
    end
  end

  -- use this function only once:
  json.use_lpeg = function () return json end

  json.using_lpeg = true

  return json -- so you can get the module using json = require "dkjson".use_lpeg()
end

if always_try_using_lpeg then
  pcall (json.use_lpeg)
end

return json


	end
	package.preload["BinDecHex"] = function( ... )
		local arg = _G.arg;
		_ENV = _ENV;

		--[[
/*
 * Copyright (c) 2007 Tim Kelly/Dialectronics
 *
 * Permission is hereby granted, free of charge, to any person obtaining 
 * a copy of this software and associated documentation files (the 
 * "Software"),  to deal in the Software without restriction, including 
 * without limitation the rights to use, copy, modify, merge, publish, 
 * distribute, sublicense, and/or sell copies of the Software, and to permit 
 * persons to whom the Software is furnished to do so, subject to the 
 * following conditions:
 *
 * The above copyright notice and this permission notice shall be 
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, 
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF 
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  
 * IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY 
 * CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT 
 * OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR 
 * THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

--]]

--[[
/*
 * Copyright (c) 2007 Tim Kelly/Dialectronics
 *
 * Permission is hereby granted, free of charge, to any person obtaining 
 * a copy of this software and associated documentation files (the 
 * "Software"),  to deal in the Software without restriction, including 
 * without limitation the rights to use, copy, modify, merge, publish, 
 * distribute, sublicense, and/or sell copies of the Software, and to permit 
 * persons to whom the Software is furnished to do so, subject to the 
 * following conditions:
 *
 * The above copyright notice and this permission notice shall be 
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, 
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF 
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  
 * IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY 
 * CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT 
 * OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR 
 * THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

/* Thanks to Bernard Clabots for string.gfind to make forward compatible to Lua 5.2 */

--]]

module(..., package.seeall);

string.gfind = string.gfind or string.gmatch

local hex2bin = {
	["0"] = "0000",
	["1"] = "0001",
	["2"] = "0010",
	["3"] = "0011",
	["4"] = "0100",
	["5"] = "0101",
	["6"] = "0110",
	["7"] = "0111",
	["8"] = "1000",
	["9"] = "1001",
	["a"] = "1010",
        ["b"] = "1011",
        ["c"] = "1100",
        ["d"] = "1101",
        ["e"] = "1110",
        ["f"] = "1111"
	}



local bin2hex = {
	["0000"] = "0",
	["0001"] = "1",
	["0010"] = "2",
	["0011"] = "3",
	["0100"] = "4",
	["0101"] = "5",
	["0110"] = "6",
	["0111"] = "7",
	["1000"] = "8",
	["1001"] = "9",
	["1010"] = "A",
        ["1011"] = "B",
        ["1100"] = "C",
        ["1101"] = "D",
        ["1110"] = "E",
        ["1111"] = "F"
	}

--[[
local dec2hex = {
	["0"] = "0",
	["1"] = "1",
	["2"] = "2",
	["3"] = "3",
	["4"] = "4",
	["5"] = "5",
	["6"] = "6",
	["7"] = "7",
	["8"] = "8",
	["9"] = "9",
	["10"] = "A",
	["11"] = "B",
	["12"] = "C",
	["13"] = "D",
	["14"] = "E",
	["15"] = "F"
	}
--]]


-- These functions are big-endian and take up to 32 bits

-- Hex2Bin
-- Bin2Hex
-- Hex2Dec
-- Dec2Hex
-- Bin2Dec
-- Dec2Bin


function Hex2Bin(s)

-- s	-> hexadecimal string

local ret = ""
local i = 0


	for i in string.gfind(s, ".") do
		i = string.lower(i)

		ret = ret..hex2bin[i]

	end

	return ret
end


function Bin2Hex(s)

-- s 	-> binary string

local l = 0
local h = ""
local b = ""
local rem

l = string.len(s)
rem = l % 4
l = l-1
h = ""

	-- need to prepend zeros to eliminate mod 4
	if (rem > 0) then
		s = string.rep("0", 4 - rem)..s
	end

	for i = 1, l, 4 do
		b = string.sub(s, i, i+3)
		h = h..bin2hex[b]
	end

	return h

end


function Bin2Dec(s)

-- s	-> binary string

local num = 0
local ex = string.len(s) - 1
local l = 0

	l = ex + 1
	for i = 1, l do
		b = string.sub(s, i, i)
		if b == "1" then
			num = num + 2^ex
		end
		ex = ex - 1
	end

	return string.format("%u", num)

end



function Dec2Bin(s, num)

-- s	-> Base10 string
-- num  -> string length to extend to

local n

	if (num == nil) then
		n = 0
	else
		n = num
	end

	s = string.format("%x", s)

	s = Hex2Bin(s)

	while string.len(s) < n do
		s = "0"..s
	end

	return s

end




function Hex2Dec(s)

-- s	-> hexadecimal string

local s = Hex2Bin(s)

	return Bin2Dec(s)

end



function Dec2Hex(s)

-- s	-> Base10 string

	s = string.format("%x", s)

	return s

end




-- These functions are big-endian and will extend to 32 bits

-- BMAnd
-- BMNAnd
-- BMOr
-- BMXOr
-- BMNot


function BMAnd(v, m)

-- v	-> hex string to be masked
-- m	-> hex string mask

-- s	-> hex string as masked

-- bv	-> binary string of v
-- bm	-> binary string mask

local bv = Hex2Bin(v)
local bm = Hex2Bin(m)

local i = 0
local s = ""

	while (string.len(bv) < 32) do
		bv = "0000"..bv
	end

	while (string.len(bm) < 32) do
		bm = "0000"..bm
	end


	for i = 1, 32 do
		cv = string.sub(bv, i, i)
		cm = string.sub(bm, i, i)
		if cv == cm then
			if cv == "1" then
				s = s.."1"
			else
				s = s.."0"
			end
		else
			s = s.."0"

		end
	end

	return Bin2Hex(s)

end


function BMNAnd(v, m)

-- v	-> hex string to be masked
-- m	-> hex string mask

-- s	-> hex string as masked

-- bv	-> binary string of v
-- bm	-> binary string mask

local bv = Hex2Bin(v)
local bm = Hex2Bin(m)

local i = 0
local s = ""

	while (string.len(bv) < 32) do
		bv = "0000"..bv
	end

	while (string.len(bm) < 32) do
		bm = "0000"..bm
	end


	for i = 1, 32 do
		cv = string.sub(bv, i, i)
		cm = string.sub(bm, i, i)
		if cv == cm then
			if cv == "1" then
				s = s.."0"
			else
				s = s.."1"
			end
		else
			s = s.."1"

		end
	end

	return Bin2Hex(s)

end



function BMOr(v, m)

-- v	-> hex string to be masked
-- m	-> hex string mask

-- s	-> hex string as masked

-- bv	-> binary string of v
-- bm	-> binary string mask

local bv = Hex2Bin(v)
local bm = Hex2Bin(m)

local i = 0
local s = ""

	while (string.len(bv) < 32) do
		bv = "0000"..bv
	end

	while (string.len(bm) < 32) do
		bm = "0000"..bm
	end


	for i = 1, 32 do
		cv = string.sub(bv, i, i)
		cm = string.sub(bm, i, i)
		if cv == "1" then
				s = s.."1"
		elseif cm == "1" then
				s = s.."1"
		else
			s = s.."0"
		end
	end

	return Bin2Hex(s)

end

function BMXOr(v, m)

-- v	-> hex string to be masked
-- m	-> hex string mask

-- s	-> hex string as masked

-- bv	-> binary string of v
-- bm	-> binary string mask

local bv = Hex2Bin(v)
local bm = Hex2Bin(m)

local i = 0
local s = ""

	while (string.len(bv) < 32) do
		bv = "0000"..bv
	end

	while (string.len(bm) < 32) do
		bm = "0000"..bm
	end


	for i = 1, 32 do
		cv = string.sub(bv, i, i)
		cm = string.sub(bm, i, i)
		if cv == "1" then
			if cm == "0" then
				s = s.."1"
			else
				s = s.."0"
			end
		elseif cm == "1" then
			if cv == "0" then
				s = s.."1"
			else
				s = s.."0"
			end
		else
			-- cv and cm == "0"
			s = s.."0"
		end
	end

	return Bin2Hex(s)

end


function BMNot(v, m)

-- v	-> hex string to be masked
-- m	-> hex string mask

-- s	-> hex string as masked

-- bv	-> binary string of v
-- bm	-> binary string mask

local bv = Hex2Bin(v)
local bm = Hex2Bin(m)

local i = 0
local s = ""

	while (string.len(bv) < 32) do
		bv = "0000"..bv
	end

	while (string.len(bm) < 32) do
		bm = "0000"..bm
	end


	for i = 1, 32 do
		cv = string.sub(bv, i, i)
		cm = string.sub(bm, i, i)
		if cm == "1" then
			if cv == "1" then
				-- turn off
				s = s.."0"
			else
				-- turn on
				s = s.."1"
			end
		else
			-- leave untouched
			s = s..cv

		end
	end

	return Bin2Hex(s)

end


-- these functions shift right and left, adding zeros to lost or gained bits
-- returned values are 32 bits long

-- BShRight(v, nb)
-- BShLeft(v, nb)


function BShRight(v, nb)

-- v	-> hexstring value to be shifted
-- nb	-> number of bits to shift to the right

-- s	-> binary string of v

local s = Hex2Bin(v)

	while (string.len(s) < 32) do
		s = "0000"..s
	end

	s = string.sub(s, 1, 32 - nb)

	while (string.len(s) < 32) do
		s = "0"..s
	end

	return Bin2Hex(s)

end

function BShLeft(v, nb)

-- v	-> hexstring value to be shifted
-- nb	-> number of bits to shift to the right

-- s	-> binary string of v

local s = Hex2Bin(v)

	while (string.len(s) < 32) do
		s = "0000"..s
	end

	s = string.sub(s, nb + 1, 32)

	while (string.len(s) < 32) do
		s = s.."0"
	end

	return Bin2Hex(s)

end

	end

end

local Ansible = require("ansible")
local File    = require("fileutils")
local Errno   = require("posix.errno")
local unistd  = require("posix.unistd")
local time    = require("posix.time")

local function get_state(path)
	-- Find the current state

	if File.lexists(path) then
		local stat = File.stat(path)
		if File.islnk(path) then
			return 'link'
		elseif File.isdir(path) then
			return 'directory'
		elseif stat ~= nil and stat['st_nlink'] > 1 then
			return 'hard'
		else
			-- could be many other things but defaulting to file
			return 'file'
		end
	end

	return 'absent'
end

local function append(t1, t2)
	for k,v in ipairs(t2) do
		t1[#t1 + 1] = v
	end
	return t1
end

local function deepcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[deepcopy(orig_key)] = deepcopy(orig_value)
        end
        setmetatable(copy, deepcopy(getmetatable(orig)))
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

local function recursive_set_attributes(module, path, follow, file_args)
	local changed = false
	local out = {}
	for _, entry in ipairs(File.walk(path, false)) do
		local root    = entry['root']
		local fsobjs  = append(entry['dirs'], entry['files'])

		for _, fsobj in ipairs(fsobjs) do
			fsname = File.join(root, {fsobj})
			out[#out + 1] = fsname

			if not File.islnk(fsname) then
				local tmp_file_args = deepcopy(file_args)
				tmp_file_args['path'] = fsname
				changed = changed or File.set_fs_attributes_if_different(module, tmp_file_args, changed, nil)
			else
				local tmp_file_args = deepcopy(file_args)
				tmp_file_args['path'] = fsname
				changed = changed or File.set_fs_attributes_if_different(module, tmp_file_args, changed, nil)
				if follow then
					fsname = File.join(root, {File.readlink(fsname)})
					if File.isdir(fsname) then
						changed = changed or recursive_set_attributes(module, fsname, follow, file_args)
					end
					tmp_file_args = deepcopy(file_args)
					tmp_file_args['path'] = fsname
					changed = changed or File.set_fs_attributes_if_different(module, tmp_file_args, changed, nil)
				end
			end
		end
	end

	return changed
end

local function strip(str, chars)
	str = string.gsub(str, string.format("^[%s]+", chars), "")
	str = string.gsub(str, string.format("[%s]+$", chars), "")
	return str
end

local function lstrip(str, chars)
	return string.gsub(str, string.format("^[%s]+", chars), "")
end

local function rstrip(str, chars)
	return string.gsub(str, string.format("[%s]+$", chars), "")
end

local function split(str, delimiter)
	local toks = {}

	for tok in string.gmatch(str, "[^".. delimiter .. "]+") do
		toks[#toks + 1] = tok
	end

	return toks
end

function main(arg)
	local module = Ansible.new(
		{ state = { choices={'file', 'directory', 'link', 'hard', 'touch', 'absent' } }
		, path = { aliases={'dest', 'name'}, required=true }
		, original_basename = { required=false }
		, recurse = { default=false, type='bool' }
		, force = { required=false, default=false, type='bool' }
		, diff_peek = {}
		, validate = { required=false }
		, src = {required=false}

		-- file common args
		-- , src = {}
		, mode = { type='raw' }
		, owner = {}
		, group = {}

		-- Selinux to ignore
		, seuser = {}
		, serole = {}
		, selevel = {}
		, setype = {}

		, follow = {type='bool', default=false}

		-- not taken by the file module, but other modules call file so it must ignore them
		, content = {}
		, backup = {}
		, force = {}
		, remote_src = {}
		, regexp = {}
		, delimiter = {}
		, directory_mode = {}
		}
	)

	module:parse(arg[1])

	-- FIXME: properly implement checkmode handling in module
	--        NB: This module is already capable of performing check_mode
	local checkmode = false

	local params = module:get_params()

	local state = params['state']
	local force = params['force']
	local diff_peek = params['diff_peek']
	local src = params['src']
	local follow = params['follow']

	-- modify source as we later reload and pass, specially relevant when used by other modules
	path = File.expanduser(params['path'])
	params['path'] = path

	-- short-circuit for diff_peek
	if nil ~= diff_peek then
		local appears_binary = false

		local f, err = io.open(path, "r")
		if f ~= nil then
			local content = f:read(8192)
			if Ansible.contains('\x00', content) then
				appears_binary = true
			end
		end

		module.exit_json({path=path, changed=False, msg="Dummy", appears_binary=appears_binary})
	end

	prev_state = get_state(path)

	-- state should default to file, but since that creates many conflicts
	-- default to 'current' when it exists
	if nil == state then
		if prev_state ~= 'absent' then
			state = prev_state
		else
			state = 'file'
		end
	end

	-- source is both the source of a symlink or an informational passing of the src for a template module
	-- or copy module, even if this module never uses it, it is needed to key off some things
	if src ~= nil then
		src = File.expanduser(src)
	else
		if 'link' == state or 'hard' == state then
			if follow and 'link' == state then
				-- use the current target of the link as the source
				src = File.realpath(path)
			else
				module:fail_json({msg='src and dest are required for creating links'})
			end
		end
	end

	-- original_basename is used by other modules that depend on file
	if File.isdir(path) and ("link" ~= state and "absent" ~= state) then
		local basename = nil
		if params['original_basename'] then
			basename = params['original_basename']
		elseif src ~= nil then
			basename = File.basename(src)
		end
		if basename then
			path = File.join(path, {basename})
			params['path'] = path
		end
	end

	-- make sure the target path is a directory when we're doing a recursive operation
	local recurse = params['recurse']
	if recurse and state ~= 'directory' then
		module:fail_json({path=path, msg="recurse option requires state to be directory"})
	end

	-- File args are inlined...
	local changed = false
	local diff = { before = {path=path}
	             , after  = {path=path}}

	local state_change = false
	if prev_state ~= state then
		diff['before']['state'] = prev_state
		diff['after']['state'] = state
		state_change = true
	end

	if state == 'absent' then
		if state_change then
			if not check_mode then
				if prev_state == 'directory' then
					local err = File.rmtree(path, {ignore_errors=false})
					if err then
						module:fail_json({msg="rmtree failed"})
					end
				else
					local status, errstr, errno = File.unlink(path)
					if not status then
						module:fail_json({path=path, msg="unlinking failed: " .. errstr})
					end
				end
			end
			module:exit_json({path=path, changed=true, msg="dummy", diff=diff})
		else
			module:exit_json({path=path, changed=false, msg="dummy"})
		end
	elseif state == 'file' then
		if state_change then
			if follow and prev_state == 'link' then
				-- follow symlink and operate on original
				path = File.realpath(path)
				prev_state = get_state(path)
				path['path'] = path
			end
		end

		if prev_state ~= 'file' and prev_state ~= 'hard' then
			-- file is not absent and any other state is a conflict
			module:fail_json({path = path, msg=string.format("file (%s) is %s, cannot continue", path, prev_state)})
		end

		changed = File.set_fs_attributes_if_different(module, params, changed, diff)
		module:exit_json({path=path, changed=changed, msg="dummy", diff=diff})
	elseif state == 'directory' then
		if follow and prev_state == 'link' then
			path = File.realpath(path)
			prev_state = get_state(path)
		end

		if prev_state == 'absent' then
			if module:check_mode() then
				module:exit_json({changed=true, msg="dummy", diff=diff})
			end
			changed = true
			local curpath = ''

			-- Split the path so we can apply filesystem attributes recursively
			-- from the root (/) directory for absolute paths or the base path
			-- of a relative path.  We can then walk the appropriate directory
			-- path to apply attributes.

			local segments = split(strip(path, '/'), '/')
			for _, dirname in ipairs(segments) do
				curpath = curpath .. '/' .. dirname
				-- remove lieading slash if we're creating a relative path
				if not File.isabs(path) then
					curpath = lstrip(curpath, "/")
				end
				if not File.exists(curpath) then
					local status, errstr, errno = File.mkdir(path)
					if not status then
						if not (errno == Errno.EEXIST and File.isdir(curpath)) then
							module:fail_json({path=path, msg="There was an issue creating " .. curpath .. " as requested: " .. errstr})
						end
					end
					tmp_file_args = deepcopy(params)
					tmp_file_args['path'] = curpath
					changed = File.set_fs_attributes_if_different(module, params, changed, diff)
				end
			end
		elseif prev_state ~= 'directory' then
			module:fail_json({path=path, msg=path .. "already exists as a " .. prev_state})
		end

		changed = File.set_fs_attributes_if_different(module, params, changed, diff)

		if recurse then
			changed = changed or recursive_set_attributes(module, params['path'], follow, params)
		end

		module:exit_json({path=path, changed=changed, diff=diff, msg="Dummy"})

	elseif state == 'link' or state == 'hard' then
		local relpath
		if File.isdir(path) and not File.islnk(path) then
			relpath = path
		else
			relpath = File.dirname(path)
		end

		local absrc = File.join(relpath, {src})
		if not File.exists(absrc) and not force then
			module:fail_json({path=path, src=src, msg='src file does not exist, use "force=yes" if you really want to create the link ' .. absrc})
		end

		if state == 'hard' then
			if not File.isabs(src) then
				module:fail_json({msg="absolute paths are required"})
			end
		elseif pref_state == 'directory' then
			if not force then
				module:fail_json({path=path, msg="refusing to convert between " .. prev_state .. " and " .. state .. " for " .. path})
			else
				local lsdir = File.listdir(path)
				if lsdir and #lsdir > 0 then
					-- refuse to replace a directory that has files in it
					module:fail_json({path=path, msg="the directory " .. path .. " is not empty, refusing to convert it"})
				end
			end
		elseif (prev_state == "file" or prev_state == "hard") and not force then
			module:fail_json({path=path, msg="refusing to convert between " .. prev_state .. " and " .. state .. " for " .. path})
		end

		if prev_state == 'absent' then
			changed = true
		elseif prev_state == 'link' then
			local old_src = File.readlink(path)
			if old_src ~= src then
				changed = true
			end
		elseif prev_state == 'hard' then
			if not (state == 'hard' and File.stat(path)['st_ino'] == File.stat(src)['st_ino']) then
				changed = true
				if not force then
					module:fail_json({dest=path, src=src, msg='Cannot link, different hard link exists at destination'})
				end
			end
		elseif prev_state == 'file' or prev_state == 'directory' then
			changed = true
			if not force then
				module:fail_json({dest=path, src=src, msg='Cannot link, ' .. prev_state .. ' exists at destination'})
			end
		else
			module:fail_json({dest=path, src=src, msg='unexpected position reached'})
		end

		if changed and not module:check_mode() then
			if prev_state ~= absent then
				-- try to replace automically
				local tmppath = string.format("%s/.%d.%d.tmp", File.dirname(path), unistd.getpid(), time.time())

				local status, errstr, errno
				if prev_state == 'directory' and (state == 'hard' or state == 'link')then
					status, errstr, errno = File.rmdir(path)
				end
				if state == 'hard' then
					status, errstr, errno = File.link(src, tmppath)
				else
					status, errstr, errno = File.symlink(src, tmppath)
				end
				if status then
					status, errstr, errno = File.rename(tmppath, path)
				end
				if not status then
					if File.exists(tmppath) then
						File.unlink(tmppath)
					end
					module:fail_json({path=path, msg='Error while replacing ' .. errstr})
				end
			else
				local status, errstr, errno
				if state == 'hard' then
					status, errstr, errno = File.link(src, path)
				else
					status, errstr, errno = File.symlink(src, path)
				end
				if not status then
					module:fail_json({path=path, msg='Error while linking: ' .. errstr})
				end
			end
		end

		if module:check_mode() and not File.exists(path) then
			module:exit_json({dest=path, src=src, msg="dummy", changed=changed, diff=diff})
		end

		changed = File.set_fs_attributes_if_different(module, params, changed, diff)
		module:exit_json({dest=path, src=src, msg="dummy", changed=changed, diff=diff})

	elseif state == 'touch' then
		if not module:check_mode() then
			local status, errmsg
			if prev_state == 'absent' then
				status, errmsg = File.touch(path)
				if not status then
					module:fail_json({path=path, msg='Error, could not touch target: ' .. errmsg})
				end
			elseif prev_state == 'file' or prev_state == 'directory' or prev_state == 'hard' then
				status, errmsg = File.utime(path)
				if not status then
					module:fail_json({path=path, msg='Error while touching existing target: ' .. errmsg})
				end
			else
				module:fail_json({msg='Cannot touch other than files, directories, and hardlinks (' .. path .. " is " .. prev_state .. ")"})
			end

			-- FIXME: SORRY, we can't replicate the catching of SystemExit as far as I know...
			--        so we _may_ leak a file
			File.set_fs_attributes_if_different(module, params, true, diff)
		end

		module:exit_json({dest=path, changed=true, diff=diff, msg="dummy"})
	end

	module.fail_json({path=path, msg='unexpected position reached'})
end

main(arg)
