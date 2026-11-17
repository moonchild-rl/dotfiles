-- VLC 3.x interface: one active file, on-demand directory navigation.
-- Started by vlc-lazy, alongside VLC's ordinary Qt window.
local state = os.getenv('VLC_LAZY_STATE')
local token = os.getenv('VLC_LAZY_TOKEN')
if not state or not token then
    vlc.msg.err('Start this interface with the vlc-lazy launcher')
    return
end

local extensions = {}
for ext in ('mp4 mkv webm avi mov m4v mpg mpeg wmv flv ts mts m2ts ogv ' ..
            '3gp 3g2 vob gif mp3 m4a aac flac ogg opus wav wma aiff alac ape'):gmatch('%S+') do
    extensions[ext] = true
end
local root, current_file
local file_cache, dir_cache = {}, {}
local scans = 0
local next_uri = 'vlc://pause:86400'
local previous_uri = 'vlc://pause:86401'
local next_id, previous_id
local libvlc = vlc.object.libvlc()
local playlist_object = vlc.object.playlist()
-- Command-line options are inherited object variables. config.get() reads
-- saved/default settings and can be empty even when --intf=qt was supplied.
local qt_interface = vlc.var.inherit(nil, 'intf') == 'qt'

local function gui_ready()
    -- Qt publishes this playlist variable after creating its main window and
    -- embedding provider. Extra interfaces start before Qt; playing sooner
    -- makes VLC fall back to a separate video window.
    return not qt_interface or
           vlc.var.get(playlist_object, 'window') == 'qt,any'
end

local function parent(path)
    local dir = path:match('^(.*)/[^/]+$')
    return dir == '' and '/' or dir
end

local function join(dir, name)
    return (dir == '/' and '/' or dir .. '/') .. name
end

local function stat(path)
    local ok, info = pcall(vlc.net.stat, path)
    return ok and info or nil
end

local function encode(text)
    return (text:gsub('([^%w%-%._~/])', function(c)
        return string.format('%%%02X', c:byte())
    end))
end

local function message(text)
    vlc.msg.info(text)
    -- No video output exists yet for audio, failed files, or a stopped player.
    pcall(vlc.osd.message, text, 0, 'top-right', 1500000)
end

local function entries(dir, want_files)
    local cache = want_files and file_cache or dir_cache
    if cache[dir] then return cache[dir] end
    scans = scans + 1
    local ok, names = pcall(vlc.io.readdir, dir)
    local result = {}
    for _, name in ipairs(ok and names or {}) do
        if name ~= '.' and name ~= '..' then
            local ext = (name:match('%.([^%.]+)$') or ''):lower()
            -- Do not stat unrelated files when listing media. Directories are
            -- inspected only when the current folder runs out of files.
            if (want_files and extensions[ext]) or
               (not want_files and name:sub(1, 1) ~= '.') then
                local path = join(dir, name)
                local info = stat(path)
                if info and ((want_files and info.type == 'file') or
                             (not want_files and info.type == 'dir')) then
                    result[#result + 1] = {
                        path = path, name = name, mtime = info.modification_time or 0
                    }
                end
            end
        end
    end
    table.sort(result, function(a, b)
        if a.mtime ~= b.mtime then return a.mtime < b.mtime end
        return a.name < b.name
    end)
    cache[dir] = result
    return result
end

local function first_in_tree(dir, depth)
    -- Bound recursion, including directory symlink cycles, like mpv-lazy.
    if depth > 64 then return nil end
    local files = entries(dir, true)
    if #files > 0 then return files[1].path end
    for _, child in ipairs(entries(dir, false)) do
        local found = first_in_tree(child.path, depth + 1)
        if found then return found end
    end
end

local function last_in_tree(dir, depth)
    if depth > 64 then return nil end
    local dirs = entries(dir, false)
    for i = #dirs, 1, -1 do
        local found = last_in_tree(dirs[i].path, depth + 1)
        if found then return found end
    end
    local files = entries(dir, true)
    if #files > 0 then return files[#files].path end
end

local function first_descendant(dir)
    for _, child in ipairs(entries(dir, false)) do
        local found = first_in_tree(child.path, 1)
        if found then return found end
    end
end

local function after_tree(dir)
    while dir ~= root do
        local ancestor = parent(dir)
        if not ancestor or ancestor == dir then return nil end
        local seen = false
        for _, sibling in ipairs(entries(ancestor, false)) do
            if seen then
                local found = first_in_tree(sibling.path, 1)
                if found then return found end
            end
            if sibling.path == dir then seen = true end
        end
        dir = ancestor
    end
end

local function before_tree(dir)
    while dir ~= root do
        local ancestor = parent(dir)
        if not ancestor or ancestor == dir then return nil end
        local siblings = entries(ancestor, false)
        for i = #siblings, 1, -1 do
            if siblings[i].path == dir then
                for j = i - 1, 1, -1 do
                    local found = last_in_tree(siblings[j].path, 1)
                    if found then return found end
                end
                break
            end
        end
        local files = entries(ancestor, true)
        if #files > 0 then return files[#files].path end
        dir = ancestor
    end
end

