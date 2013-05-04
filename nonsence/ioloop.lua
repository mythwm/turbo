--[[ Nonsence IO Loop module

Copyright 2011, 2012, 2013 John Abrahamsen

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.		]]

local log = require "log"
local util = require "util"
local signal = require "signal"
require "middleclass"
require "nwglobals"
local NGC = _G.NW_GLOBAL_COUNTER

local ioloop = {} -- ioloop namespace

local _poll_implementation = nil
  
if pcall(require, 'epoll_ffi') then
	-- Epoll FFI module found and loaded.
	log.success([[[ioloop.lua] Picked epoll_ffi module as poll module.]])
	_poll_implementation = 'epoll_ffi'
	epoll_ffi = require('epoll_ffi')
	-- Populate global with Epoll module constants
	ioloop.READ = epoll_ffi.EPOLL_EVENTS.EPOLLIN
	ioloop.WRITE = epoll_ffi.EPOLL_EVENTS.EPOLLOUT
	ioloop.PRI = epoll_ffi.EPOLL_EVENTS.EPOLLPRI
	ioloop.ERROR = epoll_ffi.EPOLL_EVENTS.EPOLLERR
else
	-- No poll modules found. Break execution and give error.
	error([[Could not load a poll module. Make sure you are running this with LuaJIT. Standard Lua is not supported.]])
end


function ioloop.instance()
	if _G.io_loop_instance then
		return _G.io_loop_instance
	else
		_G.io_loop_instance = ioloop.IOLoop:new()
		return _G.io_loop_instance
	end
end

ioloop.IOLoop = class('IOLoop')
function ioloop.IOLoop:init()	
	self._handlers = {}
	self._timeouts = {}
        self._intervals = {}
	self._callbacks = {}
	self._running = false
	self._stopped = false
	if _poll_implementation == 'epoll_ffi' then
		self._poll = _EPoll_FFI:new()
	end
        
        signal.signal(signal.SIGPIPE, signal.SIG_IGN)
end

function ioloop.IOLoop:add_handler(file_descriptor, events, handler)
	self._handlers[file_descriptor] = handler
	self._poll:register(file_descriptor, events)
        if _G.CONSOLE then
            NGC.ioloop_add_handler_count = NGC.ioloop_add_handler_count + 1
            NGC.ioloop_fd_count = NGC.ioloop_fd_count + 1
        end
end

function ioloop.IOLoop:update_handler(file_descriptor, events)
        if _G.CONSOLE then
            NGC.ioloop_update_handler_count = NGC.ioloop_update_handler_count + 1
        end
	self._poll:modify(file_descriptor, events)
end

function ioloop.IOLoop:remove_handler(file_descriptor)	
    if self._handlers[file_descriptor] then 
        self._handlers[file_descriptor] = nil
        self._poll:unregister(file_descriptor)
        if _G.CONSOLE then
            NGC.ioloop_fd_count = NGC.ioloop_fd_count - 1
        end
    end
end


function ioloop.IOLoop:_run_handler(file_descriptor, events)   
    xpcall(self._handlers[file_descriptor], function(err)
                log.error("[ioloop.lua] caught error in handler: " .. err)
                self:remove_handler(file_descriptor)
                if _G.CONSOLE then
                    NGC.ioloop_handlers_errors_count = NGC.ioloop_handlers_errors_count + 1
                end
            end, file_descriptor, events)
    
    if _G.CONSOLE then
        NGC.ioloop_handlers_called = NGC.ioloop_handlers_called + 1
    end
end

