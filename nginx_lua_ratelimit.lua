local m_rate_limit = require "rate_limit"

local key = "your bucket key"
local burstTokens = 10
local limit = 6
local interval = 60

local redis_host = "your redis host"
local redis_port = "your redis port"
local redis_db = "your db number"

local rate_limit, err = m_rate_limit:new(redis_host, redis_port, redis_db)
if err then
  return
end
local ret, err = rate_limit:access(key, burstTokens, limit, interval)

-- 仅当返回无令牌时拒绝访问
if ret and ret == 0 then
  ngx.exit(403)
end