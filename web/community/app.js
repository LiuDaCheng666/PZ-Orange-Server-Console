let csrf='',session=null,servers=[],serverId='',chatCursor=0,chatFile='',chatMessages=[],players=[],channel='all';
let chatBusy=false,playersBusy=false,statusBusy=false,chatTimer=null,playersTimer=null,statusTimer=null,toastTimer=null;

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
function showLogin(){session=null;csrf='';$('#app').hidden=true;$('#authScreen').hidden=false;clearInterval(chatTimer);clearInterval(playersTimer);clearInterval(statusTimer)}
function enterApp(result){session=result.user;csrf=result.csrf||'';$('#signedUser').textContent=session.displayName||session.username;$('#authScreen').hidden=true;$('#app').hidden=false;loadServers();chatTimer=setInterval(pollChat,1500);playersTimer=setInterval(pollPlayers,5000);statusTimer=setInterval(pollNoticeStatus,5000);lucide.createIcons()}

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
  renderServers();renderMessages();renderPlayers();pollChat();pollPlayers();pollNoticeStatus();
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

$('#channelTabs').querySelectorAll('button').forEach(button=>button.onclick=()=>{channel=button.dataset.channel;$('#channelTabs').querySelectorAll('button').forEach(item=>item.classList.toggle('active',item===button));renderMessages()});
$('#targetType').onchange=()=>{$('#targetPlayerField').hidden=$('#targetType').value!=='player'};
$('#noticeForm').onsubmit=async event=>{
  event.preventDefault();const data=formData(event.target),selectedServer=serverId;$('#sendNotice').disabled=true;$('#noticeResult').textContent='正在提交...';
  try{const result=await api('/community/api/notices',{method:'POST',body:JSON.stringify({...data,serverId:selectedServer,duration:Number(data.duration)})});$('#noticeResult').textContent=`已进入队列，预计 ${result.expectedClients} 个客户端`;showToast(result.message);followReceipt(result.id,result.expectedClients,selectedServer)}catch(error){$('#noticeResult').textContent=error.message;showToast(error.message)}finally{setTimeout(pollNoticeStatus,5000)}
};
$('#loginForm').onsubmit=async event=>{event.preventDefault();$('#authError').textContent='';try{const result=await api('/community/api/auth/login',{method:'POST',body:JSON.stringify(formData(event.target))});enterApp(result)}catch(error){$('#authError').textContent=error.message}};
$('#logoutButton').onclick=async()=>{try{await api('/community/api/auth/logout',{method:'POST'})}catch{}showLogin()};

(async()=>{try{const result=await api('/community/api/auth/session');if(result.authenticated)enterApp(result);else showLogin()}catch(error){showLogin();$('#authError').textContent=error.message}lucide.createIcons()})();
