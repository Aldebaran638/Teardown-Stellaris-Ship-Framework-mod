#version 2
#include "script/include/common.lua"

function server.init()
    server.tmp1=1
end

function client.init()
    client.tmp2=2
end

function client.tick(dt)
    DebugWatch("client1",111111111111111)

    DebugWatch("client",client.tmp2)

end

function client.draw()
end

function server.tick(dt)
    DebugWatch("server",server.tmp1)
end