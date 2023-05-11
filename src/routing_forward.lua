local http = require ("resty.http")
local resp = require ("ngx.resp")
local redis = require ("resty.redis")
local cjson= require("cjson")
local ERROR_CODE = { miss_param = 1000, server_error=1001, service_loss=1003, service_Pending=1004,  unknown_error=1005}
local SERVER_STATUS = {Running = "Running", Pending = "Pending"}
local CONFIG = {RequestForwardServerParamName = "ServerID", RedisHost="127.0.0.1", RedisPort=6379,}

--错误信息返回
local function WriteErrorMessage (code, msg)
    local result = {code = code, msg = "routing_forward:{"..msg.."}", data = {}}
    ngx.say(cjson.encode(result))
end

local function split(str,delimiter)
    local dLen = string.len(delimiter)
    local newDeli = ''
    for i=1,dLen,1 do
        newDeli = newDeli .. "["..string.sub(delimiter,i,i).."]"
    end

    local locaStart,locaEnd = string.find(str,newDeli)
    local arr = {}
    local n = 1
    while locaStart ~= nil
    do
        if locaStart>0 then
            arr[n] = string.sub(str,1,locaStart-1)
            n = n + 1
        end

        str = string.sub(str,locaEnd+1,string.len(str))
        locaStart,locaEnd = string.find(str,newDeli)
    end
    if str ~= nil then
        arr[n] = str
    end
    return arr
end

-- 代理转发
local function proxy_func(proxy_url)

    local client = http.new()
    if not client then
        ngx.log(ngx.ERROR, "proxy_func client is nil")
    end
    client:set_timeout(30 * 1000)

    local request_header = ngx.req.get_headers()
    local request_method = ngx.req.get_method()
    ngx.req.read_body()
    local request_body = ngx.req.get_body_data() -- 当请求body大于 client_body_buffer_size 默认值8k或16k时，请求报文将会被nginx缓存到硬盘，此时 ngx.req.get_body_data() 无法获取到body正文。请修改nginx client_body_buffer_size 128k，或者更大。！！！典型案例：如果是转发multipart/form-data类型，不去修改大小，就会转发失败

    ngx.log(ngx.DEBUG, "request_url ", proxy_url)
    ngx.log(ngx.DEBUG, "request_method ", request_method)
    ngx.log(ngx.DEBUG, "request_header ", cjson.encode(request_header))
    ngx.log(ngx.DEBUG, "request_body ", request_body)

    local ok, err = client:request_uri(
                            proxy_url,
                            {
                                method = request_method,
                                headers = request_header,
                                body = request_body,
                                ssl_verify = false -- 验证SSL证书是否与主机名匹配
                            }
                    )

        ngx.log(ngx.DEBUG, "proxy response", ok)
       if not ok then -- 检查请求是否成功
           WriteErrorMessage(ERROR_CODE.server_error, "failed to request: url="..proxy_url)
           ngx.log(ngx.DEBUG, "failed to request, proxy_url=".. proxy_url..",err=".. err)
           return
       end

       local response_body = ok.body
       local response_headers = ok.headers
       local response_status = ok.status

       ngx.log(ngx.DEBUG, "response_status ", cjson.encode(response_status))
       ngx.log(ngx.DEBUG, "response_headers ", cjson.encode(response_headers))
       ngx.log(ngx.DEBUG, "response_body ", cjson.encode(response_body))
       return response_status, response_headers, response_body
end

-- 输入响应内容，ngx.exit退出
local function response_func(resp_status, resp_headers, resp_body)
    ngx.status = resp_status
    --ngx.header = resp_headers
    for v, m in pairs(resp_headers) do
        resp.add_header(v, m)
    end
    ngx.say(resp_body)
end

--主函数
local function main_func()
    local request_method = ngx.var.request_method
    local args = nil

    if "GET" == request_method then
        args = ngx.req.get_uri_args()
    elseif "POST" == request_method then
        ngx.req.read_body()
        args = ngx.req.get_post_args()
        --兼容请求使用post请求，但是传参以get方式传造成的无法获取到数据的bug
        if (args == nil or args.data == null) then
            args = ngx.req.get_uri_args()
        end
    end

    local serverID = args[CONFIG.RequestForwardServerParamName]
    if (serverID == nil or serverID == '') then
        -- 参数缺失
        WriteErrorMessage(ERROR_CODE.miss_param, "required parameter ServerId")
        return
    end

    -- 进行初始化
    local redisOb = redis:new({
        connect_timeout = 50,
        read_timeout = 5000,
        keepalive_timeout = 30000,
    })

    local ok , err = redisOb:connect(CONFIG.RedisHost, CONFIG.RedisPort)

    if not ok then
        -- 连接失败
        WriteErrorMessage(ERROR_CODE.server_error, "failed to connect")
        return
    end

    --读取路由服务器配置
    local res, err = redisOb:hget("routing_forward_bucket_1",serverID)

    if type(res) == 'userdata' or res == nil then
        WriteErrorMessage(ERROR_CODE.service_loss, "service loss ServerId=" .. serverID)
        return
    end

    --解析服务地址
    local serverAddr = split(res,"/")
    local forwardAddr = serverAddr[1]
    local serverStatus = serverAddr[2]

    if serverStatus == SERVER_STATUS.Pending then
        WriteErrorMessage(ERROR_CODE.service_Pending, "service Pending ServerId=" .. serverID)
        return
    end

    --服务运行正常，进行路由转发
    if serverStatus == SERVER_STATUS.Running then
        local request_url = ngx.var.request_uri
        proxy_func("http://".. forwardAddr..request_url)
        local resp_status, resp_headers, resp_body = proxy_func("http://".. forwardAddr..request_url)
        response_func(resp_status, resp_headers, resp_body)
        return
    end

    WriteErrorMessage(ERROR_CODE.unknown_error, "unknown operation")
end

-- 执行入口......
main_func()





