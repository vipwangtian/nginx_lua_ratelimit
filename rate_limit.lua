local m_redis = require "resty.redis"

local _M = {}

_M._VERSION = "0.1"
local mt = { __index = _M }
-- redis连接超时时间
local redis_timeout = 100
-- redis连接池超时时间
local redis_pool_timeout = 3600000
-- redis连接池大小
local redis_pool_size = 10

--[[ 
    这里删除掉了lua中所有的空行与注释，因为codis不支持evalhash，
    所以这个脚本每次执行都要作为一个字符串发送到服务器执行，能省一点是一点
]]
local eval_script = [[
    local key, intervalPerPermit, refillTime, burstTokens = KEYS[1], tonumber(ARGV[1]), tonumber(ARGV[2]), tonumber(ARGV[3])
    local limit, interval = tonumber(ARGV[4]), tonumber(ARGV[5])
    local bucket = redis.call('hgetall', key)
    local currentTokens
    if table.maxn(bucket) == 0 then
        currentTokens = burstTokens
        redis.call('hset', key, 'lastRefillTime', refillTime)
    elseif table.maxn(bucket) == 4 then
        local lastRefillTime, tokensRemaining = tonumber(bucket[2]), tonumber(bucket[4])
        if refillTime > lastRefillTime then
            local intervalSinceLast = refillTime - lastRefillTime
            if intervalSinceLast > interval then
                currentTokens = math.max(burstTokens, limit)
                redis.call('hset', key, 'lastRefillTime', refillTime)
            else
                local grantedTokens = math.floor(intervalSinceLast / intervalPerPermit)
                if grantedTokens > 0 then
                    local padMillis = math.fmod(intervalSinceLast, intervalPerPermit)
                    redis.call('hset', key, 'lastRefillTime', refillTime - padMillis)
                end
                currentTokens = math.min(grantedTokens + tokensRemaining, limit)
            end
        else
            currentTokens = tokensRemaining
        end
    end
    if currentTokens == 0 then
        redis.call('hset', key, 'tokensRemaining', currentTokens)
        return 0
    else
        redis.call('hset', key, 'tokensRemaining', currentTokens - 1)
        return 1
    end
]]

--[[
    构造函数，初始化redis连接，这里db尽量用0，能少执行一个命令是一个
]]
function _M.new(self, redis_host, redis_port, db)
    local redis, err = m_redis:new()
    if err then
        return nil, err
    end
    redis:set_timeout(redis_timeout)
    local ok, err = redis:connect(redis_host, redis_port)
    if err then
        return nil, err
    end
    ok, err = redis:select(db)
    if err then
        return nil, err
    end

    return setmetatable({ _redis = redis }, mt)
end

--[[
    key:令牌桶在redis中的key
    burstTokens:瞬时最大通过量，瞬时最大通过量应该大于limit/interval，否则没什么意义
    limit:令牌桶大小
    interval:令牌桶的限速间隔，单位是秒
]]
function _M.access(self, key, burstTokens, limit, interval)
    local redis = rawget(self, "_redis")
    local refillTime = os.time()
    local intervalPerPermit = interval / limit
    local ret, err = redis:eval(eval_script, 1, key, refillTime, burstTokens, limit, interval)
    redis:setkeepalive(redis_pool_timeout, redis_pool_size)
    return ret, err
end

return _M