local resty_global_throttle = require("resty.global_throttle")
local util = require("util")

local ngx = ngx
local ngx_exit = ngx.exit
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_INFO = ngx.INFO
local ngx_HTTP_TOO_MANY_REQUESTS = ngx.HTTP_TOO_MANY_REQUESTS

local _M = {}

local DECISION_CACHE = ngx.shared.global_throttle_cache

-- it does not make sense to cache decision for too little time
-- the benefit of caching likely is negated if we cache for too little time
-- Lua Shared Dict's time resolution for expiry is 0.001.
local CACHE_THRESHOLD = 0.001

local DEFAULT_RAW_KEY = "remote_addr"

local function is_enabled(config, location_config)
  if config.memcached.host == "" or config.memcached.port == 0 then
    return false
  end
  if location_config.global_throttle.limit == 0 or
    location_config.global_throttle.window_size == 0 then
    return false
  end
  return true
end

local function get_namespaced_key_value(namespace, key_value)
  return namespace .. key_value
end

function _M.throttle(config, location_config)
  if not is_enabled(config, location_config) then
    return
  end

  local key_value = util.generate_var_value(location_config.global_throttle.key)
  if not key_value or key_value == "" then
    key_value = ngx.var[DEFAULT_RAW_KEY]
  end

  local namespaced_key_value =
    get_namespaced_key_value(location_config.global_throttle.namespace, key_value)

  local is_limit_exceeding = DECISION_CACHE:get(namespaced_key_value)
  if is_limit_exceeding then
    ngx.var.global_rate_limit_exceeding = "c"
    return ngx_exit(ngx_HTTP_TOO_MANY_REQUESTS)
  end

  local my_throttle, err = resty_global_throttle.new(
    location_config.global_throttle.namespace,
    location_config.global_throttle.limit,
    location_config.global_throttle.window_size,
    {
      provider = "memcached",
      host = config.memcached.host,
      port = config.memcached.port,
      connect_timeout = config.memcached.connect_timeout,
      max_idle_timeout = config.memcached.max_idle_timeout,
      pool_size = config.memcached.pool_size,
    }
  )
  if err then
    ngx.log(ngx.ERR, "faled to initialize resty_global_throttle: ", err)
    -- fail open
    return
  end

  local desired_delay, estimated_final_count
  estimated_final_count, desired_delay, err = my_throttle:process(key_value)
  if err then
    ngx.log(ngx.ERR, "error while processing key: ", err)
    -- fail open
    return
  end

  if desired_delay then
    if desired_delay > CACHE_THRESHOLD then
      local ok
      ok, err =
        DECISION_CACHE:safe_add(namespaced_key_value, true, desired_delay)
      if not ok then
        if err ~= "exists" then
          ngx_log(ngx_ERR, "failed to cache decision: ", err)
        end
      end
    end

    ngx.var.global_rate_limit_exceeding = "y"
    ngx_log(ngx_INFO, "limit is exceeding for ",
      location_config.global_throttle.namespace, "/", key_value,
      " with estimated_final_count: ", estimated_final_count)

    return ngx_exit(ngx_HTTP_TOO_MANY_REQUESTS)
  end
end

return _M
