-- OpenCombkeeper installer for OpenOS / Lua 5.2.
local fs=require('filesystem')
local component=require('component')
local shell=require('shell')
local computer=require('computer')
local args={...}
local action=args[1] or 'install'
local release=args[2] or 'main'
assert(release=='main' or release:match('^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$'),
  'Release must be main or a 40-character commit SHA')
local base='https://raw.githubusercontent.com/CptFishHead/OpenCombkeeper/'
local root='/home/.opencombkeeper'
local work='/home/.opencombkeeper-install'
local backups='/home/opencombkeeper-backup'
local data='/home/.opencombkeeper-data'
local keys={'opencombkeeper.lua','install.lua','src/topology.lua','src/executor.lua',
  'src/plan.lua','src/hardware.lua','src/hardware.example.lua','VERSION'}
local allowed={}
for _,key in ipairs(keys) do allowed[key]=true end

local function target(key)
  assert(allowed[key],'Unknown managed file')
  if key=='opencombkeeper.lua' then return '/usr/bin/opencombkeeper.lua' end
  if key=='install.lua' then return root..'/setup.lua' end
  if key=='src/hardware.lua' then return root..'/hardware.lua' end
  return root..'/'..key:match('([^/]+)$')
end
local function read(path)
  local file,reason=io.open(path,'rb'); if not file then return nil,reason end
  local content=file:read('*a'); file:close(); return content
end
local function write(path,content)
  local file=assert(io.open(path,'wb')); assert(file:write(content)); assert(file:flush())
  local ok,reason=file:close(); assert(ok~=false and not reason,reason or 'Close failed')
end
local function directory(path) if not fs.exists(path) then assert(fs.makeDirectory(path)) end end
local function remove(path) if fs.exists(path) then assert(fs.remove(path),'Cannot remove '..path) end end
local function checksum(content)
  local a,b=1,0
  for index=1,#content do a=(a+content:byte(index))%65521; b=(b+a)%65521 end
  return string.format('%08x',b*65536+a)
end
local function parse(content)
  assert(type(content)=='string' and #content<16384,'Missing or oversized manifest')
  local result={files={}}; local seen={}
  for line in (content..'\n'):gmatch('([^\n]*)\n') do
    line=line:gsub('\r$','')
    if line=='OpenCombkeeper-package-1' then assert(not result.header,'Duplicate header'); result.header=true
    elseif line:match('^revision ') then
      result.revision=line:match('^revision (%x+)$'); assert(result.revision and #result.revision==40,'Invalid revision')
    elseif line:match('^version ') then
      result.version=line:match('^version ([%w%.%-]+)$'); assert(result.version,'Invalid version')
    elseif line:match('^file ') then
      local key,size,sum=line:match('^file ([%w%./%-]+) (%d+) (%x+)$')
      assert(key and allowed[key] and not seen[key],'Invalid or duplicate file')
      size=tonumber(size); assert(size>0 and size<=2097152 and #sum==8,'Invalid file metadata')
      seen[key]=true; result.files[#result.files+1]={key=key,size=size,sum=sum:lower()}
    else assert(line=='','Invalid manifest line') end
  end
  assert(result.header and result.revision and result.version,'Incomplete manifest')
  for _,key in ipairs(keys) do assert(seen[key],'Missing manifest entry: '..key) end
  return result
end
local function verify(path,entry)
  local content,reason=read(path); assert(content,'Missing '..path..': '..tostring(reason))
  assert(#content==entry.size and checksum(content)==entry.sum,'Checksum mismatch: '..path)
  if path:match('%.lua$') then local chunk,errorText=loadfile(path); assert(chunk,errorText) end
end
local function unique(parent,prefix)
  directory(parent); local path=parent..'/'..prefix..tostring(math.floor(computer.uptime()*1000))
  while fs.exists(path) do path=path..'-new' end
  directory(path); return path
end
local function download(url,path)
  assert(shell.execute('wget -fq '..url..' '..path),'Download failed: '..url)
  assert(fs.exists(path) and fs.size(path)>0,'Downloaded file is empty: '..path)
end
local function check()
  local text=assert(read(root..'/package.manifest'),'Not installed')
  local manifest=parse(text); local failures=0
  print('OpenCombkeeper '..manifest.version..' / '..manifest.revision:sub(1,8))
  for _,entry in ipairs(manifest.files) do
    local ok,reason=pcall(verify,target(entry.key),entry)
    print((ok and 'OK   ' or 'FAIL ')..entry.key)
    if not ok then failures=failures+1; print(tostring(reason)) end
  end
  assert(failures==0,tostring(failures)..' managed file(s) failed')
  print('User data: '..data..' (not managed)')
  print('Hardware adapter: '..(fs.exists(root..'/hardware.lua') and 'present' or 'not installed'))
  return true
end
local function install()
  assert(component.isAvailable('internet'),'Internet card required')
  directory(root); directory(data)
  local stage=unique(work,'stage-')
  local fresh=tostring(math.floor(computer.uptime()*1000))
  print('Downloading release manifest...')
  download(base..release..'/package.manifest?fresh='..fresh,stage..'/package.manifest')
  local manifestText=assert(read(stage..'/package.manifest')); local manifest=parse(manifestText)
  if action=='update' and read(root..'/package.manifest')==manifestText then
    local ok=pcall(check); if ok then print('Already up to date.'); return true end
  end
  for index,entry in ipairs(manifest.files) do
    print(string.format('[%d/%d] %s',index,#manifest.files,entry.key))
    local staged=stage..'/'..entry.key:gsub('/','_')
    download(base..manifest.revision..'/'..entry.key,staged); verify(staged,entry); entry.staged=staged
  end
  local backup=unique(backups,'backup-'); local journal={}
  for _,entry in ipairs(manifest.files) do
    local destination=target(entry.key); local old=read(destination)
    if old then
      local backupFile=backup..'/'..entry.key:gsub('/','_'); write(backupFile,old)
      entry.backup=backupFile; entry.existed=true
      journal[#journal+1]=entry.key..' 1 '..#old..' '..checksum(old)
    else entry.existed=false; journal[#journal+1]=entry.key..' 0 0 00000001' end
  end
  write(backup..'/restore.list',table.concat(journal,'\n')..'\n')
  local ok,reason=pcall(function()
    for _,entry in ipairs(manifest.files) do
      local destination=target(entry.key); directory(fs.path(destination))
      write(destination,assert(read(entry.staged))); verify(destination,entry)
    end
    write(root..'/package.manifest',manifestText)
  end)
  if not ok then
    local restored,restoreReason=pcall(function()
      for _,entry in ipairs(manifest.files) do
        local destination=target(entry.key)
        if entry.existed then write(destination,assert(read(entry.backup))) else remove(destination) end
      end
    end)
    error('Install failed: '..tostring(reason)..'\nBackup: '..backup..
      (restored and '\nPrevious managed files restored.' or '\nRestore failed: '..tostring(restoreReason)))
  end
  print('Installed OpenCombkeeper '..manifest.version)
  print('Backup: '..backup); print('Data preserved: '..data)
  print('Run: opencombkeeper scan | opencombkeeper bind | opencombkeeper topology-check')
  print('Run opencombkeeper hardware-check before the first physical operation.')
  return true
end

local ok,result=pcall(function()
  if action=='check' then return check() end
  assert(action=='install' or action=='update' or action=='reinstall' or action=='repair',
    'Use: install | update | reinstall | repair | check')
  return install()
end)
if not ok then io.stderr:write('OpenCombkeeper: '..tostring(result)..'\n'); return false end
return result
