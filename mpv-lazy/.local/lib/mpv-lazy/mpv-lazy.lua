-- mpv-lazy: depth-first, on-demand filesystem navigation for one mpv instance.
-- Directory order: direct files (oldest first), then subdirectories (oldest first).
-- Only the current directory and directories needed for navigation are scanned.

local utils = require 'mp.utils'
local valid_extensions = {}
for ext in ('mp4 mkv webm avi mov m4v mpg mpeg wmv flv ts mts m2ts ogv 3gp 3g2 vob ' ..
              'mp3 m4a aac flac ogg opus wav wma aiff alac ape ' ..
              'jpg jpeg png webp gif bmp tif tiff avif heic heif jxl'):gmatch('%S+') do
    valid_extensions[ext] = true
end

local root = nil
local current_file = nil
local internal_file = nil
local file_cache = {}
local dir_cache = {}

local function norm_dir(p)
    if p == '/' then return '/' end
    p = p:gsub('/+$', '')
    return p ~= '' and p or '/'
end

local function parent_dir(p)
    p = norm_dir(p)
    if p == '/' then return '/' end
    local parent = p:match('^(.*)/[^/]+$')
    return norm_dir(parent or '/')
end

local function join(dir, name)
    return (dir == '/' and '/' or dir .. '/') .. name
end

