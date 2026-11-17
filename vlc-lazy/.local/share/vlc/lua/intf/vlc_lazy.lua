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
local next_id, observed_id
local libvlc = vlc.object.libvlc()

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

local function play(path)
    if not path then
        next_id = nil
        vlc.playlist.stop()
        message('No more media')
        return
    end
    current_file = path
    local current_uri = vlc.strings.make_uri(path)
    next_id = nil
    observed_id = nil
    local options = {}
    -- VLC 3 otherwise treats animated GIFs as still images on older builds.
    if path:lower():match('%.gif$') then options = {'demux=avformat'} end
    vlc.playlist.repeat_('on')
    vlc.playlist.loop('off')
    vlc.playlist.clear()
    vlc.playlist.add({{path = current_uri, options = options}})
    -- This small navigation item keeps VLC's real Next button enabled without
    -- enumerating a folder. Repeat-current prevents EOF from advancing to it.
    vlc.playlist.enqueue({{path = next_uri, name = 'Next media (vlc-lazy)'}})
    -- Match the new marker's unique ID, not just its URI. The old marker can
    -- still be current while VLC asynchronously opens the replacement file.
    -- This also recognizes a rapid second Next before that file starts.
    local playlist = vlc.playlist.get('playlist', false)
    for _, item in ipairs(playlist.children or {}) do
        if item.path == next_uri then next_id = item.id end
    end
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
    if action == 'open' then open(path, chosen_root)
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

-- VLC 3's Lua API has no key callback. Sample its key variable every 10 ms,
-- resetting consumed keys so repeated Ctrl+Right presses are recognized.
local ctrl_right = 0x04000000 + 0x00220000
local ctrl_n = 0x04000000 + string.byte('n')
while true do
    request()
    local key = vlc.var.get(libvlc, 'key-pressed')
    if key == ctrl_right or key == ctrl_n then
        vlc.var.set(libvlc, 'key-pressed', 0)
        next_folder()
    end
    local id = vlc.playlist.current()
    if id ~= observed_id then
        observed_id = id
        if id == next_id then
            next_file()
        end
    end
    vlc.misc.mwait(vlc.misc.mdate() + 10000)
end
