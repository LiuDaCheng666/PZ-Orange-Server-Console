let csrf='',session=null,servers=[],serverId='',chatCursor=0,chatFile='',chatMessages=[],players=[],channel='all';
let chatBusy=false,playersBusy=false,statusBusy=false,maintenanceBusy=false,maintenanceStatusBusy=false,chatTimer=null,playersTimer=null,statusTimer=null,maintenanceTimer=null,toastTimer=null;

const $=selector=>document.querySelector(selector);
const escapeHtml=value=>String(value??'').replace(/[&<>'"]/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[char]));
const formData=form=>Object.fromEntries(new FormData(form).entries());
function showToast(message){const node=$('#toast');node.textContent=message;node.hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>node.hidden=true,3500)}
async function api(path,options={}){
  const headers={'Content-Type':'application/json',...(options.headers||{})};
  if(options.method&&options.method!=='GET'&&csrf)headers['X-PZ-CSRF']=csrf;
  const response=await fetch(path,{credentials:'same-origin',...options,headers});
  const data=await response.json().catch(()=>({error:`请求失败（HTTP ${response.status}）`}));
  if(response.status===401&&path!=='/community/api/auth/login'){showLogin();throw new Error(data.error||'登录已失效。')}
  if(!response.ok||data.ok===false)throw new Error(data.error||'请求失败。');
  return data;
}
function showLogin(){session=null;csrf='';$('#app').hidden=true;$('#authScreen').hidden=false;clearInterval(chatTimer);clearInterval(playersTimer);clearInterval(statusTimer);clearInterval(maintenanceTimer)}
function enterApp(result){session=result.user;csrf=result.csrf||'';$('#signedUser').textContent=session.displayName||session.username;$('#maintenancePane').hidden=!session.canManageMaintenance;$('#authScreen').hidden=true;$('#app').hidden=false;loadServers();chatTimer=setInterval(pollChat,1500);playersTimer=setInterval(pollPlayers,5000);statusTimer=setInterval(pollNoticeStatus,5000);if(session.canManageMaintenance)maintenanceTimer=setInterval(pollMaintenanceStatus,3000);lucide.createIcons()}

async function loadServers(){
  try{
    const data=await api('/community/api/servers');servers=data.servers||[];
    const stored=localStorage.getItem('pz-community-server');serverId=servers.some(item=>item.id===stored)?stored:(servers[0]?.id||'');
    renderServers();switchServer(serverId);
  }catch(error){showToast(error.message)}
}
function renderServers(){
  $('#serverTabs').innerHTML=servers.map(server=>`<button type="button" data-id="${escapeHtml(server.id)}" class="${server.id===serverId?'active':''}">${escapeHtml(server.name)}</button>`).join('');
  $('#serverTabs').querySelectorAll('button').forEach(button=>button.onclick=()=>switchServer(button.dataset.id));
}
function switchServer(id){
  if(!servers.some(server=>server.id===id))return;serverId=id;localStorage.setItem('pz-community-server',id);chatCursor=0;chatFile='';chatMessages=[];players=[];
  delete $('#restartForm').elements.restartStabilizationSeconds.dataset.changed;
  renderServers();renderMessages();renderPlayers();pollChat();pollPlayers();pollNoticeStatus();if(session?.canManageMaintenance)pollMaintenanceStatus();
}
function timeLabel(value){const match=String(value||'').match(/(\d{2}:\d{2}:\d{2})/);return match?match[1]:String(value||'').slice(-8)}
function channelLabel(value){return value==='General'?'全服':value==='Local'?'附近':'广播'}
function renderMessages(){
  const visible=chatMessages.filter(item=>channel==='all'||item.channel===channel),surface=$('#messages'),atBottom=surface.scrollHeight-surface.scrollTop-surface.clientHeight<70;
  surface.innerHTML=visible.map(item=>`<article class="message ${item.kind==='broadcast'?'broadcast':''}"><time>${escapeHtml(timeLabel(item.timestamp))}</time><strong>${escapeHtml(item.author||'服务器')}<span class="channel">${channelLabel(item.channel)}</span></strong><p>${escapeHtml(item.text)}</p></article>`).join('')||'<p class="empty">当前频道还没有消息。</p>';
  if(atBottom)surface.scrollTop=surface.scrollHeight;
}
async function pollChat(){
  if(chatBusy||!serverId)return;chatBusy=true;
  try{
    const query=new URLSearchParams({serverId,after:String(chatCursor),file:chatFile});const data=await api(`/community/api/chat?${query}`);if(data.serverId!==serverId)return;
    if(data.reset)chatMessages=[];chatCursor=Number(data.cursor||0);chatFile=data.fileId||'';
    const known=new Set(chatMessages.map(item=>item.id));for(const item of data.messages||[])if(!known.has(item.id)){known.add(item.id);chatMessages.push(item)}
    if(chatMessages.length>300)chatMessages=chatMessages.slice(-300);renderMessages();$('#chatDot').className=data.available?'online':'';$('#chatStatus').textContent=data.available?'公开聊天已连接':'尚未找到聊天日志';
  }catch(error){$('#chatDot').className='error';$('#chatStatus').textContent=error.message}finally{chatBusy=false}
}
function roleLabel(role){const value=String(role||'user').toLowerCase();return value==='admin'?'管理员':value==='moderator'?'协管':'玩家'}
function renderPlayers(){
  $('#playerCount').textContent=String(players.length);$('#players').innerHTML=players.map(player=>`<div class="player"><span>${escapeHtml(player.username.slice(0,1).toUpperCase())}</span><div><strong>${escapeHtml(player.username)}</strong><small>${roleLabel(player.role)}</small></div></div>`).join('')||'<p class="empty">当前没有已确认的在线玩家。</p>';
  const selected=$('#targetUsername').value;$('#targetUsername').innerHTML=players.map(player=>`<option value="${escapeHtml(player.username)}">${escapeHtml(player.username)}</option>`).join('');if(players.some(player=>player.username===selected))$('#targetUsername').value=selected;
}
async function pollPlayers(){
  if(playersBusy||!serverId)return;playersBusy=true;
  try{const data=await api(`/community/api/players?serverId=${encodeURIComponent(serverId)}`);if(data.serverId===serverId){players=data.players||[];renderPlayers()}}catch(error){$('#players').innerHTML=`<p class="empty">${escapeHtml(error.message)}</p>`}finally{playersBusy=false}
}
async function pollNoticeStatus(){
  if(statusBusy||!serverId)return;statusBusy=true;
  try{const data=await api(`/community/api/notices/status?serverId=${encodeURIComponent(serverId)}`);if(data.serverId!==serverId)return;const usable=Boolean(data.channel?.usable);$('#noticeState').textContent=usable?`通道在线 · v${data.channel.version||'--'}`:'通道不可用';$('#noticeState').className=`notice-state ${usable?'online':'error'}`;$('#sendNotice').disabled=!usable}catch(error){$('#noticeState').textContent=error.message;$('#noticeState').className='notice-state error';$('#sendNotice').disabled=true}finally{statusBusy=false}
}
async function followReceipt(id,expected,selectedServer){
  for(let attempt=0;attempt<30;attempt++){
    await new Promise(resolve=>setTimeout(resolve,2000));if(serverId!==selectedServer)return;
    try{const data=await api(`/community/api/notices/receipt?serverId=${encodeURIComponent(selectedServer)}&id=${encodeURIComponent(id)}`);if(data.status==='rejected'){throw new Error(data.error||'服务端拒绝了通知。')}if(data.status!=='queued'){const target=Number(data.expectedClients??expected??0),acked=Number(data.acknowledgedClients||0);$('#noticeResult').textContent=`服务端已发送，客户端确认 ${acked}/${target}`;return}}catch(error){$('#noticeResult').textContent=error.message;return}
  }
  $('#noticeResult').textContent='通知已提交，客户端回执仍在等待。';
}

const maintenanceStatusLabels={checking:'检查中',current:'已是最新', 'update-required':'发现更新','auto-restart-queued':'自动重启中','auto-restart-completed':'自动重启完成','auto-restart-failed':'自动重启失败',skipped:'已跳过',failed:'检查失败',interrupted:'检查中断','no-result':'结果不明确'};
const lifecycleStageLabels={queued:'排队中','waiting-lifecycle-lock':'等待维护锁',notifying:'通知玩家',countdown:'通知倒计时',saving:'保存世界',quitting:'关闭服务器','waiting-exit':'等待进程退出',stabilizing:'停服缓冲',starting:'启动服务器','waiting-start':'等待服务器启动',completed:'已完成',failed:'失败'};
function formatDate(value){if(!value)return'--';const date=new Date(value);return Number.isNaN(date.getTime())?String(value):date.toLocaleString('zh-CN',{hour12:false})}
function operationMessage(operation){
  if(!operation)return'当前没有维护任务';
  const target=operation.stage==='countdown'?operation.countdownUntil:operation.stage==='stabilizing'?operation.stabilizationUntil:null;
  if(target){const seconds=Math.max(0,Math.ceil((new Date(target).getTime()-Date.now())/1000));return `${operation.message||'正在执行'} · 约 ${seconds} 秒`;}
  return operation.error||operation.message||'正在处理';
}
function renderMaintenanceStatus(data){
  const server=data.server||{},maintenance=data.maintenance||{},operation=data.operation,active=operation&&['queued','running'].includes(operation.status);
  $('#maintenanceServerName').textContent=server.name||servers.find(item=>item.id===serverId)?.name||'--';
  $('#maintenanceServerNote').textContent=server.note||'--';
  $('#maintenanceServerState').textContent=active?'维护执行中':server.alive?'运行中':'已停止';
  $('#maintenanceServerState').className=`maintenance-state ${active?'busy':server.alive?'online':'error'}`;
  $('#maintenanceModState').textContent=maintenanceStatusLabels[maintenance.lastStatus]||maintenance.lastStatus||'尚未检查';
  $('#maintenanceModResult').textContent=maintenance.lastMessage||'尚未执行 Mod 更新检查。';
  $('#maintenanceAutoRestart').textContent=maintenance.autoRestartOnUpdate?'发现更新后自动重启':'仅检查并提示';
  $('#maintenanceLastCheck').textContent=`上次检查 ${formatDate(maintenance.lastRunAt)}`;
  $('#maintenanceOperationState').textContent=operation?`${lifecycleStageLabels[operation.stage]||operation.stage||'处理中'}${operation.status==='failed'?' · 失败':operation.status==='completed'?' · 完成':''}`:'空闲';
  $('#maintenanceOperationMessage').textContent=operationMessage(operation);
  $('#maintenanceResult').textContent=maintenance.lastMessage||'等待操作';
  const stabilization=$('#restartForm').elements.restartStabilizationSeconds;if(!stabilization.dataset.changed)stabilization.value=maintenance.restartStabilizationSeconds||90;
  $('#checkModsButton').disabled=maintenanceBusy||Boolean(maintenance.running)||Boolean(server.lifecycleBusy);
  $('#restartButton').disabled=maintenanceBusy||!server.canRestart||Boolean(server.lifecycleBusy);
}
async function pollMaintenanceStatus(){
  if(maintenanceStatusBusy||!session?.canManageMaintenance||!serverId)return;maintenanceStatusBusy=true;const selectedServer=serverId;
  try{const data=await api(`/community/api/maintenance/status?serverId=${encodeURIComponent(selectedServer)}`);if(serverId===selectedServer)renderMaintenanceStatus(data)}catch(error){if(serverId===selectedServer){$('#maintenanceServerState').textContent='状态读取失败';$('#maintenanceServerState').className='maintenance-state error';$('#maintenanceResult').textContent=error.message}}finally{maintenanceStatusBusy=false}
}

$('#channelTabs').querySelectorAll('button').forEach(button=>button.onclick=()=>{channel=button.dataset.channel;$('#channelTabs').querySelectorAll('button').forEach(item=>item.classList.toggle('active',item===button));renderMessages()});
$('#targetType').onchange=()=>{$('#targetPlayerField').hidden=$('#targetType').value!=='player'};
$('#restartForm').elements.restartStabilizationSeconds.oninput=event=>event.currentTarget.dataset.changed='true';
$('#checkModsButton').onclick=async()=>{
  if(maintenanceBusy||!serverId)return;maintenanceBusy=true;$('#checkModsButton').disabled=true;$('#maintenanceResult').textContent='正在提交 Mod 更新检查...';
  try{const result=await api('/community/api/maintenance/check',{method:'POST',body:JSON.stringify({serverId})});$('#maintenanceResult').textContent=result.message;showToast(result.message);pollMaintenanceStatus()}catch(error){$('#maintenanceResult').textContent=error.message;showToast(error.message)}finally{maintenanceBusy=false;setTimeout(pollMaintenanceStatus,800)}
};
$('#restartForm').onsubmit=async event=>{
  event.preventDefault();if(maintenanceBusy||!serverId)return;const values=formData(event.currentTarget),warningSeconds=Number(values.warningSeconds),restartStabilizationSeconds=Number(values.restartStabilizationSeconds),server=servers.find(item=>item.id===serverId);
  if(!Number.isInteger(warningSeconds)||warningSeconds<10||warningSeconds>600){showToast('通知倒计时必须为 10 至 600 秒。');return}
  if(!Number.isInteger(restartStabilizationSeconds)||restartStabilizationSeconds<10||restartStabilizationSeconds>600){showToast('停服缓冲必须为 10 至 600 秒。');return}
  if(!confirm(`确认安全重启 ${server?.name||'当前服务器'}？\n\n系统会先发送双通道通知，等待 ${warningSeconds} 秒后保存退出；旧 Java 完全结束后再等待 ${restartStabilizationSeconds} 秒启动。`))return;
  maintenanceBusy=true;$('#restartButton').disabled=true;$('#maintenanceResult').textContent='正在提交安全重启...';
  try{const result=await api('/community/api/maintenance/restart',{method:'POST',body:JSON.stringify({serverId,confirm:'COMMUNITY_SAVE_QUIT_RESTART',warningSeconds,restartStabilizationSeconds})});$('#maintenanceResult').textContent=result.message;showToast(result.message);pollMaintenanceStatus()}catch(error){$('#maintenanceResult').textContent=error.message;showToast(error.message)}finally{maintenanceBusy=false;setTimeout(pollMaintenanceStatus,800)}
};
$('#noticeForm').onsubmit=async event=>{
  event.preventDefault();const data=formData(event.target),selectedServer=serverId;$('#sendNotice').disabled=true;$('#noticeResult').textContent='正在提交...';
  try{const result=await api('/community/api/notices',{method:'POST',body:JSON.stringify({...data,serverId:selectedServer,duration:Number(data.duration)})});$('#noticeResult').textContent=`已进入队列，预计 ${result.expectedClients} 个客户端`;showToast(result.message);followReceipt(result.id,result.expectedClients,selectedServer)}catch(error){$('#noticeResult').textContent=error.message;showToast(error.message)}finally{setTimeout(pollNoticeStatus,5000)}
};
$('#loginForm').onsubmit=async event=>{event.preventDefault();$('#authError').textContent='';try{const result=await api('/community/api/auth/login',{method:'POST',body:JSON.stringify(formData(event.target))});enterApp(result)}catch(error){$('#authError').textContent=error.message}};
$('#logoutButton').onclick=async()=>{try{await api('/community/api/auth/logout',{method:'POST'})}catch{}showLogin()};

(async()=>{try{const result=await api('/community/api/auth/session');if(result.authenticated)enterApp(result);else showLogin()}catch(error){showLogin();$('#authError').textContent=error.message}lucide.createIcons()})();
