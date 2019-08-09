local resolver = require("resty.dns.resolver")
local lrucache = require("resty.lrucache")
local resolv_conf = require("util.resolv_conf")

local _M = {}
local CACHE_SIZE = 10000
local MAXIMUM_TTL_VALUE = 2147483647 -- maximum value according to https://tools.ietf.org/html/rfc2181

local cache, err = lrucache.new(CACHE_SIZE)
if not cache then
  return error("failed to create the cache: " .. (err or "unknown"))
end

local function is_fully_qualified(host)
  return host:sub(-1) == "."
end

local function a_records_and_max_ttl(answers)
  local addresses = {}
  local ttl = MAXIMUM_TTL_VALUE -- maximum value according to https://tools.ietf.org/html/rfc2181

  for _, ans in ipairs(answers) do
    if ans.address then
      table.insert(addresses, ans.address)
      if ttl > ans.ttl then
        ttl = ans.ttl
      end
    end
  end

  return addresses, ttl
end

local function resolve_host_for_qtype(r, host, qtype)
  local answers
  answers, err = r:query(host, { qtype = qtype }, {})
  if not answers then
    return nil, -1, string.format("error while resolving %s: %s", host, err)
  end

  if answers.errcode then
    return nil, -1, string.format("server returned error code when resolving %s: %s: %s", host, answers.errcode, answers.errstr)
  end

  local addresses, ttl = a_records_and_max_ttl(answers)
  if #addresses == 0 then
    return nil, -1, "no record resolved"
  end

  return addresses, ttl, nil
end

local function resolve_host(r, host)
  local dns_errors = {}

  local addresses, ttl
  addresses, ttl, err = resolve_host_for_qtype(r, host, r.TYPE_A)
  if not addresses then
    table.insert(dns_errors, tostring(err))
  elseif #addresses > 0 then
    return addresses, ttl, nil
  end

  addresses, ttl, err = resolve_host_for_qtype(r, host, r.TYPE_AAAA)
  if not addresses then
    table.insert(dns_errors, tostring(err))
  elseif #addresses > 0 then
    return addresses, ttl, nil
  end

  return nil, nil, dns_errors
end

function _M.resolve(host)
  local cached_addresses = cache:get(host)
  if cached_addresses then
    local message = string.format(
      "addresses %s for host %s was resolved from cache",
      table.concat(cached_addresses, ", "), host)
    ngx.log(ngx.INFO, message)
    return cached_addresses
  end

  local r
  r, err = resolver:new{
    nameservers = resolv_conf.nameservers,
    retrans = 5,
    timeout = 2000,  -- 2 sec
  }

  if not r then
    ngx.log(ngx.ERR, "failed to instantiate the resolver: " .. tostring(err))
    return { host }
  end

  local addresses, tll, dns_errors = nil, nil, {}

  -- when the queried is a fully qualified domain
  -- then we don't go through resolv_conf.search
  if is_fully_qualified(host) then
    addresses, tll, dns_errors = resolve_host(r, host)
    if addresses then
      cache:set(host, addresses, ttl)
      return addresses
    end

    ngx.log(ngx.ERR, "failed to query the DNS server:\n" .. table.concat(dns_errors, "\n"))

    return { host }
  end

  -- for non fully qualified domains if number of dots in
  -- the queried hos is less than resolv_conf.ndots then we try
  -- with all the entries in resolv_conf.search before trying the original host
  --
  -- if number of dots is not less than resolv_conf.ndots then we start with
  -- the original host and then try entries in resolv_conf.search
  local _, host_ndots = host:gsub("%.", "")
  local search_start, search_end = 0, #resolv_conf.search
  if host_ndots < resolv_conf.ndots then
    search_start = 1
    search_end = #resolv_conf.search + 1
  end

  for i = search_start,search_end,1 do
    local new_host = resolv_conf.search[i] and host.."."..resolv_conf.search[i] or host
    ngx.log(ngx.WARN, "[XIYAR] host: " .. new_host)

    addresses, tll, dns_errors = resolve_host(r, new_host)
    if addresses then
      cache:set(host, addresses, ttl)
      return addresses
    end
  end

  if #dns_errors > 0 then
    ngx.log(ngx.ERR, "failed to query the DNS server:\n" .. table.concat(dns_errors, "\n"))
  end

  return { host }
end

return _M