function ioloop.IOLoop:running() return self._running end
function ioloop.IOLoop:add_callback(callback) self._callbacks[#self._callbacks + 1] = callback end
function ioloop.IOLoop:list_callbacks() return self._callbacks end

local function error_handler(err)
    log.error("[ioloop.lua] caught error in callback: " .. err)
    log.stacktrace(debug.traceback())
    if _G.CONSOLE then
        NGC.ioloop_callbacks_error_count = NGC.ioloop_callbacks_error_count + 1
    end
end

function ioloop.IOLoop:_run_callback(callback)
    xpcall(callback, error_handler)
    if _G.CONSOLE then
        NGC.ioloop_callbacks_run = NGC.ioloop_callbacks_run + 1
    end
end


function ioloop.IOLoop:add_timeout(timestamp, callback)
    local i = 1
    while(true) do
        if (self._timeouts[i] == nil) then
            break
        else
            i = i + 1
        end
    end

    self._timeouts[i] = _Timeout:new(timestamp, callback)
    
    if _G.CONSOLE then
        NGC.ioloop_timeout_count = NGC.ioloop_timeout_count + 1
    end
    return i
end

function ioloop.IOLoop:remove_timeout(ref)	
    if self._timeouts[ref] then
            self._timeouts[ref] = nil
            if _G.CONSOLE then
                NGC.ioloop_timeout_count = NGC.ioloop_timeout_count - 1
            end
            return true        
    else
            return false
    end
end

function ioloop.IOLoop:set_interval(msec, callback)
    local i = 1
    while(true) do
        if (self._intervals[i] == nil) then
            break
        else
            i = i + 1
        end
    end

    self._intervals[i] = _Interval:new(msec, callback)
    if _G.CONSOLE then
        NGC.ioloop_interval_count = NGC.ioloop_interval_count + 1
    end    
    return i   
end

function ioloop.IOLoop:clear_interval(ref)
    if (self._intervals[ref]) then
        self._intervals[ref] = nil
        if _G.CONSOLE then
            NGC.ioloop_interval_count = NGC.ioloop_interval_count - 1
        end    
        return true
    else
        return false
    end
end

function ioloop.IOLoop:_start_console_server()
    local console = require "nwconsoleserver"   
    
    local console_server = console.ConsoleServer:new(self)
    console_server:listen(27000, 0x0)    
end

function ioloop.IOLoop:start()	
    self._running = true
    if _G.CONSOLE then
        self:_start_console_server()
    end
    while true do
            local poll_timeout = 3600
            local callbacks = self._callbacks
            local time_now = nil
            if _G.CONSOLE then
                NGC.ioloop_iteration_count = NGC.ioloop_iteration_count + 1
                NGC.ioloop_callbacks_queue = #callbacks
            end    
            self._callbacks = {}

            if #self._timeouts > 0 then
                    for _, timeout in ipairs(self._timeouts) do
                            if timeout:timed_out() then
                                    self:_run_callback( timeout:callback() )
                                    timeout = nil                                        
                            end
                    end
            end
            
            
            if (#self._intervals > 0) then
                if (time_now == nil) then
                    time_now = util.gettimeofday()
                end
                for _, interval in ipairs(self._intervals) do
                    local timed_out = interval:timed_out(time_now)
                    if (timed_out == 0) then
                        self:_run_callback(interval.callback)
                        time_now = util.gettimeofday()
                        local next_call = interval:set_last_call(time_now)
                        if (next_call < poll_timeout) then
                            poll_timeout = next_call
                        end
                    else
                        if (timed_out < poll_timeout) then
                            poll_timeout = timed_out
                        end
                    end
                end
            end
            
            
            for i=1, #callbacks, 1 do 
                    self:_run_callback(callbacks[i])
            end
            
            if #self._callbacks > 0 then
                    poll_timeout = 0
            end
            
            
            if self._stopped then 
                    self.running = false
                    self.stopped = false
                    break
            end
            
            local events = self._poll:poll(poll_timeout)
            for i=1, #events do
                    self:_run_handler(events[i][1], events[i][2])
            end
            
    end
end

function ioloop.IOLoop:close()
	self._running = false
	self._stopped = true
	self._callbacks = {}
	self._handlers = {}
end

_Interval = class("_Interval")
function _Interval:init(msec, callback)
    self.interval_msec = msec
    self.callback = callback
    self.next_call = util.gettimeofday() + self.interval_msec
end

function _Interval:timed_out(time_now)
    if (time_now >= self.next_call) then
        return 0
    else
        return self.next_call - time_now
    end
end

function _Interval:set_last_call(time_now)
    self.last_interval = time_now
    self.next_call = time_now + self.interval_msec
    return self.next_call - time_now
end


_Timeout = class('_Timeout')
function _Timeout:init(timestamp, callback)
	self._timestamp = timestamp or error('No timestamp given to _Timeout class')
	self._callback = callback or error('No callback given to _Timeout class')
end

function _Timeout:timed_out()
	return ( time.now() - self._timestamp < 0 )
end

function _Timeout:callback()
	return self._callback
end




_EPoll_FFI = class('_EPoll_FFI')

-- Internal class for epoll-based event loop using the epoll_ffi module.
function _EPoll_FFI:init()
	self._epoll_fd = epoll_ffi.epoll_create() -- New epoll, store its fd.
end

function _EPoll_FFI:fileno()
	return self._epoll_fd
end

function _EPoll_FFI:register(file_descriptor, events)
	epoll_ffi.epoll_ctl(self._epoll_fd, epoll_ffi.EPOLL_CTL_ADD, 
		file_descriptor, events)
end

function _EPoll_FFI:modify(file_descriptor, events)
	epoll_ffi.epoll_ctl(self._epoll_fd, epoll_ffi.EPOLL_CTL_MOD, 
		file_descriptor, events)
end

function _EPoll_FFI:unregister(file_descriptor)
	epoll_ffi.epoll_ctl(self._epoll_fd, epoll_ffi.EPOLL_CTL_DEL, 
		file_descriptor, 0)	
end

function _EPoll_FFI:poll(timeout)
	return epoll_ffi.epoll_wait(self._epoll_fd, timeout)
end

return ioloop

