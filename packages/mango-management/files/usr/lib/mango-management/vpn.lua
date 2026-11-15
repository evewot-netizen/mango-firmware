-- Read fastd status using the same peer.connection.established field as Gluon.
-- Caller enforces a five-second timeout, including connect/read operations.
local ok, connected = pcall(function()
    local socket = require('posix.sys.socket')
    local unistd = require('posix.unistd')
    local json = require('jsonc')
    local fd = assert(socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, 0))
    local success, result = pcall(function()
        assert(socket.connect(fd, {family=socket.AF_UNIX, path='/var/run/fastd.mesh_vpn.socket'}))
        local chunks, size = {}, 0
        while true do
            local chunk = assert(unistd.read(fd, 4096))
            if #chunk == 0 then break end
            size = size + #chunk
            assert(size <= 1048576, 'oversize status')
            chunks[#chunks+1] = chunk
        end
        local status = assert(json.parse(table.concat(chunks)))
        for _, peer in pairs(status.peers or {}) do
            if type(peer.connection) == 'table' and peer.connection.established ~= nil then
                return true
            end
        end
        return false
    end)
    unistd.close(fd)
    assert(success, result)
    return result
end)
if not ok then
    print('Unbekannt')
    os.exit(1)
end
print(connected and 'Verbunden' or 'Getrennt')