local function within(p, r)
    return p == r or p:sub(1, #r + (r == '/' and 0 or 1)) ==
        (r == '/' and '/' or r .. '/')
end

local function media_file(name)
    local ext = name:match('%.([^%.]+)$')
    return ext and valid_extensions[ext:lower()] or false
end

local function reset_caches()
    file_cache = {}
    dir_cache = {}
end

local function sort_entries(entries)
    table.sort(entries, function(a, b)
        if a.mtime ~= b.mtime then return a.mtime < b.mtime end
        return a.name < b.name
    end)
end

local function list_entries(dir, kind)
    local cache = kind == 'files' and file_cache or dir_cache
    if cache[dir] then return cache[dir] end
    local names = utils.readdir(dir, kind) or {}
    local entries = {}
    for _, name in ipairs(names) do
        if (kind ~= 'files' or media_file(name)) and
           (kind ~= 'dirs' or name:sub(1, 1) ~= '.') then
            local path = join(dir, name)
            local info = utils.file_info(path)
            if info then
                entries[#entries + 1] = {
                    name = name, path = path, mtime = info.mtime or 0
                }
            end
        end
    end
    sort_entries(entries)
    cache[dir] = entries
    return entries
end

local function files_in(dir) return list_entries(dir, 'files') end
local function dirs_in(dir) return list_entries(dir, 'dirs') end

local function first_in_tree(dir, depth)
    if depth > 64 then return nil end -- Prevent recursive symlink loops.
    local files = files_in(dir)
    if #files > 0 then return files[1].path end
    for _, child in ipairs(dirs_in(dir)) do
        local found = first_in_tree(child.path, depth + 1)
        if found then return found end
    end
    return nil
end

local function last_in_tree(dir, depth)
    if depth > 64 then return nil end
    local dirs = dirs_in(dir)
    for i = #dirs, 1, -1 do
        local found = last_in_tree(dirs[i].path, depth + 1)
        if found then return found end
    end
    local files = files_in(dir)
    if #files > 0 then return files[#files].path end
    return nil
end

local function first_descendant(dir)
    for _, child in ipairs(dirs_in(dir)) do
        local found = first_in_tree(child.path, 1)
        if found then return found end
    end
    return nil
end

local function after_tree(dir)
    while dir ~= root do
        local parent = parent_dir(dir)
        if parent == dir or not within(parent, root) then return nil end
        local siblings = dirs_in(parent)
        local seen = false
        for _, sibling in ipairs(siblings) do
            if seen then
                local found = first_in_tree(sibling.path, 1)
                if found then return found end
            end
            if sibling.path == dir then seen = true end
        end
        dir = parent
    end
    return nil
end

local function before_tree(dir)
    while dir ~= root do
        local parent = parent_dir(dir)
        if parent == dir or not within(parent, root) then return nil end
        local siblings = dirs_in(parent)
        for i = #siblings, 1, -1 do
            if siblings[i].path == dir then
                for j = i - 1, 1, -1 do
                    local found = last_in_tree(siblings[j].path, 1)
                    if found then return found end
                end
                break
            end
        end
        local files = files_in(parent)
        if #files > 0 then return files[#files].path end
        dir = parent
    end
    return nil
end

local function play(path)
    if not path then
        mp.osd_message('No more media in this direction', 1.5)
        return
    end
    internal_file = path
    current_file = path
    mp.commandv('loadfile', path, 'replace')
end

local function next_file()
    if not root or not current_file then return end
    local dir = parent_dir(current_file)
    local files = files_in(dir)
    for i, entry in ipairs(files) do
        if entry.path == current_file then
            if i < #files then return play(files[i + 1].path) end
            break
        end
    end
    play(first_descendant(dir) or after_tree(dir))
end

local function previous_file()
    if not root or not current_file then return end
    local dir = parent_dir(current_file)
    local files = files_in(dir)
    for i, entry in ipairs(files) do
        if entry.path == current_file then
            if i > 1 then return play(files[i - 1].path) end
            break
        end
    end
    play(before_tree(dir))
end

local function next_folder()
    if not root or not current_file then return end
    local dir = parent_dir(current_file)
    -- From the root, move into its first descendant. Else skip this subtree.
    if dir == root then
        play(first_descendant(dir))
    else
        play(after_tree(dir))
    end
end

local function previous_folder()
    if not root or not current_file then return end
    local dir = parent_dir(current_file)
    if dir == root then
        return mp.osd_message('Already at the root directory', 1.5)
    end
    play(before_tree(dir))
end

local function rename_file()
    if not current_file then return end
    local old_path = current_file
    local dir = parent_dir(old_path)
    local old_name = old_path:match('([^/]+)$') or ''
    local res = mp.command_native({
        name = 'subprocess', playback_only = false, capture_stdout = true,
        args = {'zenity', '--entry', '--title=Rename media',
                '--text=New filename:', '--entry-text=' .. old_name}
    })
    if not res or res.status ~= 0 then return end
    local name = (res.stdout or ''):gsub('[\r\n]+$', '')
    if name == '' or name == '.' or name == '..' or name:find('/', 1, true) then
        return mp.osd_message('Invalid filename', 2)
    end
    if name == old_name then return end
    local new_path = join(dir, name)
    if utils.file_info(new_path) then
        return mp.osd_message('Filename already exists', 2)
    end
    local ok, err = os.rename(old_path, new_path)
    if not ok then
        return mp.osd_message('Rename failed: ' .. tostring(err), 3)
    end
    current_file = new_path
    file_cache[dir] = nil
    mp.osd_message('Renamed to: ' .. name, 2)
end

-- The launcher sends "open" over mpv JSON IPC. A root can be set to an
-- ancestor folder using --root, allowing traversal across sibling folders.
mp.register_script_message('open', function(path, chosen_root)
    if not path or path == '' then return end
    local info = utils.file_info(path)
    if not info then
        return mp.osd_message('Not found: ' .. path, 3)
    end
    reset_caches()
    if info.is_dir then
        root = norm_dir(path)
        current_file = nil
        local first = first_in_tree(root, 0)
        if first then play(first)
        else mp.osd_message('No media below: ' .. root, 3) end
    else
        root = (chosen_root and chosen_root ~= '') and norm_dir(chosen_root)
               or parent_dir(path)
        if not within(path, root) then root = parent_dir(path) end
        play(path) -- Start the clicked file without scanning any directory.
    end
end)

-- If the file was loaded from elsewhere, reset root to that file's directory.
mp.register_event('file-loaded', function()
    local path = mp.get_property('path')
    if not path then return end
    if internal_file == path then
        internal_file = nil
        current_file = path
        return
    end
    internal_file = nil
    current_file = path
    root = parent_dir(path)
    reset_caches()
end)

-- Advance video/audio automatically when playback reaches the end.
mp.register_event('end-file', function(ev)
    if ev.reason == 'eof' and current_file then
        local ended = current_file
        mp.add_timeout(0, function()
            if current_file == ended then next_file() end
        end)
    end
end)

mp.add_forced_key_binding('RIGHT', 'lazy-next', next_file)
mp.add_forced_key_binding('LEFT', 'lazy-prev', previous_file)
mp.add_forced_key_binding('Ctrl+RIGHT', 'lazy-next-folder', next_folder)
mp.add_forced_key_binding('Ctrl+LEFT', 'lazy-prev-folder', previous_folder)
mp.add_forced_key_binding('Shift+RIGHT', 'lazy-seek-fwd',
    function() mp.commandv('seek', '5', 'relative+exact') end)
mp.add_forced_key_binding('Shift+LEFT', 'lazy-seek-back',
    function() mp.commandv('seek', '-5', 'relative+exact') end)
mp.add_forced_key_binding('F2', 'lazy-rename', rename_file)

-- Signal readiness only after all message and key handlers are registered.
mp.set_property_bool("user-data/mpv-lazy/ready", true)