local function play(path)
    if not path then
        next_id, previous_id = nil, nil
        -- Stop and remove the navigation items. Leaving a repeated pause item
        -- here lets native Next wrap to the last real file or load forever.
        vlc.playlist.clear()
        message('No more media')
        return
    end
    current_file = path
    local current_uri = vlc.strings.make_uri(path)
    next_id, previous_id = nil, nil
    local options = {}
    -- VLC 3 otherwise treats animated GIFs as still images on older builds.
    if path:lower():match('%.gif$') then options = {'demux=avformat'} end
    vlc.playlist.repeat_('on')
    vlc.playlist.loop('off')
    vlc.playlist.clear()
    -- Navigation items keep VLC's toolbar buttons usable without scanning
    -- folders. Queue everything without autoplay, then select the real media.
    vlc.playlist.enqueue({
        {path = previous_uri, name = 'Previous media (vlc-lazy)'},
        {path = current_uri, options = options},
        {path = next_uri, name = 'Next media (vlc-lazy)'}
    })
    local media_id
    local playlist = vlc.playlist.get('playlist', false)
    for _, item in ipairs(playlist.children or {}) do
        if item.path == next_uri then next_id = item.id end
        if item.path == previous_uri then previous_id = item.id end
        if item.path == current_uri then media_id = item.id end
    end
    assert(media_id, 'Unable to queue media: ' .. path)
    vlc.playlist.gotoitem(media_id)
end

local function previous_file()
    if not current_file then return end
    local dir = parent(current_file)
    local files = entries(dir, true)
    for i, entry in ipairs(files) do
        if entry.path == current_file then
            if i > 1 then return play(files[i - 1].path) end
            break
        end
    end
    local path = before_tree(dir)
    if path then return play(path) end
    -- A toolbar click has already entered the previous navigation item.
    -- Restore the first file; a Left key at the beginning simply leaves it.
    if previous_id and vlc.playlist.current() == previous_id then
        play(current_file)
    end
    message('No previous media')
end

local function next_file()
    if not current_file then return end
    local dir = parent(current_file)
    local files = entries(dir, true)
    for i, entry in ipairs(files) do
        if entry.path == current_file then
            if i < #files then return play(files[i + 1].path) end
            break
        end
    end
    play(first_descendant(dir) or after_tree(dir))
end

local function next_folder()
    if not current_file then return end
    local dir = parent(current_file)
    -- Match mpv-lazy: from the root enter its children; elsewhere skip this
    -- folder's entire remaining subtree and continue at its next sibling.
    play(dir == root and first_descendant(dir) or after_tree(dir))
end

local function open(path, chosen_root)
    local info = stat(path)
    if not info or (info.type ~= 'file' and info.type ~= 'dir') then
        error('Not a file or directory: ' .. path)
    end
    file_cache, dir_cache, scans = {}, {}, 0
    root = chosen_root
    current_file = nil
    if info.type == 'dir' then
        play(first_in_tree(path, 0))
    else
        play(path) -- No readdir or sibling stat calls on a double click.
    end
end

local function handle(action, path, chosen_root)
    if action == 'ping' then
        if not gui_ready() then error('The VLC window is closing') end
        return 'ready-4'
    elseif action == 'open' then open(path, chosen_root)
    elseif action == 'next' then next_file()
    elseif action == 'next-folder' then next_folder()
    elseif action == 'status' then
        return 'file=' .. (current_file or '') .. '\nroot=' .. (root or '') ..
               '\nstate=' .. vlc.playlist.status() .. '\nscans=' .. scans
    else error('Unknown request: ' .. action) end
    return ''
end

local function write_reply(id, ok, text)
    local file = assert(io.open(state .. '/reply.tmp', 'w'))
    file:write(token .. '\n' .. id .. '\n' .. (ok and 'ok' or 'error') .. '\n' .. encode(text) .. '\n')
    file:close()
    assert(os.rename(state .. '/reply.tmp', state .. '/reply'))
end

local function request()
    local file = io.open(state .. '/request', 'r')
    if not file then return end
    local request_token, id, action, path, chosen_root = file:read('*l', '*l', '*l', '*l', '*l')
    file:close()
    os.remove(state .. '/request')
    if request_token ~= token or not id or not chosen_root then return end
    local ok, result = pcall(handle, action, vlc.strings.decode_uri(path), vlc.strings.decode_uri(chosen_root))
    if not ok then vlc.msg.err(tostring(result)) end
    write_reply(id, ok, tostring(result))
end

-- Handle arrow keys directly so file navigation also works when the native
-- playlist is empty at the end. Shift+arrows remain VLC's seek shortcuts.
-- VLC 3 has no Lua key callback; reset consumed keys to recognize repeats.
local key_handlers = {
    [0x00220000] = next_file,
    [0x00210000] = previous_file,
    [string.byte('n')] = next_file,
    [string.byte('p')] = previous_file,
    [0x04000000 + 0x00220000] = next_folder,
    [0x04000000 + string.byte('n')] = next_folder
}
while not gui_ready() do
    vlc.misc.mwait(vlc.misc.mdate() + 10000)
end
while true do
    request()
    local key = vlc.var.get(libvlc, 'key-pressed')
    local handler = key_handlers[key]
    if handler then
        vlc.var.set(libvlc, 'key-pressed', 0)
        handler()
    end
    -- Match the current playlist's unique marker IDs. Check every tick:
    -- VLC can still report a stale current ID while replacement is queued.
    local id = vlc.playlist.current()
    if next_id and id == next_id then
        next_file()
    elseif previous_id and id == previous_id then
        previous_file()
    end
    vlc.misc.mwait(vlc.misc.mdate() + 10000)
end
