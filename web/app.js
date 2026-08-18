const qs=new URLSearchParams(location.search);
const views=['overview','console','chat','players','items','world','commands','system','profiles','ai','users','map-reset','maintenance'];
const initialView=views.includes(qs.get('view'))?qs.get('view'):'overview';

const titles={overview:'服务器总览',console:'实时日志',chat:'游戏聊天',players:'玩家管理',items:'物品资料库',world:'世界控制',commands:'命令中心',system:'本机资源监控',profiles:'服务器配置',ai:'游戏内 AI 助手',users:'Web 登录用户','map-reset':'地图刷新',maintenance:'维护与审计'};
let selectedId=qs.get('server')||localStorage.getItem('pz-server')||'',activeView=initialView;
let cursor=0,paused=false,filter='all',logLines=[],lastStatus=null,statusBusy=false,logBusy=false;
let profileConfig=null,editingProfileId='',playerDirectory=null,playersBusy=false,playerRequestServer='',playerRequestSerial=0,lastPlayersRefreshAt=0;
let playerAdminSnapshot=null,playerAdminBusy=false,playerAdminSerial=0;
let authSession=null,csrfToken='',appStarted=false,statusTimer=null,logTimer=null,systemTimer=null,userDirectory=[];
let itemSearchTimer=null,itemPollTimer=null,itemRequestSerial=0,itemIndexSnapshot=null,systemBusy=false,hostControlState=null;
let itemCatalogTimer=null,itemCatalogSerial=0,itemCatalogPage=1,itemCatalogSnapshot=null,itemCatalogSelected=null;
let chatCursor=0,chatFile='',chatMessages=[],chatFilter='all',chatBusy=false,chatTimer=null,chatFollowLatest=true,worldgenSerial=0;
let commandResultSerial=0,lifecycleSerial=0,lifecycleOperation=null;
let saveBackupPlan=null,saveBackupBusy=false,maintenanceSchedule=null,maintenanceBusy=false,programUpdateStatus=null,programUpdateBusy=false;
let noticeStatusBusy=false,noticeStatusServer='',noticeChannel=null,noticeSerial=0,noticeLastCheckedAt=0,noticeStatusError='';
let aiConfig=null,aiBusy=false,aiKnowledgeBuild=null,aiKnowledgeTimer=null;
let broadcastSchedules=[],broadcastScheduleBusy=false,executionHistory=[],executionHistoryPage=1,executionHistoryPageSize=30,executionHistoryTotal=0,executionHistoryTotalPages=1;
let aiPolicies=[],aiOperations=[],aiPolicyPlayers=[],aiModerationEvents=[];
let mapResetSnapshot=null,mapResetBusy=false,mapResetPollTimer=null,mapResetSerial=0,mapResetServerId='';

const api=async(path,options={})=>{
  options.headers={...(options.headers||{})};
  if(options.body)options.headers['Content-Type']='application/json;charset=utf-8';
  if(options.method&&options.method!=='GET'&&csrfToken)options.headers['X-PZ-CSRF']=csrfToken;
  const timeoutMs=Number(options.timeoutMs||15000);delete options.timeoutMs;
  const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),timeoutMs);
  if(!options.signal)options.signal=controller.signal;
  let response;
  try{response=await fetch(path,options)}catch(error){if(error.name==='AbortError')throw new Error('面板请求超时，请刷新页面后重试。');throw error}finally{clearTimeout(timeout)}
  let data;
  try{data=await response.json()}catch{throw new Error(`HTTP ${response.status}`)}
  if(response.status===401&&path!=='/api/auth/login'){showAuth();throw new Error(data.error||'请先登录。')}
  if(!response.ok||!data.ok)throw new Error(data.error||`HTTP ${response.status}`);
  return data;
};
const currentServer=()=>lastStatus?.servers?.find(server=>server.id===selectedId)||null;
const toast=(message,error=false)=>{const el=document.querySelector('#toast');el.textContent=message;el.className=`toast show${error?' error':''}`;clearTimeout(el.timer);el.timer=setTimeout(()=>el.className='toast',3600)};
const escapeHtml=value=>String(value).replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));

const itemInput=document.querySelector('#itemSearch'),itemResults=document.querySelector('#itemResults'),itemSearchStatus=document.querySelector('#itemSearchStatus');
const itemIndexStatus=document.querySelector('#itemIndexStatus'),itemIndexProgress=document.querySelector('#itemIndexProgress');
const formatDate=value=>value?new Date(value).toLocaleString('zh-CN',{hour12:false}):'--';
function itemProgress(data){
  if(!data.building)return data.cacheAvailable||data.ready?100:0;
  if(data.phase==='starting')return 5;if(data.phase==='translations')return 15;if(data.phase==='vanilla')return 35;if(data.phase==='workshop')return 50;
  if(data.phase==='mods'&&data.total)return Math.min(90,50+Math.round(Number(data.current||0)/Number(data.total)*40));
  if(data.phase==='mods')return 65;if(data.phase==='finalizing')return 95;return 8;
}
function renderItemIndexStatus(data={}){
  itemIndexSnapshot=data;const stats=data.stats||{},building=Boolean(data.building),available=Boolean(data.cacheAvailable||data.ready),failed=Boolean(data.error);
  const elapsed=building&&data.startedAt?` · 已扫描 ${Math.max(0,Math.round((Date.now()-new Date(data.startedAt))/1000))} 秒`:'';
  const state=failed?(available?'warning':'error'):building?'building':available?'ready':'empty';
  itemIndexStatus.dataset.state=state;itemIndexProgress.value=itemProgress(data);
  document.querySelector('#itemIndexState').textContent=failed?(available?'更新失败，旧缓存仍可用':'物品扫描失败'):building?(available?'正在更新物品索引':'正在首次扫描物品'):available?'物品缓存可用':'尚未生成物品缓存';
  document.querySelector('#itemIndexPhase').textContent=failed?'点击“重新扫描”重试':building?`${data.phaseLabel||'正在后台扫描'}${elapsed}`:'扫描已完成，可直接搜索并重复使用缓存';
  document.querySelector('#itemIndexCount').textContent=available?Number(data.count||0).toLocaleString('zh-CN'):'--';
  document.querySelector('#itemIndexChinese').textContent=available?Number(stats.chineseNames||0).toLocaleString('zh-CN'):'--';
  document.querySelector('#itemIndexMods').textContent=available?`${stats.matchedMods||0}/${stats.enabledMods||0}`:'--';
  document.querySelector('#itemIndexGenerated').textContent=`缓存时间 ${formatDate(data.generatedAt)}`;
}
function itemStatusText(data){
  if(data.error&&!data.cacheAvailable)return'物品索引生成失败，请点击刷新重试。';
  if(data.error&&data.cacheAvailable)return`重新扫描失败，上次缓存仍可用 · ${data.count||0} 项 · ${formatDate(data.generatedAt)}`;
  if(data.building){
    const elapsed=data.startedAt?` · 已用 ${Math.max(0,Math.round((Date.now()-new Date(data.startedAt))/1000))} 秒`:'';
    const cache=data.cacheAvailable?`上次缓存仍可用，共 ${data.count||0} 项。`:'首次扫描，完成前仍可手工输入完整 ID。';
    return `${data.phaseLabel||'正在后台扫描物品'}${elapsed} · ${cache}`;
  }
  if(data.cacheAvailable){const stats=data.stats||{};return `缓存可用 · ${data.count||0} 项 · 中文名称 ${stats.chineseNames||0} · Mod ${stats.matchedMods||0}/${stats.enabledMods||0} · ${formatDate(data.generatedAt)}`}
  return'尚无物品缓存，正在准备首次扫描。';
}
async function refreshItemStatus(schedule=true){
  clearTimeout(itemPollTimer);if(!selectedId)return;
  const requestServer=selectedId,serial=++itemRequestSerial;
  try{const data=await api(`/api/items/status?serverId=${encodeURIComponent(requestServer)}`);if(serial!==itemRequestSerial||requestServer!==selectedId)return;renderItemIndexStatus(data);itemSearchStatus.textContent=itemStatusText(data);if(data.building&&schedule)itemPollTimer=setTimeout(()=>refreshItemStatus(true),1500)}catch(error){if(requestServer===selectedId){renderItemIndexStatus({error:error.message});itemSearchStatus.textContent=error.message}}
}
function closeItemResults(){itemResults.hidden=true;itemInput.setAttribute('aria-expanded','false')}
function selectItemOption(option){if(!option)return;itemInput.value=option.dataset.itemId;itemSearchStatus.textContent=`已选择 ${option.dataset.itemName} · ${option.dataset.itemId}`;closeItemResults()}
function renderItemResults(items){
  itemResults.innerHTML=items.length?items.map(item=>{const name=item.nameZh||item.nameEn||item.id,source=item.source==='mod'?(item.modId||'Mod'):'本体';return `<button class="item-result" type="button" role="option" data-item-id="${escapeHtml(item.id)}" data-item-name="${escapeHtml(name)}"><strong>${escapeHtml(name)}</strong><code>${escapeHtml(item.id)}</code><b class="capability ${item.source==='mod'?'client':'available'}">${escapeHtml(source)}</b></button>`}).join(''):'<p class="empty-state compact">没有匹配物品，可继续手工输入完整 ID。</p>';
  itemResults.hidden=false;itemInput.setAttribute('aria-expanded','true');
}
async function searchItems(query=itemInput.value.trim()){
  clearTimeout(itemPollTimer);
  if(!selectedId||!query){closeItemResults();itemSearchStatus.textContent='输入中文名称或完整物品 ID 搜索';return}
  const requestServer=selectedId,serial=++itemRequestSerial;
  itemSearchStatus.textContent='正在搜索物品...';
  try{
    const data=await api(`/api/items?serverId=${encodeURIComponent(requestServer)}&q=${encodeURIComponent(query)}&limit=40`);
    if(serial!==itemRequestSerial||requestServer!==selectedId||query!==itemInput.value.trim())return;
    if(!data.ready){
      closeItemResults();
      renderItemIndexStatus(data);
      itemSearchStatus.textContent=data.error?'物品索引生成失败，请点击刷新重试。':'首次使用，正在后台扫描本体和启用 Mod...';
      if(data.building)itemPollTimer=setTimeout(()=>searchItems(query),1200);
      return;
    }
    renderItemIndexStatus({...data,cacheAvailable:true});
    itemSearchStatus.textContent=`缓存 ${data.count} 项${data.refreshing?'（后台正在更新）':''}${data.gameVersion?` · 游戏 ${data.gameVersion}`:''} · 显示 ${data.items.length} 条匹配`;
    renderItemResults(data.items);
  }catch(error){closeItemResults();itemSearchStatus.textContent=error.message}
}
itemInput.addEventListener('input',()=>{clearTimeout(itemSearchTimer);clearTimeout(itemPollTimer);itemRequestSerial+=1;itemSearchTimer=setTimeout(()=>searchItems(),250)});
itemInput.addEventListener('focus',()=>{if(itemInput.value.trim())searchItems()});
itemInput.addEventListener('blur',()=>setTimeout(closeItemResults,160));
itemInput.addEventListener('keydown',event=>{if(event.key==='Escape'){closeItemResults();return}if(event.key==='ArrowDown'&&!itemResults.hidden){event.preventDefault();itemResults.querySelector('[data-item-id]')?.focus();return}if(event.key==='Enter'&&!itemResults.hidden){const first=itemResults.querySelector('[data-item-id]');if(first){event.preventDefault();selectItemOption(first)}}});
itemResults.addEventListener('mousedown',event=>{const option=event.target.closest('[data-item-id]');if(!option)return;event.preventDefault();selectItemOption(option)});
async function rebuildItems(){try{const data=await api('/api/items/rebuild',{method:'POST',body:JSON.stringify({serverId:selectedId})});toast(data.message);renderItemIndexStatus({...itemIndexSnapshot,building:true,refreshing:Boolean(itemIndexSnapshot?.cacheAvailable),phase:'starting',phaseLabel:'准备扫描',startedAt:new Date().toISOString()});itemSearchStatus.textContent='正在后台重新扫描物品，上次缓存继续可用...';document.querySelector('#itemCatalogSummary').textContent='正在后台重新扫描物品，当前缓存仍可浏览';clearTimeout(itemPollTimer);itemPollTimer=setTimeout(()=>refreshItemStatus(true),800)}catch(error){toast(error.message,true)}}
document.querySelector('#rebuildItemIndex').onclick=rebuildItems;

const catalogSearch=document.querySelector('#itemCatalogSearch'),catalogCategory=document.querySelector('#itemCatalogCategory'),catalogSource=document.querySelector('#itemCatalogSource'),catalogMod=document.querySelector('#itemCatalogMod');
function catalogSourceLabel(item){return item.source==='mod'?(item.modId||'启用 Mod'):'游戏本体'}
function itemGrantTargetMarkup(){return `<div class="item-target-picker"><span class="item-target-label">发放对象</span><div class="item-target-modes"><label><input type="radio" name="targetMode" value="single" checked><span>单个玩家</span></label><label><input type="radio" name="targetMode" value="selected"><span>选择部分</span></label><label><input type="radio" name="targetMode" value="all-online"><span>全部在线</span></label></div><label class="item-target-single">在线玩家<select class="online-player-select" name="username" required><option value="">正在读取在线玩家...</option></select></label><div class="item-target-selected" hidden><div class="item-target-actions"><span>勾选在线玩家</span><div><button type="button" data-item-target-action="all">全选</button><button type="button" data-item-target-action="clear">清空</button></div></div><div class="item-target-checklist"></div></div><p class="item-target-summary">正在读取在线玩家...</p></div>`}
function itemGrantNotificationMarkup(){return `<div class="item-grant-notification"><label>发放后通知<select name="notificationChannel"><option value="none">不发送通知</option><option value="native">文字全服广播</option><option value="popup">Mod 右下角弹窗</option><option value="both">文字广播 + Mod 弹窗</option></select></label><div class="item-grant-notification-fields" hidden><label>通知内容<textarea name="notificationMessage" maxlength="1200" rows="3" placeholder="留空时自动生成物品发放通知"></textarea></label><label class="item-notice-duration" hidden>弹窗时长（秒）<input name="notificationDuration" type="number" min="3" max="300" value="10"></label><p class="item-notification-hint">通知发送给当前全服在线玩家。</p></div></div>`}
function renderCatalogFacets(data){
  const categoryValue=catalogCategory.value,modValue=catalogMod.value;
  catalogCategory.innerHTML='<option value="">全部分类</option>'+data.categories.map(value=>`<option value="${escapeHtml(value)}">${escapeHtml(value)}</option>`).join('');
  catalogMod.innerHTML='<option value="">全部 Mod</option>'+data.mods.map(value=>`<option value="${escapeHtml(value)}">${escapeHtml(value)}</option>`).join('');
  if(data.categories.includes(categoryValue))catalogCategory.value=categoryValue;
  if(data.mods.includes(modValue))catalogMod.value=modValue;
}
function renderCatalogDetail(item){
  const detail=document.querySelector('#itemCatalogDetail');itemCatalogSelected=item||null;
  if(!item){detail.innerHTML='<div class="item-detail-empty"><i data-lucide="package-search"></i><strong>选择一件物品查看资料</strong><span>列表采用分页加载，不会一次载入全部物品。</span></div>';lucide.createIcons();return}
  const name=item.nameZh||item.nameEn||item.id,english=item.nameEn&&item.nameEn!==name?item.nameEn:'--';
  detail.innerHTML=`<div class="item-detail-title"><span class="item-detail-icon"><i data-lucide="package"></i></span><div><p>${escapeHtml(item.category||'其他')}</p><h3>${escapeHtml(name)}</h3><code>${escapeHtml(item.id)}</code></div></div><dl class="item-detail-data"><div><dt>中文名称</dt><dd>${escapeHtml(item.nameZh||'未提供中文翻译')}</dd></div><div><dt>英文名称</dt><dd>${escapeHtml(english)}</dd></div><div><dt>管理分类</dt><dd>${escapeHtml(item.category||'其他')}</dd></div><div><dt>原始分类</dt><dd>${escapeHtml(item.displayCategory||'未记录')}</dd></div><div><dt>物品类型</dt><dd>${escapeHtml(item.itemType||'未记录')}</dd></div><div><dt>来源</dt><dd>${escapeHtml(catalogSourceLabel(item))}</dd></div>${item.workshopId?`<div><dt>Workshop ID</dt><dd><code>${escapeHtml(item.workshopId)}</code></dd></div>`:''}</dl><form id="catalogGrantForm" class="catalog-grant-form command-control">${itemGrantTargetMarkup()}<label>数量<input name="count" type="number" min="1" max="100" value="1" required></label>${itemGrantNotificationMarkup()}<button class="primary-button" type="submit"><i data-lucide="package-plus"></i>发放此物品</button></form>`;
  renderOnlinePlayerSelects();updateItemGrantNotificationState(detail.querySelector('#catalogGrantForm'));lucide.createIcons();
}
function renderItemCatalog(data){
  itemCatalogSnapshot=data;renderCatalogFacets(data);
  const rows=document.querySelector('#itemCatalogRows');
  rows.innerHTML=data.items.length?data.items.map(item=>{const name=item.nameZh||item.nameEn||item.id;return`<button class="item-catalog-row${itemCatalogSelected?.id===item.id?' selected':''}" type="button" data-catalog-id="${escapeHtml(item.id)}"><span><strong>${escapeHtml(name)}</strong><small>${escapeHtml(item.nameEn&&item.nameEn!==name?item.nameEn:'')}</small><code>${escapeHtml(item.id)}</code></span><b>${escapeHtml(item.category||'其他')}</b><em class="capability ${item.source==='mod'?'client':'available'}">${escapeHtml(catalogSourceLabel(item))}</em></button>`}).join(''):'<p class="empty-state">当前筛选条件没有匹配物品。</p>';
  document.querySelector('#itemCatalogSummary').textContent=`找到 ${Number(data.total).toLocaleString('zh-CN')} 项 · 缓存共 ${Number(data.count).toLocaleString('zh-CN')} 项 · ${formatDate(data.generatedAt)}`;
  document.querySelector('#itemCatalogPage').textContent=data.pages?`第 ${data.page} / ${data.pages} 页`:'没有结果';
  document.querySelector('#itemCatalogPrev').disabled=data.page<=1;document.querySelector('#itemCatalogNext').disabled=!data.pages||data.page>=data.pages;
  rows.querySelectorAll('[data-catalog-id]').forEach(row=>row.onclick=()=>{const item=data.items.find(value=>value.id===row.dataset.catalogId);rows.querySelectorAll('.item-catalog-row').forEach(value=>value.classList.toggle('selected',value===row));renderCatalogDetail(item)});
  if(itemCatalogSelected){const current=data.items.find(value=>value.id===itemCatalogSelected.id);if(current)renderCatalogDetail(current)}
}
async function refreshItemCatalog(page=itemCatalogPage){
  if(!selectedId)return;const requestServer=selectedId,serial=++itemCatalogSerial;
  document.querySelector('#itemCatalogSummary').textContent='正在读取物品目录...';
  const params=new URLSearchParams({serverId:requestServer,page:String(page),pageSize:'60',q:catalogSearch.value.trim(),category:catalogCategory.value,source:catalogSource.value,mod:catalogMod.value});
  try{const data=await api(`/api/items/catalog?${params}`);if(serial!==itemCatalogSerial||requestServer!==selectedId)return;if(!data.ready){document.querySelector('#itemCatalogSummary').textContent='物品缓存正在生成，完成后自动显示';setTimeout(()=>activeView==='items'&&refreshItemCatalog(page),1500);return}itemCatalogPage=data.page;renderItemCatalog(data)}catch(error){document.querySelector('#itemCatalogSummary').textContent=error.message;document.querySelector('#itemCatalogRows').innerHTML=`<p class="empty-state error-text">${escapeHtml(error.message)}</p>`}
}
function resetItemCatalog(){itemCatalogSerial+=1;itemCatalogPage=1;itemCatalogSnapshot=null;itemCatalogSelected=null;renderCatalogDetail(null);document.querySelector('#itemCatalogRows').innerHTML='<p class="empty-state">正在读取物品目录...</p>';document.querySelector('#itemCatalogSummary').textContent='正在读取物品缓存...'}
catalogSearch.addEventListener('input',()=>{clearTimeout(itemCatalogTimer);itemCatalogTimer=setTimeout(()=>{itemCatalogPage=1;refreshItemCatalog(1)},300)});
[catalogCategory,catalogSource,catalogMod].forEach(control=>control.onchange=()=>{itemCatalogPage=1;refreshItemCatalog(1)});
document.querySelector('#itemCatalogPrev').onclick=()=>refreshItemCatalog(Math.max(1,itemCatalogPage-1));
document.querySelector('#itemCatalogNext').onclick=()=>refreshItemCatalog(itemCatalogPage+1);
document.querySelector('#catalogRebuild').onclick=rebuildItems;
document.querySelector('#itemCatalogDetail').addEventListener('submit',event=>{if(event.target.id!=='catalogGrantForm')return;event.preventDefault();submitItemGrant(event.target,itemCatalogSelected.id)});

function showView(name){
  if(name==='users'&&!authSession?.local)return;
  activeView=name;
  document.querySelectorAll('.view').forEach(view=>view.classList.toggle('active',view.id===`view-${name}`));
  document.querySelectorAll('[data-view]').forEach(button=>button.classList.toggle('active',button.dataset.view===name));
  document.querySelector('#pageTitle').textContent=titles[name];
  if(name==='maintenance'){refreshAudit();refreshLifecycleStatus();refreshSaveBackupPlan();refreshMaintenanceSchedule();refreshProgramUpdateStatus();refreshExecutionHistory()}
  if(name==='map-reset')refreshMapReset(true);
  if(name==='profiles')refreshProfiles();
  if(['chat','players','items','commands','world'].includes(name))refreshPlayers();
  if(name==='chat'){pollChat();refreshNoticeStatus();refreshBroadcastSchedules()}
  if(name==='items')refreshItemCatalog();
  if(name==='system')pollSystem();
  if(name==='users')refreshUsers();
  if(name==='ai')refreshAIPage();
  if(name==='overview'||name==='console')pollLog();
}
document.querySelectorAll('[data-view]').forEach(button=>button.onclick=()=>showView(button.dataset.view));
document.querySelectorAll('[data-go]').forEach(button=>button.onclick=()=>showView(button.dataset.go));

function duration(iso){
  if(!iso)return'--';
  const total=Math.max(0,(Date.now()-new Date(iso))/1000),days=Math.floor(total/86400),hours=Math.floor(total%86400/3600),minutes=Math.floor(total%3600/60);
  return days?`${days}天 ${hours}时`:`${hours}时 ${minutes}分`;
}
function renderServerStrip(){
  const strip=document.querySelector('#serverStrip');
  strip.innerHTML=lastStatus.servers.map(server=>{const starting=server.status==='waiting-startup-lock'||server.status==='starting',statusText=server.status==='waiting-startup-lock'?'排队启动':server.status==='starting'?'初始化中':server.alive?'运行中':'已停止';return`<button class="server-row ${server.id===selectedId?'selected':''} ${server.commandChannel==='readonly'?'readonly':''}" type="button" data-server-id="${escapeHtml(server.id)}"><span class="server-icon ${server.kind==='production'?'prod':'test'}"><i data-lucide="${server.kind==='production'?'server':'flask-conical'}"></i></span><span class="server-copy"><strong>${escapeHtml(server.name)}</strong><small>${escapeHtml(server.lanAddress||'未配置地址')} · ${server.commandChannel==='readonly'?'只读':'受控命令'}</small></span><span class="badge ${server.alive||starting?'running':'stopped'}">${statusText}</span></button>`}).join('');
  strip.querySelectorAll('[data-server-id]').forEach(button=>button.onclick=()=>selectServer(button.dataset.serverId));
  lucide.createIcons();
}
function renderPicker(){
  const select=document.querySelector('#serverSelect');
  select.innerHTML=lastStatus.servers.map(server=>`<option value="${escapeHtml(server.id)}">${escapeHtml(server.name)}${server.commandChannel==='readonly'?'（只读）':''}</option>`).join('');
  select.value=selectedId;
}
function renderCurrentServer(){
  const server=currentServer();
  if(!server)return;
  const servers=lastStatus?.servers||[],runningServers=servers.filter(item=>item.alive),pendingOnlineServers=runningServers.filter(item=>!item.onlineKnown),knownOnlineTotal=runningServers.filter(item=>item.onlineKnown).reduce((total,item)=>total+(Number(item.onlineCount)||0),0),currentOnline=server.alive?(server.onlineKnown?Number(server.onlineCount)||0:'同步中'):0;
  const jvm=server.jvmMemory||{},memoryText=value=>value==null?'--':`${(Number(value)/1073741824).toFixed(1)} GB`;
  document.querySelector('#targetEyebrow').textContent=`当前目标 · ${server.name}`;
  document.querySelector('#onlineCount').textContent=pendingOnlineServers.length?(knownOnlineTotal?`≥ ${knownOnlineTotal}`:'同步中'):knownOnlineTotal;
  document.querySelector('#playerLimit').textContent=`当前服 ${currentOnline} / ${server.maxPlayers||'--'} · ${runningServers.length}/${servers.length}服运行${pendingOnlineServers.length?` · ${pendingOnlineServers.length}服待同步`:''}`;
  document.querySelector('#memoryUsage').textContent=server.alive?`${(server.memoryMB/1024).toFixed(1)} GB`:'--';
  document.querySelector('#memoryPeak').textContent=server.alive?`Windows 工作集 · 峰值 ${(server.memoryPeakMB/1024).toFixed(1)} GB`:'Windows 工作集峰值 --';
  document.querySelector('#jvmHeapUsage').textContent=jvm.available?memoryText(jvm.currentUsedBytes):'--';
  document.querySelector('#jvmHeapLimit').textContent=jvm.available?`最近 GC 后 · 上限 ${memoryText(jvm.maxBytes)}`:(jvm.reason||'JVM 堆数据不可用');
  document.querySelector('#jvmHeapPeak').textContent=jvm.available?memoryText(jvm.peakUsedBytes):'--';
  document.querySelector('#jvmHeapSample').textContent=jvm.available?`本次运行峰值 · ${jvm.lastGcAt?formatDate(jvm.lastGcAt):'等待更新时间'}`:(jvm.maxBytes?`已配置上限 ${memoryText(jvm.maxBytes)}`:'等待 GC 采样');
  document.querySelector('#uptime').textContent=server.alive?duration(server.startedAt):'--';
  document.querySelector('#javaPid').textContent=server.javaPid?`PID ${server.javaPid}`:'PID --';
  document.querySelector('#ports').textContent=server.ports?.length?server.ports.join(' / '):'--';
  if(!playerDirectory)document.querySelector('#playerSummary').textContent=server.onlineText||'尚未获取在线玩家列表。执行“在线玩家”查询后，结果会进入日志。';
  const notice=document.querySelector('#readonlyNotice');
  notice.hidden=server.writable;
  notice.querySelector('span').textContent=server.note;
  document.querySelectorAll('.command-control button:not([data-go]):not(.item-lookup-control):not(.item-result):not(#startServer):not(#stopServer):not(#restartServer):not([data-notice-control]),.command-control input:not(.item-lookup-control):not([data-notice-control]),.command-control textarea:not([data-notice-control]),.command-control select:not([data-notice-control]),button.command-control:not([data-go]):not(.item-lookup-control):not(.item-result):not(#startServer):not(#stopServer):not(#restartServer):not([data-notice-control])').forEach(control=>control.disabled=!server.writable||control.dataset.alwaysDisabled==='true'||control.dataset.onlineEmpty==='true');
  const start=document.querySelector('#startServer'),stop=document.querySelector('#stopServer'),restart=document.querySelector('#restartServer');
  const lifecycleBusy=lifecycleOperation?.serverId===server.id&&['queued','running'].includes(lifecycleOperation.status);
  start.disabled=lifecycleBusy||!server.canStart||server.alive;
  start.title=server.startReason||'';
  stop.disabled=lifecycleBusy||!server.canStop||!server.alive;
  restart.disabled=lifecycleBusy||!server.canRestart||!server.alive;
  if(playerAdminSnapshot)renderPlayerAdmin();
  updateChatMode();
}
function selectServer(id){
  if(id===selectedId&&currentServer())return;
  closeAdminSetupDialog();
  selectedId=id;localStorage.setItem('pz-server',id);cursor=0;logLines=[];chatCursor=0;chatFile='';chatMessages=[];chatFollowLatest=true;worldgenSerial+=1;commandResultSerial+=1;lifecycleSerial+=1;noticeSerial+=1;playerRequestSerial+=1;playerAdminSerial+=1;mapResetSerial+=1;clearTimeout(mapResetPollTimer);mapResetSnapshot=null;mapResetServerId='';playerAdminBusy=false;playerAdminSnapshot=null;playersBusy=false;playerRequestServer='';noticeStatusServer='';noticeChannel=null;noticeLastCheckedAt=0;noticeStatusError='';lifecycleOperation=null;executionHistory=[];executionHistoryPage=1;executionHistoryTotal=0;executionHistoryTotalPages=1;document.querySelector('#commandResultTray').hidden=true;renderChat(true);renderWorldgenResult('idle','尚未执行查询','已切换服务器，请重新执行世界生成查询','请选择操作并执行。');playerDirectory=null;document.querySelector('#playerSummary').textContent='正在读取在线玩家...';document.querySelector('#playerTable').innerHTML='<p class="empty-state">正在读取所选服务器玩家列表...</p>';document.querySelector('#playerAdminLookupForm').reset();renderPlayerAdmin();renderOnlinePlayerSelects();itemIndexSnapshot=null;renderItemIndexStatus({});itemRequestSerial+=1;clearTimeout(itemSearchTimer);clearTimeout(itemPollTimer);clearTimeout(itemCatalogTimer);resetItemCatalog();closeItemResults();itemSearchStatus.textContent='正在读取物品缓存状态...';
  document.querySelector('#logOutput').textContent='正在读取所选服务器日志...';
  renderPicker();renderServerStrip();renderCurrentServer();pollLog();if(activeView==='chat'){pollChat();refreshNoticeStatus(true);refreshBroadcastSchedules()}if(activeView==='maintenance'){refreshLifecycleStatus();refreshSaveBackupPlan();refreshMaintenanceSchedule();refreshProgramUpdateStatus();refreshExecutionHistory()}if(activeView==='map-reset')refreshMapReset(true);refreshPlayers();refreshItemStatus();if(activeView==='items')refreshItemCatalog();
}
async function refreshStatus(){
  if(statusBusy)return;statusBusy=true;
  try{
    const data=await api('/api/status');lastStatus=data;
    if(!data.servers.some(server=>server.id===selectedId))selectedId=data.defaultServer||data.servers[0]?.id||'';
    localStorage.setItem('pz-server',selectedId);renderPicker();renderServerStrip();renderCurrentServer();if(activeView==='maintenance'){if(!document.querySelector('#saveBackupPlanForm:focus-within'))refreshSaveBackupPlan();if(!document.querySelector('#maintenanceScheduleForm:focus-within'))refreshMaintenanceSchedule()}if(activeView==='map-reset'&&mapResetSnapshot)renderMapReset(mapResetSnapshot,false);if(activeView==='ai'&&!aiPolicyForm.elements.serverId.options.length){const policy=aiPolicies.find(item=>item.id===aiPolicyForm.elements.id.value);fillAIPolicy(policy||null);renderAIPolicies()}
    const server=currentServer(),knownOnline=(playerDirectory?.players||[]).filter(player=>player.online).length;
    if(server&&['chat','players','items','commands','world'].includes(activeView)&&(!playerDirectory||Number(server.onlineCount)!==knownOnline||Date.now()-lastPlayersRefreshAt>10000))refreshPlayers();
    document.querySelector('#serverClock').textContent=new Date(data.serverTime).toLocaleTimeString('zh-CN',{hour12:false});
    document.querySelector('#connectionDot').className='status-dot ok';document.querySelector('#connectionText').textContent='面板连接正常';
  }catch(error){
    document.querySelector('#connectionDot').className='status-dot';document.querySelector('#connectionText').textContent='面板连接失败';
    console.error(error);
  }finally{statusBusy=false}
}
document.querySelector('#serverSelect').onchange=event=>selectServer(event.target.value);

function classify(line){if(line.includes('[PZCompatTrace]'))return'compat';if(line.startsWith('ERROR:')||line.includes('Exception thrown'))return'error';if(line.startsWith('WARN'))return'warn';if(line.includes('Network')||/connect|disconnect|checksum/i.test(line))return'network';return'general'}
function renderActivity(){
  const feed=document.querySelector('#activityFeed'),important=logLines.filter(line=>['error','warn','network','compat'].includes(classify(line))).slice(-12).reverse();
  if(!important.length){feed.innerHTML='<p class="empty-state">等待服务器事件</p>';return}
  feed.innerHTML=important.map(line=>{const kind=classify(line),time=(line.match(/\d\d:\d\d:\d\d/)||['--:--:--'])[0],clean=line.replace(/^.*?>\s*/,'').slice(0,220);return `<div class="activity-item ${kind}"><time>${time}</time><span class="kind">${kind.toUpperCase()}</span><span>${escapeHtml(clean)}</span></div>`}).join('');
}
function renderLog(){const visible=filter==='all'?logLines:logLines.filter(line=>classify(line)===filter),output=document.querySelector('#logOutput');output.textContent=visible.join('\n')||'当前筛选条件没有日志。';if(!paused){const box=output.parentElement;box.scrollTop=box.scrollHeight}renderActivity()}
async function pollLog(){
  if(paused||logBusy||!selectedId||!['overview','console'].includes(activeView))return;logBusy=true;const requestServer=selectedId;
  try{const data=await api(`/api/log?serverId=${encodeURIComponent(requestServer)}&after=${cursor}`);if(data.serverId!==selectedId)return;cursor=data.cursor;if(data.text){const incoming=data.text.replace(/\r/g,'').split('\n').filter(Boolean);logLines=data.reset?incoming:[...logLines,...incoming];if(logLines.length>6000)logLines=logLines.slice(-6000);renderLog()}}catch{}finally{logBusy=false}
}
const chatChannelLabels={General:'全服',Local:'附近',Whisper:'私聊',Faction:'阵营',Safehouse:'安全屋',Broadcast:'服务器广播',Admin:'管理员'};
function renderChat(forceLatest=false){
  const surface=document.querySelector('#chatSurface'),container=document.querySelector('#chatMessages'),previousTop=surface.scrollTop,followLatest=forceLatest||chatFollowLatest;
  const visible=chatFilter==='all'?chatMessages:chatMessages.filter(message=>message.channel===chatFilter);
  container.innerHTML=visible.length?visible.map(message=>`<article class="chat-message channel-${escapeHtml(message.channel.toLowerCase())}"><div class="chat-message-meta"><span>${escapeHtml(chatChannelLabels[message.channel]||message.channel)}</span><strong>${escapeHtml(message.author||'服务器')}</strong><time>${escapeHtml(message.timestamp||'')}</time></div><p>${escapeHtml(message.text)}</p></article>`).join(''):'<p class="empty-state">当前频道还没有聊天记录。</p>';
  if(followLatest){surface.scrollTop=surface.scrollHeight;chatFollowLatest=true}
  else surface.scrollTop=Math.min(previousTop,Math.max(0,surface.scrollHeight-surface.clientHeight));
}
const chatSurface=document.querySelector('#chatSurface');
chatSurface.addEventListener('scroll',()=>{chatFollowLatest=chatSurface.scrollHeight-chatSurface.scrollTop-chatSurface.clientHeight<=32},{passive:true});
async function pollChat(force=false){
  if(chatBusy||!selectedId||activeView!=='chat')return;
  if(force){chatCursor=0;chatFile='';chatMessages=[];chatFollowLatest=true;renderChat(true)}
  chatBusy=true;const requestServer=selectedId;
  try{
    const params=new URLSearchParams({serverId:requestServer,after:String(chatCursor)});if(chatFile)params.set('file',chatFile);
    const data=await api(`/api/chat?${params}`);if(data.serverId!==selectedId)return;
    chatCursor=Number(data.cursor)||0;chatFile=data.fileId||'';
    let changed=Boolean(data.reset);if(data.reset)chatMessages=[];
    const known=new Set(chatMessages.map(message=>message.id));for(const message of data.messages||[]){if(!known.has(message.id)){known.add(message.id);chatMessages.push(message);changed=true}}
    if(chatMessages.length>1000){chatMessages=chatMessages.slice(-1000);changed=true}
    if(changed)renderChat(Boolean(data.reset));document.querySelector('#chatStatusDot').className=`status-dot${data.available?' ok':''}`;
    document.querySelector('#chatStatus').textContent=data.available?`聊天日志已连接 · ${data.fileId} · 最近更新 ${formatDate(data.updatedAt)}`:'当前服务器还没有聊天日志，玩家发言后会自动出现。';
  }catch(error){document.querySelector('#chatStatusDot').className='status-dot';document.querySelector('#chatStatus').textContent=error.message}finally{chatBusy=false}
}
document.querySelectorAll('#chatFilters button').forEach(button=>button.onclick=()=>{document.querySelectorAll('#chatFilters button').forEach(item=>item.classList.remove('active'));button.classList.add('active');chatFilter=button.dataset.chatFilter;chatFollowLatest=true;renderChat(true)});
document.querySelector('#refreshChat').onclick=()=>{pollChat(true);refreshNoticeStatus(true)};
function renderNoticeStatus(channel=noticeChannel){
  const dot=document.querySelector('#noticeStatusDot'),status=document.querySelector('#noticeStatus');
  const channelStatus=channel?.status||(channel?.active?'online':channel?.stale?'stale':'offline');
  dot.className=`status-dot${channelStatus==='online'?' ok':channelStatus==='offline'?' error':''}`;
  if(!channel){status.textContent='正在检查当前服务器的通知 Mod 通道';return}
  if(!channel.installed){status.textContent='本机未找到 PZWebNotices Mod，请先安装后再启用';return}
  const age=channel.ageSeconds==null?'刚刚':`${Number(channel.ageSeconds).toFixed(1)} 秒前`;
  if(channel.v3Compatible===false){status.textContent=`Mod 心跳已收到，但 v${channel.version||'未知'} 过旧；Web 发送需要 0.2.3 或更高版本`;return}
  if(noticeStatusError){status.textContent=`状态刷新失败，沿用上次状态 · ${noticeStatusError}`;return}
  if(channelStatus==='stale'){status.textContent=`Mod 心跳延迟 · ${age} · 服务器可能正在保存或负载较高，仍可发送并等待回执`;return}
  if(channelStatus==='missing'){status.textContent='尚未收到该服务器的 Mod 心跳；请确认已启用 PZWebNotices，首次启用后才需要重启服务器';return}
  if(channelStatus==='offline'){status.textContent=`Mod 已超过 5 分钟没有心跳（最后更新 ${age}），请检查服务器状态或 Mod 日志`;return}
  status.textContent=`Mod 通道在线 · v${channel.version||'未知'} · 心跳 ${age} · 客户端在线 ${channel.online??'未知'}`;
}
async function refreshNoticeStatus(force=false){
  if(!selectedId||noticeStatusBusy)return;
  if(!force&&noticeStatusServer===selectedId&&Date.now()-noticeLastCheckedAt<5000)return;
  const serverId=selectedId,serial=noticeSerial;noticeStatusBusy=true;noticeStatusServer=serverId;
  try{const data=await api(`/api/notices/status?serverId=${encodeURIComponent(serverId)}`);if(serial!==noticeSerial||serverId!==selectedId)return;noticeChannel=data.channel||null;noticeStatusError='';noticeLastCheckedAt=Date.now();renderNoticeStatus();updateChatMode();document.querySelectorAll('#grantForm,#catalogGrantForm').forEach(updateItemGrantNotificationState)}
  catch(error){if(serial===noticeSerial&&serverId===selectedId){noticeStatusError=error.message;noticeLastCheckedAt=Date.now();if(noticeChannel)renderNoticeStatus();else{document.querySelector('#noticeStatusDot').className='status-dot error';document.querySelector('#noticeStatus').textContent=`通知通道状态刷新失败 · ${error.message}`}updateChatMode();document.querySelectorAll('#grantForm,#catalogGrantForm').forEach(updateItemGrantNotificationState)}}
  finally{noticeStatusBusy=false;if(serial===noticeSerial&&serverId===selectedId)updateChatMode()}
}
function updateNoticePreview(){
  const style=document.querySelector('input[name="noticeStyle"]:checked')?.value||'info',title=document.querySelector('#noticeTitle').value.trim(),message=document.querySelector('#chatMessage').value.trim(),titleSize=document.querySelector('#noticeTitleSize').value,bodySize=document.querySelector('#noticeBodySize').value,accentColor=document.querySelector('#noticeAccentColor').value,textColor=document.querySelector('#noticeTextColor').value,preview=document.querySelector('#noticePreview');
  document.querySelectorAll('[data-notice-style]').forEach(label=>label.classList.toggle('selected',label.dataset.noticeStyle===style));
  preview.dataset.style=style;preview.dataset.titleSize=titleSize;preview.dataset.bodySize=bodySize;preview.style.borderLeftColor=accentColor;document.querySelector('#noticePreviewTitle').style.color=accentColor;document.querySelector('#noticePreviewMessage').style.color=textColor;document.querySelector('#noticePreviewTitle').textContent=title||'服务器通知';document.querySelector('#noticePreviewMessage').textContent=message||'通知正文会在这里预览。';
}
function updateChatMode(){
  const mode=document.querySelector('#chatSendMode').value,privateMode=mode==='private',noticeMode=mode==='notice',recipient=document.querySelector('#chatRecipientField'),fields=document.querySelector('#noticeFields'),message=document.querySelector('#chatMessage'),button=document.querySelector('#chatSendButton'),hint=document.querySelector('#chatComposeHint'),server=currentServer(),targetType=document.querySelector('#noticeTargetType').value,targeted=noticeMode&&targetType==='player',targetField=document.querySelector('#noticeTargetPlayerField'),targetPlayer=document.querySelector('#noticeTargetPlayer');
  recipient.hidden=!privateMode;fields.hidden=!noticeMode;targetField.hidden=!targeted;message.maxLength=noticeMode?4096:1200;
  message.placeholder=noticeMode?'输入右下角通知正文，支持换行；游戏内最多展示 5 行':privateMode?'输入私聊内容':'输入广播内容；换行和长句会自动拆成多条，避免游戏内文字溢出';
  if(privateMode){hint.textContent='PZ 原生服务端控制台没有私聊命令。选择器已准备好，但发送需要安装服务端 Lua 聊天桥接后才能启用。';button.innerHTML='<i data-lucide="lock-keyhole"></i>原生通道不支持私聊'}
  else if(noticeMode){hint.textContent=targeted?'通知只发送给选中的在线玩家，离线后 Mod 会拒绝并返回结果。':'通知发送给全部在线玩家；正文支持中文和换行，最多 4096 个 UTF-8 字节。';button.innerHTML='<i data-lucide="panel-bottom"></i>发送通知'}
  else{hint.textContent='每条最多 60 个字符；换行和长句会自动拆成多条，避免游戏内文字溢出。';button.innerHTML='<i data-lucide="send"></i>发送广播'}
  const noticeReady=Boolean(server?.alive&&(noticeChannel?.usable||noticeChannel?.active||noticeChannel?.stale)&&noticeChannel?.v3Compatible!==false),native=document.querySelector('#noticeNativeBroadcast');
  if((server&&!server.writable)||targeted)native.checked=false;
  document.querySelector('#chatSendMode').disabled=!server;
  document.querySelectorAll('#noticeFields [data-notice-control]:not(#refreshNoticeStatus):not(#noticeNativeBroadcast)').forEach(control=>control.disabled=!noticeReady);
  document.querySelector('#refreshNoticeStatus').disabled=!server||noticeStatusBusy;
  native.disabled=!noticeReady||!server?.writable||targeted;
  message.disabled=privateMode||(noticeMode?!noticeReady:!server?.writable);
  button.disabled=privateMode||(noticeMode?(!noticeReady||(targeted&&!targetPlayer.value)||(native.checked&&!server?.writable)):!server?.writable);
  updateNoticePreview();lucide.createIcons();
}
async function followNoticeReceipt(serverId,id,expectedClients,targetType,targetUsername,serial){
  for(let attempt=0;attempt<16;attempt+=1){
    await sleep(attempt?1000:350);if(serial!==noticeSerial||serverId!==selectedId)return;
    try{
      const data=await api(`/api/notices/receipt?serverId=${encodeURIComponent(serverId)}&id=${encodeURIComponent(id)}`);if(serial!==noticeSerial||serverId!==selectedId)return;
      if(data.status==='rejected'){renderCommandResult('error','通知被服务端 Mod 拒绝',`通知 ${id}`,data.error||'通知格式无效。');return}
      const expected=Number(data.expectedClients??expectedClients??0),acked=Number(data.acknowledgedClients||0),players=(data.acknowledgedPlayers||[]).join('、');
      if(data.status==='broadcast'||data.status==='directed'){
        const directed=data.status==='directed',target=data.targetUsername||targetUsername;
        if(expected===0){renderCommandResult('success','通知已由服务端广播',`通知 ${id} · 当前没有需要确认的在线客户端`,'服务端 Mod 已处理通知。');return}
        if(acked>=expected){renderCommandResult('success',directed?'指定玩家已确认通知':'通知已被全部在线客户端确认',`客户端确认 ${acked}/${expected}${directed&&target?` · ${target}`:''}`,players?`已确认：${players}`:directed?'目标玩家已显示通知。':'所有在线客户端已显示通知。');return}
        renderCommandResult('delivered',directed?'通知已发送给指定玩家':'通知已由服务端广播',`客户端确认 ${acked}/${expected}${directed&&target?` · ${target}`:''} · 已等待 ${attempt+1} 秒`,players?`已确认：${players}\n\n正在等待客户端确认...`:'正在等待客户端显示并确认...');
      }else renderCommandResult('queued','通知正在等待 Mod 读取',`通知 ${id} · 已等待 ${attempt+1} 秒`,'通知已写入受控 Mod 队列。');
    }catch(error){renderCommandResult('error','通知回执读取失败','无法继续查询 Mod 通道状态',error.message);return}
  }
  try{const data=await api(`/api/notices/receipt?serverId=${encodeURIComponent(serverId)}&id=${encodeURIComponent(id)}`),expected=Number(data.expectedClients??expectedClients??0),acked=Number(data.acknowledgedClients||0);renderCommandResult('warning','通知已广播，但客户端确认不完整',`客户端确认 ${acked}/${expected}`,`服务端已广播通知。未确认的玩家可能尚未加载或安装 PZWebNotices，也可能正在连接或退出。`)}catch{renderCommandResult('warning','通知确认等待超时',`通知 ${id}`,'请查看 Mod 通道状态和服务器日志。')}
}
async function sendNotice(){
  const serverId=selectedId,input=document.querySelector('#chatMessage'),message=input.value.trim(),title=document.querySelector('#noticeTitle').value.trim(),style=document.querySelector('input[name="noticeStyle"]:checked')?.value||'info',duration=Number(document.querySelector('#noticeDuration').value),targetType=document.querySelector('#noticeTargetType').value,targetUsername=document.querySelector('#noticeTargetPlayer').value,titleSize=document.querySelector('#noticeTitleSize').value,bodySize=document.querySelector('#noticeBodySize').value,accentColor=document.querySelector('#noticeAccentColor').value,textColor=document.querySelector('#noticeTextColor').value,nativeBroadcast=document.querySelector('#noticeNativeBroadcast').checked;
  if(!message||!title||(targetType==='player'&&!targetUsername))return;
  const messageBytes=new TextEncoder().encode(message).length;if(messageBytes>4096){const error=`通知正文当前为 ${messageBytes} 个 UTF-8 字节，最多允许 4096 个字节。`;renderCommandResult('error','通知正文过长','通知没有进入 Mod 队列',error);toast(error,true);return false}
  const serial=++noticeSerial;renderCommandResult('queued','右下角通知正在提交','正在写入 Mod 通知队列','等待面板接收通知...');
  try{const data=await api('/api/notices',{method:'POST',body:JSON.stringify({serverId,style,title,message,duration,targetType,targetUsername,titleSize,bodySize,accentColor,textColor,nativeBroadcast})});if(serial!==noticeSerial||serverId!==selectedId)return false;toast(data.message);input.value='';updateNoticePreview();const fallback=data.nativeBroadcastWarning?`\n\n原生广播未能附加发送：${data.nativeBroadcastWarning}`:nativeBroadcast?'\n\n已同时提交原生全服广播。':'',targetLabel=data.targetType==='player'?`指定玩家 ${data.targetUsername}`:'全部在线玩家';renderCommandResult(data.nativeBroadcastWarning?'warning':'queued','通知已进入 Mod 队列',`通知 ${data.id} · ${targetLabel} · 预计客户端 ${data.expectedClients}`,`正在等待服务端 Mod 处理...${fallback}`);followNoticeReceipt(serverId,data.id,data.expectedClients,data.targetType,data.targetUsername,serial);return data}catch(error){if(serial===noticeSerial)renderCommandResult('error','通知提交失败','通知没有进入 Mod 队列',error.message);toast(error.message,true);return false}
}
document.querySelector('#chatSendMode').onchange=()=>{updateChatMode();if(document.querySelector('#chatSendMode').value==='notice')refreshNoticeStatus(true)};
const noticeStyleColors={info:'#62a7df',success:'#4fc38a',warning:'#e3a846',danger:'#e56565'};
document.querySelectorAll('[data-notice-style]').forEach(label=>label.onclick=()=>{label.querySelector('input').checked=true;document.querySelector('#noticeAccentColor').value=noticeStyleColors[label.dataset.noticeStyle]||noticeStyleColors.info;updateNoticePreview()});
document.querySelector('#noticeTitle').addEventListener('input',updateNoticePreview);document.querySelector('#chatMessage').addEventListener('input',updateNoticePreview);document.querySelector('#noticeNativeBroadcast').addEventListener('change',updateChatMode);document.querySelector('#noticeTargetType').addEventListener('change',updateChatMode);document.querySelector('#noticeTargetPlayer').addEventListener('change',updateChatMode);['noticeTitleSize','noticeBodySize','noticeAccentColor','noticeTextColor'].forEach(id=>document.querySelector(`#${id}`).addEventListener('input',updateNoticePreview));
document.querySelector('#refreshNoticeStatus').onclick=()=>refreshNoticeStatus(true);
document.querySelector('#chatComposer').onsubmit=async event=>{event.preventDefault();const mode=document.querySelector('#chatSendMode').value,input=document.querySelector('#chatMessage'),message=input.value.trim();if(!message)return;if(mode==='notice'){await sendNotice();return}if(mode!=='broadcast')return;const result=await command({action:'broadcast',message});if(result){input.value='';updateNoticePreview();setTimeout(()=>pollChat(),900)}};

const broadcastScheduleForm=document.querySelector('#broadcastScheduleForm');
const broadcastChannelLabels={native:'原生广播',popup:'Mod 弹窗',both:'原生 + 弹窗'};
function fillBroadcastSchedule(schedule=null){
  broadcastScheduleForm.reset();broadcastScheduleForm.elements.id.value=schedule?.id||'';broadcastScheduleForm.elements.name.value=schedule?.name||'';broadcastScheduleForm.elements.enabled.value=String(schedule?.enabled??true);broadcastScheduleForm.elements.channel.value=schedule?.channel||'native';broadcastScheduleForm.elements.intervalMinutes.value=schedule?.intervalMinutes||60;broadcastScheduleForm.elements.style.value=schedule?.style||'info';broadcastScheduleForm.elements.duration.value=schedule?.duration||15;broadcastScheduleForm.elements.title.value=schedule?.title||'服务器通知';broadcastScheduleForm.elements.message.value=schedule?.message||'';
  document.querySelector('#broadcastScheduleFormTitle').textContent=schedule?'编辑循环广播':'新建循环广播';document.querySelector('#broadcastScheduleMode').textContent=schedule?'编辑':'新任务';document.querySelector('#broadcastScheduleMode').className=`badge ${schedule?.enabled?'running':'neutral'}`;document.querySelector('#deleteBroadcastSchedule').disabled=!schedule;document.querySelector('#runBroadcastScheduleNow').disabled=!schedule;
}
function renderBroadcastSchedules(){
  const list=document.querySelector('#broadcastScheduleList');
  list.innerHTML=broadcastSchedules.length?broadcastSchedules.map(item=>`<button class="broadcast-schedule-row${item.id===broadcastScheduleForm.elements.id.value?' selected':''}" type="button" data-broadcast-schedule="${escapeHtml(item.id)}"><span><strong>${escapeHtml(item.name)}</strong><small>${escapeHtml(broadcastChannelLabels[item.channel]||item.channel)} · 每 ${Number(item.intervalMinutes)} 分钟</small></span><b class="badge ${item.enabled?'running':'neutral'}">${item.enabled?'启用':'暂停'}</b><time>下次 ${item.enabled?formatDate(item.nextRunAt):'--'}</time><em>${escapeHtml(item.lastMessage||'尚未执行')}</em></button>`).join(''):'<p class="empty-state compact">当前服务器没有循环广播任务。</p>';
  list.querySelectorAll('[data-broadcast-schedule]').forEach(row=>row.onclick=()=>{fillBroadcastSchedule(broadcastSchedules.find(item=>item.id===row.dataset.broadcastSchedule));renderBroadcastSchedules()});
}
async function refreshBroadcastSchedules(){if(!selectedId||broadcastScheduleBusy)return;const serverId=selectedId;broadcastScheduleBusy=true;try{const data=await api(`/api/broadcast-schedules?serverId=${encodeURIComponent(serverId)}`);if(serverId!==selectedId)return;broadcastSchedules=data.schedules||[];const editing=broadcastSchedules.find(item=>item.id===broadcastScheduleForm.elements.id.value);if(editing)fillBroadcastSchedule(editing);else if(!broadcastScheduleForm.elements.id.value)fillBroadcastSchedule();renderBroadcastSchedules()}catch(error){if(serverId===selectedId)document.querySelector('#broadcastScheduleList').innerHTML=`<p class="empty-state compact error-text">${escapeHtml(error.message)}</p>`}finally{broadcastScheduleBusy=false}}
document.querySelector('#newBroadcastSchedule').onclick=()=>{fillBroadcastSchedule();renderBroadcastSchedules();broadcastScheduleForm.elements.name.focus()};
broadcastScheduleForm.onsubmit=async event=>{event.preventDefault();const values=formData(event.currentTarget),editing=Boolean(values.id),intervalMinutes=Number(values.intervalMinutes),duration=Number(values.duration);if(!Number.isInteger(intervalMinutes)||intervalMinutes<5||intervalMinutes>10080){toast('循环间隔必须为 5 至 10080 分钟。',true);return}const payload={id:values.id,serverId:selectedId,name:values.name,enabled:values.enabled==='true',channel:values.channel,intervalMinutes,style:values.style,duration,title:values.title,message:values.message};try{const result=await api('/api/broadcast-schedules',{method:editing?'PUT':'POST',body:JSON.stringify(payload)});broadcastSchedules=result.schedules||[];const selected=broadcastSchedules.find(item=>item.id===values.id)||broadcastSchedules.find(item=>item.name===values.name);fillBroadcastSchedule(selected);renderBroadcastSchedules();toast(result.message)}catch(error){toast(error.message,true)}};
document.querySelector('#deleteBroadcastSchedule').onclick=async()=>{const id=broadcastScheduleForm.elements.id.value,item=broadcastSchedules.find(value=>value.id===id);if(!item||!confirm(`确认删除循环广播“${item.name}”？`))return;try{const result=await api('/api/broadcast-schedules',{method:'DELETE',body:JSON.stringify({id,confirm:'DELETE_BROADCAST_SCHEDULE'})});broadcastSchedules=result.schedules||[];fillBroadcastSchedule();renderBroadcastSchedules();toast(result.message)}catch(error){toast(error.message,true)}};
document.querySelector('#runBroadcastScheduleNow').onclick=async event=>{const id=broadcastScheduleForm.elements.id.value;if(!id)return;const button=event.currentTarget;button.disabled=true;try{const result=await api('/api/broadcast-schedules/run-now',{method:'POST',body:JSON.stringify({id})});broadcastSchedules=result.schedules||[];const selected=broadcastSchedules.find(item=>item.id===id);fillBroadcastSchedule(selected);renderBroadcastSchedules();toast(result.message);setTimeout(()=>activeView==='maintenance'&&refreshExecutionHistory(),700)}catch(error){toast(error.message,true)}finally{button.disabled=false}};

const commandActionLabels={players:'查询在线玩家',connections:'查询连接列表',stats:'查询服务器统计',save:'保存当前世界',showoptions:'查询服务器选项',reloadoptions:'重新加载服务器选项','check-mod-updates':'检查 Mod 更新',help:'查询完整命令帮助','help-topic':'查询命令帮助',broadcast:'发送全服广播',access:'修改访问级别',additem:'发放物品',worldgen:'世界生成操作'};
function renderCommandResult(state,title,meta,output){const tray=document.querySelector('#commandResultTray');tray.hidden=false;tray.dataset.state=state;document.querySelector('#commandResultTitle').textContent=title;document.querySelector('#commandResultMeta').textContent=meta;document.querySelector('#commandResultOutput').textContent=output;lucide.createIcons()}
function commandOutputText(data){return(data.output||[]).map(line=>line.replace(/^.*?>\s*/, '')).join('\n')||'服务器没有返回可识别的结果行。托管通道只确认命令已写入，不能把这视为游戏逻辑已经成功。'}
async function followCommandResult(serverId,requestId,title,serial){
  for(let attempt=0;attempt<55;attempt+=1){
    await sleep(attempt?1000:450);if(serial!==commandResultSerial||serverId!==selectedId)return;
    try{
      const data=await api(`/api/command/result?serverId=${encodeURIComponent(serverId)}&id=${encodeURIComponent(requestId)}`);if(serial!==commandResultSerial||serverId!==selectedId)return;
      if(data.status==='failed'){renderCommandResult('error',`${title}失败`,`命令 ${data.command}`,data.receipt?.error||commandOutputText(data));return}
      if(data.status==='response'){
        if(data.command==='players')refreshPlayers();
        if(data.resultCode==='mods-current'){renderCommandResult('success','Mod 无需更新',`检查完成 · ${formatDate(data.queuedAt)}`,`${data.resultMessage}\n\n服务器原始结果：\n${commandOutputText(data)}`);return}
        if(data.resultCode==='mods-update-required'){renderCommandResult('warning','发现 Mod 更新',`需要安排停服更新 · ${formatDate(data.queuedAt)}`,`${data.resultMessage}\n\n服务器原始结果：\n${commandOutputText(data)}`);return}
        renderCommandResult('success',`${title}已返回结果`,`命令 ${data.command} · ${formatDate(data.queuedAt)}`,commandOutputText(data));return
      }
      if(data.done||data.noOutput){renderCommandResult('warning',`${title}已送达，但无结果行`,`命令 ${data.command} · 托管通道已确认写入`,commandOutputText(data));return}
      renderCommandResult(data.status==='delivered'?'delivered':'queued',data.status==='delivered'?`${title}已送达服务器`:`${title}正在排队`,`命令 ${data.command} · 已等待 ${attempt+1} 秒`,'正在等待服务器控制台返回内容...');
    }catch(error){renderCommandResult('error',`${title}结果读取失败`,'无法继续查询命令状态',error.message);return}
  }
  renderCommandResult('warning',`${title}等待超时`,'命令可能仍在服务器内部执行','可以在实时日志中继续查看后续输出。');
}
async function followBroadcastResults(serverId,requestIds,serial){
  const ids=[...new Set(requestIds.filter(Boolean))],total=ids.length;
  for(let attempt=0;attempt<55;attempt+=1){
    await sleep(attempt?1000:450);if(serial!==commandResultSerial||serverId!==selectedId)return;
    try{
      const results=await Promise.all(ids.map(id=>api(`/api/command/result?serverId=${encodeURIComponent(serverId)}&id=${encodeURIComponent(id)}`)));if(serial!==commandResultSerial||serverId!==selectedId)return;
      const failed=results.filter(data=>data.status==='failed'||data.receipt?.status==='failed');
      const completed=results.filter(data=>data.receipt?.status==='completed');
      if(failed.length){
        const first=failed[0];
        renderCommandResult('error','全服广播发送失败',`失败 ${failed.length} 段 · 已发送 ${completed.length}/${total} 段`,first.receipt?.error||`第 ${results.indexOf(first)+1} 段未能写入服务器控制台。`);return
      }
      if(completed.length===total){renderCommandResult('success','全服广播已发送',`已发送 ${total}/${total} 段` ,`服务器控制台已接收全部 ${total} 段广播。`);return}
      if(completed.length){renderCommandResult('delivered','全服广播正在发送',`已发送 ${completed.length}/${total} 段`,`服务器控制台已接收 ${completed.length} 段，正在等待剩余 ${total-completed.length} 段。`)}
      else renderCommandResult('queued','全服广播正在排队',`已发送 0/${total} 段 · 已等待 ${attempt+1} 秒`,'正在等待受控命令通道写入服务器控制台...');
    }catch(error){renderCommandResult('error','全服广播结果读取失败','无法继续查询各分段的发送状态',error.message);return}
  }
  renderCommandResult('warning','全服广播等待超时',`共 ${total} 段 · 发送状态尚未全部确认`,'请在实时日志或聊天记录中查看后续结果。');
}
function renderPersistedItemGrantResult(submission,count){
  if(!submission?.found||!submission.resultCode)return false;
  const status=String(submission.status||''),code=String(submission.resultCode||''),terminal=status==='failed'||['completed','completed-with-warning','item-result-unconfirmed','failed'].includes(code);
  if(!terminal)return false;
  const failed=status==='failed'||code==='failed',warning=status==='warning'||code==='completed-with-warning'||code==='item-result-unconfirmed',state=failed?'error':warning?'warning':'success';
  const title=failed?'物品发放任务已结束，存在失败':warning?'物品发放已结束，部分结果需核对':'物品发放已由游戏服务器确认';
  renderCommandResult(state,title,`持久化任务已完成 · 共 ${Number(submission.targetCount||count)} 人`,submission.resultMessage||'执行历史已经记录物品发放完成。');
  return true;
}
async function followItemGrantResults(serverId,submission,serial){
  const itemIds=[...new Set((submission.itemRequestIds||submission.requestIds||[]).filter(Boolean))],notificationIds=[...new Set((submission.notificationRequestIds||[]).filter(Boolean))],allIds=[...new Set([...itemIds,...notificationIds])],count=Number(submission.targetCount||itemIds.length),noticeId=submission.noticeId||'',submissionId=submission.submissionId||'',initialWarnings=[...(submission.notificationWarnings||[])];
  for(let attempt=0;attempt<55;attempt+=1){
    await sleep(attempt?1000:450);if(serial!==commandResultSerial||serverId!==selectedId)return;
    if(submissionId){
      const persisted=await api(`/api/command/submission?serverId=${encodeURIComponent(serverId)}&id=${encodeURIComponent(submissionId)}`,{timeoutMs:10000}).catch(()=>null);
      if(serial!==commandResultSerial||serverId!==selectedId)return;
      if(renderPersistedItemGrantResult(persisted,count))return;
    }
    try{
      const batch=await api(`/api/command/results?serverId=${encodeURIComponent(serverId)}&ids=${encodeURIComponent(allIds.join(','))}`,{timeoutMs:15000}),results=batch.results||[];if(serial!==commandResultSerial||serverId!==selectedId)return;
      const byId=new Map(allIds.map((id,index)=>[id,results[index]])),itemResults=itemIds.map(id=>byId.get(id)),notificationResults=notificationIds.map(id=>byId.get(id));
      const itemConfirmed=itemResults.filter(data=>data?.gameStatus==='success'||data?.resultCode==='item-added'),itemFailed=itemResults.filter(data=>data?.gameStatus==='failed'||data?.status==='failed'||data?.receipt?.status==='failed'),itemUnconfirmed=itemResults.filter(data=>data?.gameStatus==='unconfirmed'),itemDelivered=itemResults.filter(data=>data?.gameStatus==='pending'||(!data?.gameStatus&&data?.receipt?.status==='completed')),itemQueued=itemResults.filter(data=>!data?.receipt&&!['success','failed','unconfirmed','pending'].includes(data?.gameStatus)),notificationFailed=notificationResults.filter(data=>data?.status==='failed'||data?.receipt?.status==='failed'),notificationCompleted=notificationResults.filter(data=>data?.receipt?.status==='completed');
      let popup=null;if(noticeId)popup=await api(`/api/notices/receipt?serverId=${encodeURIComponent(serverId)}&id=${encodeURIComponent(noticeId)}`).catch(()=>null);if(serial!==commandResultSerial||serverId!==selectedId)return;
      const popupExpected=Number(popup?.expectedClients??submission.expectedNoticeClients??0),popupAcknowledged=Number(popup?.acknowledgedClients||0),popupDelivered=['broadcast','directed'].includes(popup?.status),itemsFinished=itemConfirmed.length+itemFailed.length+itemUnconfirmed.length===itemIds.length,warnings=[...initialWarnings];
      if(notificationFailed.length)warnings.push(`文字广播有 ${notificationFailed.length} 段发送失败。`);if(popup?.status==='rejected')warnings.push(`Mod 弹窗被拒绝：${popup.error||'格式无效'}`);
      if(itemsFinished){
        if(itemFailed.length)warnings.push(`${itemFailed.length} 名玩家明确发放失败。`);if(itemUnconfirmed.length)warnings.push(`${itemUnconfirmed.length} 名玩家已送达控制台但未捕获游戏结果，请先核对再决定是否重发。`);
        const parts=[`游戏确认成功 ${itemConfirmed.length}/${count} 人，明确失败 ${itemFailed.length} 人，待人工确认 ${itemUnconfirmed.length} 人。`];
        if(itemFailed.length)parts.push(itemFailed.map(data=>data.resultMessage||`${data.command}: ${data.receipt?.error||'游戏服务器返回失败'}`).join('\n'));
        if(notificationIds.length)parts.push(`附加文字广播：已送达 ${notificationCompleted.length}/${notificationIds.length} 段${notificationCompleted.length+notificationFailed.length<notificationIds.length?'，后台继续确认':''}。`);
        if(noticeId)parts.push(popupDelivered?`Mod 弹窗已由服务端发出，当前客户端确认 ${popupAcknowledged}/${popupExpected}；弹窗回执不再阻塞物品结果。`:`Mod 弹窗仍由后台确认，不影响物品发放结果。`);
        if(warnings.length)parts.push(`警告：${warnings.join('；')}`);
        const state=itemFailed.length?'error':warnings.length?'warning':'success',title=itemFailed.length?'部分玩家物品发放失败':itemUnconfirmed.length?'物品命令已送达，部分结果待确认':'物品发放已由游戏服务器确认';renderCommandResult(state,title,`确认 ${itemConfirmed.length} · 失败 ${itemFailed.length} · 待确认 ${itemUnconfirmed.length} · 共 ${count} 人`,parts.join('\n'));return
      }
      const progress=[`游戏确认 ${itemConfirmed.length}/${count}`,`已送达待结果 ${itemDelivered.length}`,`排队 ${itemQueued.length}`];if(itemFailed.length)progress.push(`失败 ${itemFailed.length}`);if(notificationIds.length)progress.push(`文字广播 ${notificationCompleted.length}/${notificationIds.length}`);if(noticeId)progress.push(popupDelivered?`弹窗已发出 ${popupAcknowledged}/${popupExpected}`:'弹窗等待 Mod');renderCommandResult(itemConfirmed.length||itemDelivered.length?'delivered':'queued',itemConfirmed.length?'正在确认剩余玩家的发放结果':itemDelivered.length?'物品命令已送达，等待游戏结果':'物品发放正在排队',`${progress.join(' · ')} · 已等待 ${attempt+1} 秒`,'面板正在按玩家和物品精确核对游戏日志；附加通知不会阻塞物品完成状态。');
    }catch(error){
      if(attempt>=54){renderCommandResult('warning','物品发放结果查询暂时中断',`共 ${count} 名玩家 · 后台任务仍可继续记录最终结果`,`${error.message}\n请在执行历史中核对“游戏确认”数量，避免重复发放。`);return}
      renderCommandResult('delivered','物品命令已提交，正在恢复结果查询',`共 ${count} 名玩家 · 第 ${attempt+1} 次查询暂未返回`,'面板会优先从持久化执行历史确认最终结果，请不要重复发放。');
    }
  }
  renderCommandResult('warning','物品发放结果等待超时',`共 ${count} 名玩家 · 状态尚未全部确认`,'命令可能已送达。为避免重复发放，请先在执行历史中核对“游戏确认”数量。');
}
document.querySelector('#closeCommandResult').onclick=()=>{commandResultSerial+=1;noticeSerial+=1;document.querySelector('#commandResultTray').hidden=true};
const createSubmissionId=()=>{if(globalThis.crypto?.randomUUID)return crypto.randomUUID().replaceAll('-','');const bytes=new Uint8Array(16);crypto.getRandomValues(bytes);return [...bytes].map(value=>value.toString(16).padStart(2,'0')).join('')};
async function recoverCommandSubmission(serverId,submissionId){
  for(let attempt=0;attempt<8;attempt+=1){
    if(attempt)await sleep(500);
    try{const recovered=await api(`/api/command/submission?serverId=${encodeURIComponent(serverId)}&id=${encodeURIComponent(submissionId)}`,{timeoutMs:3000});if(recovered.found)return recovered}catch{}
  }
  return null;
}
async function command(body){
  const server=currentServer();if(!server?.writable){toast(server?.note||'当前服务器不可执行命令。',true);return false}
  noticeSerial+=1;
  const serverId=selectedId,title=commandActionLabels[body.action]||'服务器命令',showResult=body.action!=='worldgen',serial=showResult?++commandResultSerial:commandResultSerial,submissionId=body.action==='additem'?createSubmissionId():'';
  if(showResult)renderCommandResult('queued',`${title}正在提交`,'正在写入受控命令队列','等待面板接收命令...');
  try{
    const data=await api('/api/command',{method:'POST',body:JSON.stringify({...body,serverId,submissionId}),timeoutMs:15000});if(body.action==='additem'&&!data.submissionId)data.submissionId=submissionId;toast(data.message);setTimeout(pollLog,700);if(body.action==='players'||body.action==='access')setTimeout(refreshPlayers,1200);
    if(showResult&&body.action==='additem'&&renderPersistedItemGrantResult(data.immediateItemResult?.submission,Number(data.targetCount||data.itemRequestIds?.length||1)))return data;
    if(showResult&&body.action==='additem'&&data.itemRequestIds?.length){renderCommandResult('delivered','物品发放已进入服务器队列',`面板已接收 · 目标 ${Number(data.targetCount||data.itemRequestIds.length)} 人`,'正在等待游戏服务器逐名返回发放结果...');followItemGrantResults(serverId,data,serial)}
    else if(showResult&&body.action==='broadcast'&&data.requestIds?.length)followBroadcastResults(serverId,data.requestIds,serial);else if(showResult&&data.requestId)followCommandResult(serverId,data.requestId,title,serial);return data
  }catch(error){
    if(body.action==='additem'&&submissionId){
      if(showResult&&serial===commandResultSerial)renderCommandResult('delivered','正在找回物品发放状态','提交响应未及时返回，但命令可能已经执行','正在通过唯一提交 ID 查询执行历史，请不要重复点击发放。');
      const recovered=await recoverCommandSubmission(serverId,submissionId);
      if(recovered){toast('已从执行历史找回物品发放任务，没有重复提交。');if(showResult&&serial===commandResultSerial){renderCommandResult('delivered','已找回物品发放任务',`任务状态：${recovered.status||'执行中'} · 目标 ${Number(recovered.targetCount||recovered.requestIds?.length||0)} 人`,'面板正在继续核对游戏服务器结果，请不要重复发放。');followItemGrantResults(serverId,recovered,serial)}return recovered}
    }
    if(showResult&&serial===commandResultSerial)renderCommandResult('error',`${title}提交失败`,'没有找到对应的服务器任务',`${error.message}\n未发现可恢复的执行记录，本次可以重新提交。`);toast(error.message,true);return false
  }
}
const formData=form=>Object.fromEntries(new FormData(form).entries());
const roleLabels={admin:'管理员',moderator:'版主',gm:'GM',overseer:'监管员',observer:'观察员',priority:'优先玩家',user:'普通玩家',banned:'已封禁'};
function renderPlayers(){
  const table=document.querySelector('#playerTable');
  const players=playerDirectory?.players||[],online=players.filter(player=>player.online),history=players.filter(player=>!player.online);
  const onlineKnown=playerDirectory?.onlineKnown!==false;
  document.querySelector('#playerSummary').textContent=!onlineKnown?'在线状态暂时无法确认':online.length?`在线 ${online.length} 人：${online.map(player=>player.username).join('、')}`:'当前没有在线玩家';
  renderOnlinePlayerSelects();refreshOpenPlayerPickers();
  if(!players.length){table.innerHTML='<p class="empty-state">没有读取到玩家账号记录。</p>';return}
  const header='<div class="player-table-head"><span>玩家</span><span>状态</span><span>SteamID</span><span>权限</span><span>最近连接</span></div>';
  const rows=list=>list.map(player=>`<button type="button" class="player-table-row ${player.online?'online':''}" data-player-name="${escapeHtml(player.username)}" data-steam-id="${escapeHtml(player.steamId||'')}"><strong>${escapeHtml(player.username)}</strong><span><i></i>${player.online?'在线':'离线'}</span><code>${escapeHtml(player.steamId||'未记录')}</code><b class="role-badge ${escapeHtml(player.role)}">${escapeHtml(roleLabels[player.role]||player.role)}</b><time>${escapeHtml(player.lastConnection||'--')}</time></button>`).join('');
  table.innerHTML=`<section class="player-group"><div class="player-group-title"><strong>在线玩家</strong><span>${onlineKnown?`${online.length} 人`:'未知'}</span></div>${online.length?header+rows(online):`<p class="empty-state compact">${onlineKnown?'当前没有在线玩家。':'当前日志无法确认在线玩家。'}</p>`}</section><details class="player-history"><summary><span>历史玩家</span><b>${history.length} 人</b></summary>${history.length?header+rows(history):'<p class="empty-state compact">没有其他历史玩家。</p>'}</details>`;
  table.querySelectorAll('[data-player-name]').forEach(row=>row.onclick=()=>{document.querySelector('#accessForm input[name="username"]').value=row.dataset.playerName;const steamInput=document.querySelector('#steamForm input[name="steamId"]');if(steamInput&&row.dataset.steamId)steamInput.value=row.dataset.steamId;if(row.dataset.steamId&&canManagePlayerData()){document.querySelector('#playerAdminLookupForm input[name="steamId"]').value=row.dataset.steamId;queryPlayerAdmin(row.dataset.steamId)}});
}
const canManagePlayerData=()=>Boolean(authSession?.user?.canManagePlayerData);
function updatePlayerAdminAccess(){
  const panel=document.querySelector('#playerDataAdmin');panel.hidden=!canManagePlayerData();
  if(panel.hidden){playerAdminSerial+=1;playerAdminBusy=false;playerAdminSnapshot=null;document.querySelector('#playerAdminLookupForm').reset();renderPlayerAdmin()}
}
function renderPlayerAdmin(data=playerAdminSnapshot){
  const result=document.querySelector('#playerAdminResult'),state=document.querySelector('#playerAdminState'),message=document.querySelector('#playerAdminMessage');
  if(!data){result.hidden=true;state.textContent='尚未查询';state.className='badge neutral';message.textContent='按 SteamID64 查询关联账号、角色、允许列表和封禁状态。';return}
  const accounts=data.accounts||[],characters=data.characters||[],server=currentServer(),running=Boolean(server?.alive),lifecycleActive=Boolean(data.lifecycleActive),deletable=accounts.length>0||characters.length>0||data.allowed;
  result.hidden=false;state.textContent=data.found?'已找到档案':'未找到档案';state.className=`badge ${data.found?'running':'neutral'}`;
  document.querySelector('#playerAdminSteamId').textContent=data.steamId||'--';document.querySelector('#playerAdminAccountCount').textContent=String(accounts.length);document.querySelector('#playerAdminCharacterCount').textContent=String(characters.length);document.querySelector('#playerAdminAccessState').textContent=`${data.allowed?'允许':'未允许'} / ${data.banned?'已封禁':'未封禁'}`;
  document.querySelector('#playerAdminAccounts').innerHTML=accounts.length?accounts.map(account=>`<div class="player-admin-record"><span><strong>${escapeHtml(account.username)}</strong><small>${escapeHtml(account.displayName||'无显示名')} · ${escapeHtml(roleLabels[account.role]||account.role||'普通玩家')}</small></span><b class="${account.online?'online':''}">${account.online?'在线':'离线'}</b><code>${escapeHtml(account.steamId||account.ownerId||'未记录')}</code><time>${escapeHtml(account.lastConnection||'--')}</time></div>`).join(''):'<p class="empty-state compact">没有关联账号。</p>';
  document.querySelector('#playerAdminCharacters').innerHTML=characters.length?characters.map(character=>`<div class="player-admin-record"><span><strong>${escapeHtml(character.name||character.username||'未命名角色')}</strong><small>${escapeHtml(character.username||'未知账号')} · 槽位 ${Number(character.playerIndex||0)}</small></span><b class="${character.isDead?'dead':''}">${character.isDead?'已死亡':'存活'}</b><code>${Number(character.x||0)}, ${Number(character.y||0)}, ${Number(character.z||0)}</code><time>${escapeHtml(character.world||'--')}</time></div>`).join(''):'<p class="empty-state compact">没有关联角色存档。</p>';
  const passwordForm=document.querySelector('#playerPasswordForm'),passwordSelect=passwordForm.elements.username,passwordButton=passwordForm.querySelector('button[type="submit"]');passwordSelect.innerHTML=accounts.map(account=>`<option value="${escapeHtml(account.username)}">${escapeHtml(account.username)}${account.online?' · 在线':''}</option>`).join('');passwordSelect.disabled=!accounts.length;passwordButton.disabled=!accounts.length||!running;
  document.querySelector('#playerPasswordHint').textContent=!accounts.length?'没有可修改的关联账号。':running?'密码不会写入 Web 历史或 API 回包。':'服务器已停止，官方 setpassword 命令不可用。';
  const deleteForm=document.querySelector('#playerDeleteForm'),deleteButton=deleteForm.querySelector('button[type="submit"]');deleteButton.disabled=!deletable||running||lifecycleActive;deleteForm.elements.confirmSteamId.value='';
  document.querySelector('#playerDeleteHint').textContent=!deletable?'没有可删除的账号、角色或允许列表数据。':running?'服务器正在运行，必须先安全停服。':lifecycleActive?'服务器生命周期任务尚未结束。':'可删除；执行前会自动备份两个数据库。';
  message.textContent=data.found?`已读取 ${data.serverName||server?.name||'服务器'} 的玩家档案。封禁记录不会随账号删除。`:`SteamID ${data.steamId} 没有关联记录。`;
  lucide.createIcons();
}
async function queryPlayerAdmin(steamId=document.querySelector('#playerAdminLookupForm input[name="steamId"]').value.trim()){
  if(!selectedId||playerAdminBusy)return false;if(!/^7656119\d{10}$/.test(steamId)){toast('请输入 7656119 开头的 17 位 SteamID64。',true);return false}
  const serverId=selectedId,serial=++playerAdminSerial;playerAdminBusy=true;document.querySelector('#playerAdminState').textContent='查询中';document.querySelector('#playerAdminMessage').textContent='正在读取账号数据库与角色数据库...';
  try{const data=await api(`/api/player-admin?serverId=${encodeURIComponent(serverId)}&steamId=${encodeURIComponent(steamId)}`);if(serial!==playerAdminSerial||serverId!==selectedId)return false;playerAdminSnapshot=data;renderPlayerAdmin();return data}catch(error){if(serial===playerAdminSerial&&serverId===selectedId){playerAdminSnapshot=null;renderPlayerAdmin();document.querySelector('#playerAdminMessage').textContent=error.message;toast(error.message,true)}return false}finally{if(serial===playerAdminSerial)playerAdminBusy=false}
}
function renderOnlinePlayerSelects(){
  const online=(playerDirectory?.players||[]).filter(player=>player.online).sort((a,b)=>a.username.localeCompare(b.username,'zh-CN'));
  document.querySelectorAll('.online-player-select').forEach(select=>{
    const previous=select.value,placeholder=online.length?`请选择在线玩家（${online.length} 人）`:playerDirectory?.onlineKnown===false?'暂时无法确认在线玩家':'当前没有在线玩家';
    select.innerHTML=`<option value="">${placeholder}</option>${online.map(player=>`<option value="${escapeHtml(player.username)}">${escapeHtml(player.username)}${player.steamId?` · ${escapeHtml(player.steamId)}`:''}</option>`).join('')}`;
    if(online.some(player=>player.username===previous))select.value=previous;
    select.dataset.onlineEmpty=String(!online.length);
  });
  document.querySelectorAll('#grantForm,#catalogGrantForm').forEach(form=>{renderItemGrantTargets(form,online);updateItemGrantNotificationState(form)});
  ['grantForm','xpForm','keyForm'].forEach(id=>{const form=document.querySelector(`#${id}`),button=form?.querySelector('button[type="submit"]');if(button)button.dataset.onlineEmpty=String(!online.length)});
  document.querySelectorAll('#catalogGrantForm button[type="submit"]').forEach(button=>button.dataset.onlineEmpty=String(!online.length));
  renderCurrentServer();
}
function renderItemGrantTargets(form,online=(playerDirectory?.players||[]).filter(player=>player.online).sort((a,b)=>a.username.localeCompare(b.username,'zh-CN'))){
  const checklist=form.querySelector('.item-target-checklist');if(!checklist)return;
  const checked=new Set([...checklist.querySelectorAll('input:checked')].map(input=>input.value.toLowerCase()));
  checklist.innerHTML=online.length?online.map(player=>`<label><input type="checkbox" name="selectedUsername" value="${escapeHtml(player.username)}"${checked.has(player.username.toLowerCase())?' checked':''}><span><strong>${escapeHtml(player.username)}</strong><small>${escapeHtml(player.steamId||'未记录 SteamID')}</small></span></label>`).join(''):'<p class="empty-state compact">当前没有可选的在线玩家。</p>';
  updateItemGrantTargetState(form,online);
}
function updateItemGrantTargetState(form,online=(playerDirectory?.players||[]).filter(player=>player.online)){
  const mode=form.querySelector('input[name="targetMode"]:checked')?.value||'single',single=form.querySelector('.item-target-single'),selected=form.querySelector('.item-target-selected'),select=form.querySelector('.online-player-select'),summary=form.querySelector('.item-target-summary');
  if(single)single.hidden=mode!=='single';if(selected)selected.hidden=mode!=='selected';if(select)select.required=mode==='single';
  const selectedCount=form.querySelectorAll('.item-target-checklist input:checked').length,known=playerDirectory?.onlineKnown!==false;
  summary.textContent=!known?'在线状态暂时无法确认，后端会拒绝批量发放。':mode==='all-online'?`将发给当前全部 ${online.length} 名在线玩家。`:mode==='selected'?`已选择 ${selectedCount}/${online.length} 名在线玩家。`:'从当前在线玩家中选择一人。';
}
function updateItemGrantNotificationState(form){
  const channel=form.querySelector('[name="notificationChannel"]')?.value||'none',fields=form.querySelector('.item-grant-notification-fields'),durationField=form.querySelector('.item-notice-duration'),hint=form.querySelector('.item-notification-hint'),popup=['popup','both'].includes(channel);
  if(fields)fields.hidden=channel==='none';if(durationField)durationField.hidden=!popup;if(!hint)return;
  if(channel==='none'){hint.textContent='只发放物品，不额外通知。';return}
  if(popup&&!noticeChannel?.usable)hint.textContent='将尝试发送通知；当前尚未确认 Mod 心跳，物品仍会正常发放，弹窗失败会记为警告。';
  else hint.textContent=channel==='native'?'通知会作为文字发送给当前全服在线玩家。':channel==='popup'?'通知会通过 Mod 右下角弹窗发送给当前全服在线玩家。':'同一内容会同时发送文字广播和 Mod 右下角弹窗。';
}
function getItemGrantPayload(form,item){
  const mode=form.querySelector('input[name="targetMode"]:checked')?.value||'single',count=Number(form.querySelector('input[name="count"]')?.value||0),select=form.querySelector('.online-player-select'),notificationChannel=form.querySelector('[name="notificationChannel"]')?.value||'none',notificationMessage=form.querySelector('[name="notificationMessage"]')?.value.trim()||'',notificationDuration=Number(form.querySelector('[name="notificationDuration"]')?.value||10);
  let usernames=[];
  if(mode==='single'&&select?.value)usernames=[select.value];
  if(mode==='selected')usernames=[...form.querySelectorAll('.item-target-checklist input:checked')].map(input=>input.value);
  if(mode!=='all-online'&&!usernames.length){toast(mode==='single'?'请选择一名在线玩家。':'请至少勾选一名在线玩家。',true);return null}
  return {action:'additem',targetMode:mode,usernames,username:usernames[0]||'',item,count,notificationChannel,notificationMessage,notificationDuration};
}
function submitItemGrant(form,item){
  const payload=getItemGrantPayload(form,item);if(!payload)return false;
  const onlineCount=(playerDirectory?.players||[]).filter(player=>player.online).length,targetCount=payload.targetMode==='all-online'?onlineCount:payload.usernames.length;
  const notificationLabel={none:'不发送通知',native:'同时发送文字全服广播',popup:'同时发送 Mod 弹窗',both:'同时发送文字广播和 Mod 弹窗'}[payload.notificationChannel]||'不发送通知';
  if((targetCount>1||payload.notificationChannel!=='none')&&!confirm(`确认向 ${targetCount} 名当前在线玩家各发放 ${payload.count} 个 ${item}？\n${notificationLabel}`))return false;
  return command(payload);
}
document.addEventListener('change',event=>{const form=event.target.closest('#grantForm,#catalogGrantForm');if(!form)return;if(event.target.matches('input[name="targetMode"]')||event.target.matches('.item-target-checklist input'))updateItemGrantTargetState(form);if(event.target.matches('[name="notificationChannel"]')){updateItemGrantNotificationState(form);if(['popup','both'].includes(event.target.value))refreshNoticeStatus(true)}});
document.addEventListener('click',event=>{const action=event.target.closest('[data-item-target-action]');if(!action)return;const form=action.closest('#grantForm,#catalogGrantForm'),checked=action.dataset.itemTargetAction==='all';form.querySelectorAll('.item-target-checklist input').forEach(input=>input.checked=checked);updateItemGrantTargetState(form)});
async function refreshPlayers(){
  if(!selectedId||(playersBusy&&playerRequestServer===selectedId))return;const requestServer=selectedId,requestSerial=++playerRequestSerial;playersBusy=true;playerRequestServer=requestServer;
  try{const data=await api(`/api/players?serverId=${encodeURIComponent(requestServer)}`);if(requestSerial!==playerRequestSerial||data.serverId!==selectedId)return;playerDirectory=data;lastPlayersRefreshAt=Date.now();renderPlayers()}catch(error){if(requestSerial===playerRequestSerial&&requestServer===selectedId)document.querySelector('#playerTable').innerHTML=`<p class="empty-state error-text">${escapeHtml(error.message)}</p>`}finally{if(requestSerial===playerRequestSerial){playersBusy=false;playerRequestServer=''}}
}
function playerPickerRows(input){
  const mode=input.name==='steamId'?'steam':'name',needle=input.value.trim().toLowerCase();
  return (playerDirectory?.players||[]).filter(player=>mode==='name'||player.steamId).filter(player=>!needle||player.username.toLowerCase().includes(needle)||String(player.steamId||'').includes(needle)).sort((a,b)=>Number(b.online)-Number(a.online)||a.username.localeCompare(b.username,'zh-CN')).slice(0,80);
}
function renderPlayerPicker(input){
  const menu=input.parentElement.querySelector('.player-picker-menu');if(!menu)return;
  const players=playerPickerRows(input),online=players.filter(player=>player.online),history=players.filter(player=>!player.online);
  const rows=list=>list.map(player=>`<button type="button" class="player-picker-option" data-player-name="${escapeHtml(player.username)}" data-steam-id="${escapeHtml(player.steamId||'')}"><span><strong>${escapeHtml(player.username)}</strong><small>${escapeHtml(roleLabels[player.role]||player.role)}</small></span><span><b class="${player.online?'online':''}">${player.online?'在线':'历史'}</b><code>${escapeHtml(player.steamId||'无 SteamID')}</code></span></button>`).join('');
  menu.innerHTML=players.length?`${online.length?`<div class="player-picker-group"><span>在线玩家</span><b>${online.length}</b></div>${rows(online)}`:''}${history.length?`<details class="player-picker-history" ${online.length?'':'open'}><summary><span>历史玩家</span><b>${history.length}</b></summary>${rows(history)}</details>`:''}`:'<p class="empty-state compact">没有匹配的页面玩家记录，可继续手工输入。</p>';
}
function openPlayerPicker(input){
  document.querySelectorAll('.player-picker-menu').forEach(menu=>menu.hidden=true);renderPlayerPicker(input);input.parentElement.querySelector('.player-picker-menu').hidden=false;input.setAttribute('aria-expanded','true');
}
function closePlayerPicker(input){const menu=input.parentElement.querySelector('.player-picker-menu');if(menu)menu.hidden=true;input.setAttribute('aria-expanded','false')}
function refreshOpenPlayerPickers(){document.querySelectorAll('.player-picker input').forEach(input=>{const menu=input.parentElement.querySelector('.player-picker-menu');if(menu&&!menu.hidden)renderPlayerPicker(input)})}
document.querySelectorAll('.command-control input[name="username"],.command-control input[name="target"],#steamForm input[name="steamId"]').forEach(input=>{
  input.removeAttribute('list');input.autocomplete='new-password';input.setAttribute('role','combobox');input.setAttribute('aria-autocomplete','list');input.setAttribute('aria-expanded','false');
  const wrapper=document.createElement('div');wrapper.className='player-picker';input.parentNode.insertBefore(wrapper,input);wrapper.append(input);const menu=document.createElement('div');menu.className='player-picker-menu';menu.hidden=true;menu.setAttribute('role','listbox');wrapper.append(menu);
  input.addEventListener('focus',()=>openPlayerPicker(input));input.addEventListener('input',()=>openPlayerPicker(input));input.addEventListener('keydown',event=>{if(event.key==='Escape')closePlayerPicker(input);if(event.key==='ArrowDown'){const first=menu.querySelector('.player-picker-option');if(first){event.preventDefault();first.focus()}}});
  menu.addEventListener('mousedown',event=>{const option=event.target.closest('.player-picker-option');if(!option)return;event.preventDefault();input.value=input.name==='steamId'?option.dataset.steamId:option.dataset.playerName;closePlayerPicker(input)});
  input.addEventListener('blur',()=>setTimeout(()=>closePlayerPicker(input),150));
});
document.querySelectorAll('[data-action]').forEach(button=>button.onclick=()=>command({action:button.dataset.action}));
document.querySelector('#exportPlayers').onclick=()=>{if(!selectedId){toast('请先选择服务器。',true);return}location.href=`/api/players/export?serverId=${encodeURIComponent(selectedId)}`};
document.querySelector('#playerAdminLookupForm').onsubmit=event=>{event.preventDefault();queryPlayerAdmin()};
document.querySelector('#playerPasswordForm').onsubmit=async event=>{event.preventDefault();if(!playerAdminSnapshot)return;const values=formData(event.currentTarget);if(values.password!==values.passwordConfirm){toast('两次输入的新密码不一致。',true);return}if(!confirm(`确认修改账号 ${values.username} 的游戏密码？`))return;try{const result=await api('/api/player-admin/password',{method:'POST',body:JSON.stringify({serverId:selectedId,steamId:playerAdminSnapshot.steamId,username:values.username,password:values.password,passwordConfirm:values.passwordConfirm})});event.currentTarget.elements.password.value='';event.currentTarget.elements.passwordConfirm.value='';toast(result.message)}catch(error){toast(error.message,true)}};
document.querySelector('#playerDeleteForm').onsubmit=async event=>{event.preventDefault();if(!playerAdminSnapshot)return;const confirmSteamId=event.currentTarget.elements.confirmSteamId.value.trim(),steamId=playerAdminSnapshot.steamId;if(confirmSteamId!==steamId){toast('确认 SteamID 与目标不一致。',true);return}if(!confirm(`永久删除 SteamID ${steamId} 的账号和角色数据？\n\n执行前会自动备份数据库；封禁记录和审计日志保留。`))return;try{const result=await api('/api/player-admin',{method:'DELETE',body:JSON.stringify({serverId:selectedId,steamId,confirmSteamId,confirm:'DELETE_PLAYER_DATA'}),timeoutMs:30000});toast(result.message);document.querySelector('#playerAdminMessage').textContent=`${result.message} 备份：${result.backupPath}`;await refreshPlayers();await queryPlayerAdmin(steamId)}catch(error){toast(error.message,true)}};
document.querySelector('#refreshBtn').onclick=()=>{refreshStatus();pollLog();pollChat(true)};
document.querySelectorAll('#logFilters button').forEach(button=>button.onclick=()=>{document.querySelectorAll('#logFilters button').forEach(item=>item.classList.remove('active'));button.classList.add('active');filter=button.dataset.filter;renderLog()});
document.querySelector('#pauseLog').onclick=()=>{paused=!paused;document.querySelector('#pauseLog').innerHTML=`<i data-lucide="${paused?'play':'pause'}"></i>`;lucide.createIcons();if(!paused)pollLog()};
document.querySelector('#downloadLog').onclick=()=>{const blob=new Blob([logLines.join('\n')],{type:'text/plain;charset=utf-8'}),link=document.createElement('a');link.href=URL.createObjectURL(blob);link.download=`pz-${selectedId}-${new Date().toISOString().replace(/[:.]/g,'-')}.log`;link.click();URL.revokeObjectURL(link.href)};
document.querySelector('#broadcastForm').onsubmit=async event=>{event.preventDefault();const input=document.querySelector('#broadcastMessage'),message=input.value.trim();if(message&&await command({action:'broadcast',message}))input.value=''};
document.querySelector('#accessForm').addEventListener('click',event=>{const button=event.target.closest('button[data-access]');if(!button)return;event.preventDefault();const data=formData(document.querySelector('#accessForm'));command({action:'access',username:data.username,level:button.dataset.access==='user'?'user':data.level})});
document.querySelector('#stateForm').addEventListener('click',event=>{const button=event.target.closest('button[data-enabled]');if(!button)return;event.preventDefault();const data=formData(document.querySelector('#stateForm'));command({action:'toggle',username:data.username,feature:data.feature,enabled:button.dataset.enabled==='true'})});
document.querySelector('#teleportForm').onsubmit=event=>{event.preventDefault();command({action:'teleport',...formData(event.target)})};
document.querySelector('#grantForm').onsubmit=event=>{event.preventDefault();submitItemGrant(event.target,event.target.querySelector('[name="item"]').value.trim())};
document.querySelector('#moderationForm').addEventListener('click',event=>{const button=event.target.closest('button[data-mode]');if(!button)return;event.preventDefault();const data=formData(document.querySelector('#moderationForm')),mode=button.dataset.mode;if(mode==='ban'&&!confirm(`确认封禁玩家 ${data.username}？`))return;command({action:mode,...data,confirm:mode==='ban'?'CONFIRM':undefined})});
document.querySelectorAll('[data-event]').forEach(button=>{if(button.closest('#localWeatherForm'))return;button.onclick=()=>command({action:'event',event:button.dataset.event})});
document.querySelector('#rainForm').onsubmit=event=>{event.preventDefault();command({action:'event',event:'startrain',value:+formData(event.target).value})};
document.querySelector('#stormForm').onsubmit=event=>{event.preventDefault();command({action:'event',event:'startstorm',value:+formData(event.target).value})};
document.querySelector('#localWeatherForm').addEventListener('click',event=>{const button=event.target.closest('[data-event]');if(!button)return;event.preventDefault();command({action:'event',event:button.dataset.event,username:formData(document.querySelector('#localWeatherForm')).username})});
document.querySelector('#hordeForm').onsubmit=event=>{event.preventDefault();const data=formData(event.target);if(confirm(`确认在玩家 ${data.username} 附近生成 ${data.count} 只僵尸？`))command({action:'horde',username:data.username,count:+data.count,confirm:'CONFIRM'})};

document.querySelector('#queryForm').onsubmit=event=>{event.preventDefault();const action=formData(event.target).action;if(action==='worldgen-status')runWorldgen('status');else command({action})};
document.querySelector('#accountForm').onsubmit=event=>{event.preventDefault();const data=formData(event.target);if(data.mode==='remove')command({action:'whitelist-remove',username:data.username});else command({action:'user-account',mode:data.mode,username:data.username,password:data.password})};
document.querySelector('#steamForm').onsubmit=event=>{event.preventDefault();const data=formData(event.target),danger=data.mode==='banid';if(!danger||confirm(`确认封禁 SteamID ${data.steamId}？`))command({action:'steam-access',...data,confirm:danger?'CONFIRM':undefined})};
document.querySelector('#ipForm').onsubmit=event=>{event.preventDefault();const data=formData(event.target),danger=data.mode==='banip';if(!danger||confirm(`确认封禁 IP ${data.ip}？`))command({action:'ip-ban',...data,confirm:danger?'CONFIRM':undefined})};
document.querySelector('#optionForm').onsubmit=event=>{event.preventDefault();const data=formData(event.target);if(confirm(`确认将服务器选项 ${data.name} 修改为 ${data.value}？`))command({action:'change-option',...data,confirm:'CONFIRM'})};
document.querySelector('#timeForm').onsubmit=event=>{event.preventDefault();command({action:'time-speed',period:+formData(event.target).period})};
document.querySelector('#xpForm').onsubmit=event=>{event.preventDefault();const data=formData(event.target);command({action:'addxp',...data,amount:+data.amount})};
document.querySelector('#vehicleForm').onsubmit=event=>{event.preventDefault();command({action:'addvehicle',...formData(event.target)})};
document.querySelector('#keyForm').onsubmit=event=>{event.preventDefault();command({action:'addkey',...formData(event.target)})};
document.querySelector('#safehouseForm').onsubmit=event=>{event.preventDefault();const data=formData(event.target);if(data.mode==='release'){if(confirm(`确认释放安全屋 ${data.title}？`))command({action:'release-safehouse',title:data.title,confirm:'CONFIRM'})}else command({action:'safehouse',...data})};
document.querySelector('#userRepairForm').onsubmit=event=>{event.preventDefault();const data=formData(event.target);command({action:data.mode,username:data.username})};
const worldgenLabels={status:'查询状态',recheck:'全量重检并生成',start:'启动生成',stop:'紧急停止生成'};
function renderWorldgenResult(state,title,meta,output){const panel=document.querySelector('#worldgenResult');panel.dataset.state=state;document.querySelector('#worldgenResultTitle').textContent=title;document.querySelector('#worldgenResultMeta').textContent=meta;document.querySelector('#worldgenResultOutput').textContent=output}
function worldgenOutputText(data){
  const lines=data.output||[];let summary='';
  const progressLine=[...lines].reverse().find(line=>/Generating map:\s*\d+\/\d+/i.test(line));
  const startedLine=[...lines].reverse().find(line=>/Generating map started\.\s*Chunks:\s*\d+\s+using\s+\d+\s+threads/i.test(line));
  if(progressLine){
    const progress=progressLine.match(/Generating map:\s*(\d+)\/(\d+)(?:\s+using\s+(\d+)\s+threads|\s+ETA:\s*(\d+)\s+sec)/i);
    if(progress){const current=Number(progress[1]),total=Number(progress[2]),threads=progress[3],eta=progress[4],percent=total?Math.min(100,current/total*100).toFixed(1):'100.0';summary=total===0?`当前没有待生成地图块（${current}/${total}${threads?`，工作线程 ${threads}`:''}）。`:`地图生成进度 ${current}/${total}（${percent}%）${threads?`，使用 ${threads} 个工作线程`:''}${eta?`，预计剩余 ${Math.ceil(Number(eta)/60)} 分钟`:''}。`}
  }else if(startedLine){
    const started=startedLine.match(/Chunks:\s*(\d+)\s+using\s+(\d+)\s+threads/i);if(started)summary=`已开始生成 ${started[1]} 个地图块，使用 ${started[2]} 个工作线程。`;
  }
  const raw=lines.map(line=>line.replace(/^.*?>\s*/,''));return [summary,...raw].filter(Boolean).join('\n')||'服务器暂未返回可识别的世界生成结果。';
}
async function followWorldgenResult(serverId,requestId,serial){
  for(let attempt=0;attempt<18;attempt+=1){
    await sleep(attempt?1000:500);if(serial!==worldgenSerial||serverId!==selectedId)return;
    try{
      const data=await api(`/api/command/result?serverId=${encodeURIComponent(serverId)}&id=${encodeURIComponent(requestId)}`);if(serial!==worldgenSerial||serverId!==selectedId)return;
      if(data.status==='failed'){renderWorldgenResult('error','世界生成命令执行失败',`命令 ${data.command}`,data.receipt?.error||worldgenOutputText(data));return}
      if(data.status==='response'){renderWorldgenResult('success','服务器已返回世界生成结果',`命令 ${data.command} · ${formatDate(data.queuedAt)}`,worldgenOutputText(data));return}
      if(data.done||data.noOutput){renderWorldgenResult('warning','命令已送达，但服务器没有返回结果行',`命令 ${data.command} · 托管通道已确认写入`,worldgenOutputText(data));return}
      renderWorldgenResult(data.status==='delivered'?'delivered':'running',data.status==='delivered'?'命令已送达服务器，等待结果':'命令正在队列中',`命令 ${data.command} · 已等待 ${attempt+1} 秒`,'正在读取服务器控制台返回，请稍候...');
    }catch(error){renderWorldgenResult('error','无法读取世界生成结果','结果查询请求失败',error.message);return}
  }
  renderWorldgenResult('warning','结果等待超时','命令可能仍在服务器中执行','请稍后再次执行“查询状态”，服务器不会因为关闭此窗口而停止任务。');
}
async function runWorldgen(mode){
  const server=currentServer();let confirmation;
  if(mode==='recheck'){
    if(server?.onlineKnown&&Number(server.onlineCount)>0){renderWorldgenResult('error','已阻止全量重检并生成',`当前有 ${server.onlineCount} 名玩家在线`,'该操作可能阻塞服务器主线程，必须等所有玩家离线后再执行。');return}
    const typed=prompt('高风险：此操作会立即全量生成缺失地图块，可能长时间占满 CPU，期间玩家可能无法连接，停止命令也可能无法执行。\n\n确认继续请输入：全量生成');
    if(typed!=='全量生成'){if(typed!==null)renderWorldgenResult('warning','确认文字不匹配','操作未提交','必须完整输入“全量生成”才会执行。');return}confirmation='RECHECK_ALL';
  }else if(mode==='start'){
    if(server?.onlineKnown&&Number(server.onlineCount)>0){renderWorldgenResult('error','已阻止启动世界生成',`当前有 ${server.onlineCount} 名玩家在线`,'世界生成会显著增加服务器负载，必须等所有玩家离线后再执行。');return}
    if(!confirm('确认启动世界生成？生成期间会显著增加 CPU、内存和磁盘负载。'))return;confirmation='CONFIRM';
  }else if(mode==='stop'&&!confirm('确认发送紧急停止世界生成命令？'))return;
  const serial=++worldgenSerial,serverId=selectedId;renderWorldgenResult('running',`正在${worldgenLabels[mode]||mode}`,'正在将命令写入受控队列','等待托管通道接收命令...');
  const data=await command({action:'worldgen',mode,confirm:confirmation});if(serial!==worldgenSerial||serverId!==selectedId)return;
  if(!data){renderWorldgenResult('error','世界生成命令未能提交','服务器拒绝或命令通道不可用','请查看页面右上角错误提示。');return}
  renderWorldgenResult('queued','命令已进入队列',`命令 ${data.command} · ${new Date().toLocaleTimeString('zh-CN',{hour12:false})}`,'正在等待服务器接收并返回结果...');
  if(data.requestId)followWorldgenResult(serverId,data.requestId,serial);else renderWorldgenResult('warning','命令已提交但没有结果编号','无法自动跟踪返回','可再次执行“查询状态”确认。');
}
document.querySelector('#worldgenForm').onsubmit=event=>{event.preventDefault();runWorldgen(formData(event.target).mode)};
document.querySelector('#luaForm').onsubmit=event=>{event.preventDefault();const data=formData(event.target);if(confirm(`确认热重载 ${data.file}？错误重载可能影响当前会话。`))command({action:'lua-reload',...data,confirm:'CONFIRM'})};
document.querySelector('#logLevelForm').onsubmit=event=>{event.preventDefault();command({action:'log-level',...formData(event.target)})};

const formatBytes=(value,rate=false)=>{const number=Number(value)||0,units=['B','KB','MB','GB','TB'];let size=number,index=0;while(size>=1024&&index<units.length-1){size/=1024;index+=1}return`${size.toFixed(index<2?0:1)} ${units[index]}${rate?'/s':''}`};
const formatHostUptime=seconds=>{const days=Math.floor(seconds/86400),hours=Math.floor(seconds%86400/3600),minutes=Math.floor(seconds%3600/60);return days?`${days} 天 ${hours} 小时`:`${hours} 小时 ${minutes} 分`};
function renderHostControl(control={}){
  hostControlState=control;const startup=control.startupTask||{},autoLogon=control.autoLogon||{},authorized=Boolean(control.authorized),pending=Boolean(control.restartPending);
  const badge=document.querySelector('#hostControlBadge'),startupButton=document.querySelector('#toggleHostStartup'),restartButton=document.querySelector('#restartPhysicalHost'),cancelButton=document.querySelector('#cancelHostRestart');
  badge.textContent=authorized?'admin 已授权':'仅 admin 可操作';badge.className=`badge ${authorized?'running':'neutral'}`;
  document.querySelector('#hostStartupDetail').textContent=startup.installed&&startup.enabled?`已启用 · ${startup.userId||'当前管理员'} · 登录前启动`:'未启用，机器重启后 Web 不会自动恢复';
  startupButton.dataset.enabled=String(Boolean(startup.installed&&startup.enabled));startupButton.querySelector('span').textContent=startup.installed&&startup.enabled?'停用':'启用';startupButton.disabled=!authorized;
  document.querySelector('#hostAutoLogonDetail').textContent=autoLogon.enabled?`已启用 · ${[autoLogon.domainName,autoLogon.userName].filter(Boolean).join('\\')||'Windows 用户'}`:'未启用；Web 开机任务不依赖桌面登录';
  const running=(control.runningServers||[]).map(item=>`${item.name}${item.javaPid?` (PID ${item.javaPid})`:''}`);
  document.querySelector('#hostRestartDetail').textContent=pending?`Windows 重启倒计时进行中 · ${formatDate(control.restartExecuteAt)}`:running.length?`请先保存并停止：${running.join('、')}`:'全部游戏服务器已停止，可以安全重启物理机';
  restartButton.disabled=!authorized||!control.allServersStopped||pending;cancelButton.hidden=!pending;cancelButton.disabled=!authorized;
  lucide.createIcons();
}
function renderSystem(data){
  const host=data.host||{},processes=data.processes||[],netTotal=(data.network||[]).reduce((sum,item)=>sum+(Number(item.bytesPerSecond)||0),0);
  document.querySelector('#hostCpu').textContent=`${host.cpuPercent??0}%`;document.querySelector('#hostCores').textContent=`${host.cpuName||''} · ${host.physicalCores||0} 核 / ${host.logicalProcessors||0} 线程`;
  document.querySelector('#hostMemory').textContent=`${formatBytes(host.memoryUsedBytes)} / ${formatBytes(host.memoryTotalBytes)}`;document.querySelector('#hostMemoryDetail').textContent=`可用 ${formatBytes(host.memoryAvailableBytes)}`;
  document.querySelector('#hostNetwork').textContent=formatBytes(netTotal,true);document.querySelector('#hostUptime').textContent=formatHostUptime(host.uptimeSeconds||0);document.querySelector('#systemSampleTime').textContent=`采样 ${formatDate(data.sampledAt)}`;
  document.querySelector('#systemProcesses').innerHTML=`<div class="system-table-head"><span>进程</span><span>CPU</span><span>工作集（峰值）</span><span>线程</span><span>允许逻辑处理器</span></div>${processes.map(process=>`<div class="system-table-row"><span><strong>${escapeHtml(process.name)}</strong><small>${process.kind==='panel'?'Web 面板':escapeHtml(process.serverId)} · PID ${process.pid}</small></span><b>${Number(process.cpuPercent).toFixed(2)}%</b><code>${formatBytes(process.workingSetBytes)}（${formatBytes(process.peakWorkingSetBytes)}）</code><code>${process.threadCount}</code><small>${process.affinity?.length===host.logicalProcessors?'全部':escapeHtml((process.affinity||[]).join(', ')||'未知')}</small></div>`).join('')||'<p class="empty-state compact">没有可显示的进程。</p>'}`;
  const selectedServer=lastStatus?.servers?.find(server=>server.id===selectedId),serverProcesses=processes.filter(process=>process.kind==='server'),serverScopes=serverProcesses.map((process,index)=>({process,slot:index%4,affinity:new Set(process.affinity||[])})),serverProcess=serverProcesses.find(process=>process.serverId===selectedId),affinity=new Set(serverProcess?.affinity||[]),coreLoads=data.logicalProcessors||[];
  const scope=document.querySelector('#cpuCoreScope');scope.textContent=serverProcess?`${serverProcess.name} · PID ${serverProcess.pid} · ${affinity.size}/${host.logicalProcessors||coreLoads.length}`:`${selectedServer?.name||'所选服务器'}未运行`;scope.className=`badge ${serverProcess?'running':'neutral'}`;
  document.querySelector('#cpuServerLegend').innerHTML=serverScopes.map(({process,slot,affinity:scopeAffinity})=>`<span class="cpu-server-key server-slot-${slot}${process.serverId===selectedId?' selected':''}"><i></i><strong>${escapeHtml(process.name)}</strong><small>PID ${process.pid} · ${scopeAffinity.size}/${host.logicalProcessors||coreLoads.length} 核</small></span>`).join('')||'<p class="empty-state compact">当前没有运行中的游戏服务器进程。</p>';
  document.querySelector('#cpuCoreGrid').innerHTML=coreLoads.map(core=>{const coreIndex=Number(core.index),load=Math.max(0,Math.min(100,Number(core.usagePercent)||0)),allowed=Boolean(serverProcess&&affinity.has(coreIndex)),level=load>=85?'critical':load>=60?'busy':load>=30?'warm':'idle',coreServers=serverScopes.filter(item=>item.affinity.has(coreIndex)),serverNames=coreServers.map(item=>item.process.name),title=`逻辑处理器 ${core.index} · 主机占用 ${load.toFixed(1)}% · 允许调度：${serverNames.join('、')||'无受管服务器'}`,serverTags=coreServers.map(({process,slot})=>`<span class="cpu-core-server server-slot-${slot}" title="${escapeHtml(process.name)} · PID ${process.pid}">${escapeHtml(process.name)}</span>`).join('');return`<div class="cpu-core-tile ${level} ${allowed?'allowed':'outside'}" data-core-index="${coreIndex}" title="${escapeHtml(title)}"><span class="cpu-core-fill" style="height:${load}%"></span><div class="cpu-core-head"><span><small>CPU</small><strong>${core.index}</strong></span><b>${Math.round(load)}%</b></div><div class="cpu-core-servers">${serverTags||'<span class="cpu-core-server empty">无</span>'}</div></div>`}).join('')||'<p class="empty-state compact">当前系统没有返回逐核占用。</p>';
  document.querySelector('#systemDisks').innerHTML=(data.disks||[]).map(disk=>{const percent=disk.totalBytes?Math.round(disk.usedBytes/disk.totalBytes*100):0;return`<div class="resource-row"><div><strong>${escapeHtml(disk.drive)} ${escapeHtml(disk.label||'本地磁盘')}</strong><span>${formatBytes(disk.usedBytes)} / ${formatBytes(disk.totalBytes)}</span></div><progress max="100" value="${percent}"></progress><small>已用 ${percent}% · 可用 ${formatBytes(disk.freeBytes)}</small></div>`}).join('')||'<p class="empty-state compact">没有固定磁盘数据。</p>';
  document.querySelector('#systemNetwork').innerHTML=(data.network||[]).map(adapter=>`<div class="resource-row network-row"><div><strong>${escapeHtml(adapter.name)}</strong><span>${escapeHtml(adapter.linkSpeed||adapter.description||'')}</span></div><div class="network-rates"><span>接收 <b>${formatBytes(adapter.receiveBytesPerSecond,true)}</b></span><span>发送 <b>${formatBytes(adapter.sendBytesPerSecond,true)}</b></span></div></div>`).join('')||'<p class="empty-state compact">没有活动网卡数据。</p>';
  renderHostControl(data.hostControl||{});
}
async function pollSystem(){if(systemBusy||activeView!=='system')return;systemBusy=true;try{renderSystem(await api('/api/system'))}catch(error){document.querySelector('#systemSampleTime').textContent=error.message}finally{systemBusy=false}}
document.querySelector('#toggleHostStartup').onclick=async event=>{const enabled=event.currentTarget.dataset.enabled!=='true',verb=enabled?'启用':'停用';if(!confirm(`确认${verb} Web 面板开机启动任务？`))return;event.currentTarget.disabled=true;try{const result=await api('/api/host/startup-task',{method:'POST',body:JSON.stringify({enabled,confirm:'CHANGE_HOST_STARTUP'})});toast(result.message);await pollSystem()}catch(error){toast(error.message,true)}finally{if(hostControlState)renderHostControl(hostControlState)}};
document.querySelector('#openHostAutoLogon').onclick=()=>{if(!confirm('将下载本机配置启动脚本。运行后只在微软 Sysinternals Autologon 中输入 Windows 密码，确认继续？'))return;location.href='/api/host/autologon/launcher';toast('本机配置启动脚本已下载。')};
document.querySelector('#restartPhysicalHost').onclick=async()=>{const typed=prompt('这会重新启动整台 Windows 物理机。请输入“重启物理机”确认：','');if(typed===null)return;if(typed!=='重启物理机'){toast('确认文字不匹配，物理机不会重启。',true);return}try{const result=await api('/api/host/restart',{method:'POST',body:JSON.stringify({confirm:'RESTART_PHYSICAL_HOST'})});toast(result.message);await pollSystem()}catch(error){toast(error.message,true)}};
document.querySelector('#cancelHostRestart').onclick=async()=>{if(!confirm('确认取消 Windows 物理机重启倒计时？'))return;try{const result=await api('/api/host/restart/cancel',{method:'POST',body:JSON.stringify({confirm:'CANCEL_HOST_RESTART'})});toast(result.message);await pollSystem()}catch(error){toast(error.message,true)}};

const sleep=milliseconds=>new Promise(resolve=>setTimeout(resolve,milliseconds));
async function followLifecycle(serverId,done,successMessage){
  for(let attempt=0;attempt<180;attempt+=1){
    await sleep(1000);await refreshStatus();
    const server=lastStatus?.servers?.find(item=>item.id===serverId);
    if(!server)return false;
    if(done(server)){if(successMessage)toast(successMessage);return true}
    if(!server.alive&&attempt>=1){toast(`${server.name} 启动后提前退出，请查看执行历史或服务器日志。`,true);return false}
  }
  toast('等待服务器状态变化超时，请查看维护页执行反馈。',true);return false;
}
const lifecycleActionLabels={stop:'保存并停止',restart:'安全重启',update:'安全更新服务器程序'};
const lifecycleStageLabels={queued:'等待后台执行',locking:'取得操作锁',notifying:'发送维护通知',countdown:'等待玩家准备',saving:'保存世界',quitting:'正常退出',"waiting-stop":'等待 Java 结束',stabilizing:'释放内存与端口',updating:'SteamCMD 更新中',"verifying-update":'校验更新结果',starting:'启动新实例',"waiting-running":'等待新 Java 运行',completed:'操作完成',failed:'操作失败'};
const lifecycleStageMessages={queued:'操作已提交，等待后台执行器启动。',locking:'正在取得服务器生命周期操作锁。',notifying:'正在发送原生全服广播和右下角弹窗。',countdown:'维护通知已发送，正在等待玩家准备。',saving:'正在保存世界，并等待受控通道确认。',quitting:'保存已确认，正在请求服务器正常退出。',"waiting-stop":'退出命令已送达，正在等待旧 Java 进程完全结束。',stabilizing:'旧 Java 已结束，正在等待大内存、端口和 Steam 网络资源完全释放。',updating:'正在通过 SteamCMD 更新 AppID 380870 的 public 分支。',"verifying-update":'SteamCMD 已结束，正在校验 BuildID 和成功标记。',starting:'资源释放缓冲已结束，正在启动新实例。',"waiting-running":'启动脚本已执行，正在等待新 Java 进入运行状态。',completed:'操作已完成。',failed:'操作失败，请查看下方原因。'};
function renderLifecycleOperation(operation){
  const panel=document.querySelector('#lifecycleStatus'),error=document.querySelector('#lifecycleError'),detail=document.querySelector('#lifecycleDetail');lifecycleOperation=operation||null;if(!operation){panel.dataset.state='idle';document.querySelector('#lifecycleTitle').textContent='当前没有生命周期操作';document.querySelector('#lifecycleBadge').textContent='空闲';document.querySelector('#lifecycleMessage').textContent='执行停止、安全重启或程序更新后，这里会显示每个阶段。';document.querySelector('#lifecycleStarted').textContent='--';document.querySelector('#lifecycleOldPid').textContent='--';document.querySelector('#lifecycleNewPid').textContent='--';detail.hidden=true;error.hidden=true;renderCurrentServer();return}
  const countdownTarget=operation.stage==='countdown'?operation.countdownUntil:operation.stage==='stabilizing'?operation.stabilizationUntil:null;
  const secondsLeft=countdownTarget?Math.max(0,Math.ceil((new Date(countdownTarget)-Date.now())/1000)):null;
  const timedMessage=operation.stage==='countdown'?`维护通知已发送，约 ${secondsLeft} 秒后开始维护。${operation.warnings?.length?' 部分通知通道不可用，已使用可用通道继续。':''}`:operation.stage==='stabilizing'?`旧 Java 已完全结束，正在释放大内存、端口和 Steam 资源，约 ${secondsLeft} 秒后启动新实例。`:null;
  panel.dataset.state=operation.status;document.querySelector('#lifecycleTitle').textContent=`${lifecycleActionLabels[operation.action]||operation.action} · ${lifecycleStageLabels[operation.stage]||operation.stage}`;document.querySelector('#lifecycleBadge').textContent=operation.status==='completed'?'成功':operation.status==='failed'?'失败':operation.status==='queued'?'排队中':'执行中';document.querySelector('#lifecycleMessage').textContent=timedMessage||(operation.message||lifecycleStageMessages[operation.stage]||'正在处理...');document.querySelector('#lifecycleStarted').textContent=formatDate(operation.startedAt);document.querySelector('#lifecycleOldPid').textContent=operation.oldJavaPid||'--';document.querySelector('#lifecycleNewPid').textContent=operation.newJavaPid||'--';detail.hidden=!operation.detail;detail.textContent=operation.detail||'';error.hidden=!operation.error;error.textContent=operation.error||'';renderCurrentServer();
}
async function refreshLifecycleStatus(operationId=''){
  if(!selectedId)return null;const serverId=selectedId,params=new URLSearchParams({serverId});if(operationId)params.set('id',operationId);
  try{const data=await api(`/api/server/operation?${params}`);if(serverId!==selectedId)return null;renderLifecycleOperation(data.operation);return data.operation}catch(error){if(activeView==='maintenance')renderLifecycleOperation({action:'restart',status:'failed',stage:'failed',message:'无法读取生命周期状态。',error:error.message});return null}
}
async function followLifecycleOperation(serverId,operationId,serial){
  for(let attempt=0;attempt<1800;attempt+=1){
    await sleep(attempt?1000:350);if(serial!==lifecycleSerial||serverId!==selectedId)return;
    const operation=await refreshLifecycleStatus(operationId);if(serial!==lifecycleSerial||serverId!==selectedId)return;
    await refreshStatus();
    if(operation?.status==='completed'){toast(`${lifecycleActionLabels[operation.action]||'服务器操作'}已完成。`);refreshAudit();refreshExecutionHistory();refreshProgramUpdateStatus();return}
    if(operation?.status==='failed'){toast(operation.error||operation.message||'服务器操作失败。',true);refreshAudit();refreshExecutionHistory();refreshProgramUpdateStatus();return}
  }
  toast('生命周期操作等待超时，后台状态仍会保留在维护页。',true);
}
document.querySelector('#stopServer').onclick=async()=>{const server=currentServer(),serverId=selectedId;if(!server||!confirm(`确认保存世界并停止 ${server.name}？`))return;try{const data=await api('/api/server/stop',{method:'POST',body:JSON.stringify({serverId,confirm:'SAVE_AND_STOP'})});toast(data.message);showView('maintenance');const serial=++lifecycleSerial;followLifecycleOperation(serverId,data.operationId,serial)}catch(error){toast(error.message,true)}};
document.querySelector('#restartServer').onclick=async()=>{const server=currentServer(),serverId=selectedId,warningSeconds=Number(document.querySelector('#restartWarningSeconds').value),restartStabilizationSeconds=Number(document.querySelector('#restartStabilizationSeconds').value);if(!server)return;if(!Number.isInteger(warningSeconds)||warningSeconds<10||warningSeconds>600){toast('通知倒计时必须为 10 至 600 秒。',true);return}if(!Number.isInteger(restartStabilizationSeconds)||restartStabilizationSeconds<10||restartStabilizationSeconds>600){toast('停服后启动缓冲必须为 10 至 600 秒。',true);return}if(!confirm(`确认安全重启 ${server.name}？将先广播并弹窗通知，等待 ${warningSeconds} 秒后保存退出；旧 Java 完全结束后再缓冲 ${restartStabilizationSeconds} 秒启动。`))return;try{const data=await api('/api/server/restart',{method:'POST',body:JSON.stringify({serverId,confirm:'SAVE_QUIT_RESTART',warningSeconds,restartStabilizationSeconds})});toast(data.message);showView('maintenance');const serial=++lifecycleSerial;followLifecycleOperation(serverId,data.operationId,serial)}catch(error){toast(error.message,true)}};
const adminSetupDialog=document.querySelector('#adminSetupDialog'),adminSetupForm=document.querySelector('#adminSetupForm'),adminSetupError=document.querySelector('#adminSetupError');
function clearAdminSetupFields(){adminSetupForm.reset();adminSetupForm.dataset.serverId='';adminSetupError.textContent=''}
function closeAdminSetupDialog(){if(!adminSetupDialog)return;clearAdminSetupFields();if(adminSetupDialog.open)adminSetupDialog.close()}
function openAdminSetupDialog(server){clearAdminSetupFields();adminSetupForm.dataset.serverId=server.id;document.querySelector('#adminSetupServerName').textContent=`${server.name}（${server.serverName}）`;adminSetupDialog.showModal();setTimeout(()=>adminSetupForm.elements.adminPassword.focus(),0)}
async function startSelectedServer(serverId,adminPassword='',adminPasswordConfirm=''){
  const server=lastStatus?.servers?.find(item=>item.id===serverId);if(!server||server.id!==selectedId)throw new Error('所选服务器已经改变，请重新操作。');
  const button=document.querySelector('#startServer');button.disabled=true;toast(`正在启动 ${server.name}...`);
  try{const body={serverId};if(adminPassword||adminPasswordConfirm){body.adminPassword=adminPassword;body.adminPasswordConfirm=adminPasswordConfirm}const data=await api('/api/server/start',{method:'POST',body:JSON.stringify(body)});toast(data.message);followLifecycle(serverId,state=>state.alive&&state.status==='running',`${server.name} 已进入运行状态。`);return true}
  catch(error){toast(error.message,true);try{await refreshStatus()}catch{}throw error}
  finally{const current=currentServer();if(serverId===selectedId){if(current)renderCurrentServer();else button.disabled=false}}
}
document.querySelector('#startServer').onclick=event=>{const server=currentServer();if(!server)return;if(server.adminSetupRequired){openAdminSetupDialog(server);return}startSelectedServer(server.id).catch(()=>{})};
adminSetupForm.addEventListener('input',()=>{const password=adminSetupForm.elements.adminPassword.value,confirmPassword=adminSetupForm.elements.confirmPassword.value;if(confirmPassword&&password!==confirmPassword)adminSetupError.textContent='两次输入的密码不一致。';else adminSetupError.textContent=''});
adminSetupForm.onsubmit=async event=>{event.preventDefault();const serverId=adminSetupForm.dataset.serverId,password=adminSetupForm.elements.adminPassword.value,confirmPassword=adminSetupForm.elements.confirmPassword.value,submit=adminSetupForm.querySelector('button[type="submit"]');adminSetupError.textContent='';if(password!==confirmPassword){adminSetupError.textContent='两次输入的密码不一致。';adminSetupForm.elements.confirmPassword.focus();return}if(password.length<8){adminSetupError.textContent='密码至少需要 8 个字符。';adminSetupForm.elements.adminPassword.focus();return}submit.disabled=true;try{await startSelectedServer(serverId,password,confirmPassword);closeAdminSetupDialog()}catch(error){adminSetupError.textContent=error.message;adminSetupForm.elements.adminPassword.value='';adminSetupForm.elements.confirmPassword.value='';adminSetupForm.elements.adminPassword.focus()}finally{submit.disabled=false}};
document.querySelector('#closeAdminSetup').onclick=closeAdminSetupDialog;document.querySelector('#cancelAdminSetup').onclick=closeAdminSetupDialog;adminSetupDialog.addEventListener('cancel',event=>{event.preventDefault();closeAdminSetupDialog()});
async function refreshAudit(){try{const data=await api('/api/audit');document.querySelector('#auditOutput').textContent=data.lines.join('\n')||'暂无操作'}catch{}}
document.querySelector('#refreshAudit').onclick=refreshAudit;

const executionStatusLabels={queued:'排队',running:'执行中',success:'成功',warning:'警告',failed:'失败'};
const executionCategoryLabels={query:'查询',command:'命令',item:'物品',broadcast:'广播',update:'更新检查',lifecycle:'生命周期'};
function renderExecutionHistory(){
  const list=document.querySelector('#executionHistoryList');
  list.innerHTML=executionHistory.length?executionHistory.map(item=>`<details class="execution-history-row" data-status="${escapeHtml(item.status)}"><summary><time>${formatDate(item.createdAt)}</time><b>${escapeHtml(executionCategoryLabels[item.category]||item.category)}</b><strong>${escapeHtml(item.summary||item.action)}</strong><span class="execution-status">${escapeHtml(executionStatusLabels[item.status]||item.status)}</span><small>${escapeHtml(item.source==='scheduled'?'定时任务':item.source==='ai'?'AI':'Web')}</small></summary><div class="execution-history-detail"><p>${escapeHtml(item.message||'没有结果说明')}</p>${item.detail?`<pre>${escapeHtml(item.detail)}</pre>`:''}<dl><div><dt>动作</dt><dd>${escapeHtml(item.action||'--')}</dd></div><div><dt>结果码</dt><dd>${escapeHtml(item.resultCode||'--')}</dd></div><div><dt>更新时间</dt><dd>${formatDate(item.updatedAt)}</dd></div></dl></div></details>`).join(''):'<p class="empty-state compact">当前筛选条件没有执行记录。</p>';
  document.querySelector('#executionHistoryPage').textContent=`第 ${executionHistoryPage} / ${executionHistoryTotalPages} 页`;
  document.querySelector('#executionHistorySummary').textContent=`共 ${executionHistoryTotal} 条 · 每页 ${executionHistoryPageSize} 条`;
  document.querySelector('#executionHistoryPrevious').disabled=executionHistoryPage<=1;
  document.querySelector('#executionHistoryNext').disabled=executionHistoryPage>=executionHistoryTotalPages;
}
async function refreshExecutionHistory(){if(!selectedId)return;const serverId=selectedId,filter=document.querySelector('#executionHistoryFilter').value,params=new URLSearchParams({serverId,page:String(executionHistoryPage),pageSize:String(executionHistoryPageSize)});if(filter!=='all')params.set('category',filter);try{const data=await api(`/api/execution-history?${params}`);if(serverId!==selectedId)return;executionHistory=data.records||[];executionHistoryPage=Number(data.page||1);executionHistoryPageSize=Number(data.pageSize||30);executionHistoryTotal=Number(data.total??executionHistory.length);executionHistoryTotalPages=Number(data.totalPages||Math.max(1,Math.ceil(executionHistoryTotal/executionHistoryPageSize)));renderExecutionHistory()}catch(error){if(serverId===selectedId)document.querySelector('#executionHistoryList').innerHTML=`<p class="empty-state compact error-text">${escapeHtml(error.message)}</p>`}}
document.querySelector('#executionHistoryFilter').onchange=()=>{executionHistoryPage=1;refreshExecutionHistory()};document.querySelector('#refreshExecutionHistory').onclick=()=>{executionHistoryPage=1;refreshExecutionHistory()};document.querySelector('#executionHistoryPrevious').onclick=()=>{if(executionHistoryPage<=1)return;executionHistoryPage-=1;refreshExecutionHistory()};document.querySelector('#executionHistoryNext').onclick=()=>{if(executionHistoryPage>=executionHistoryTotalPages)return;executionHistoryPage+=1;refreshExecutionHistory()};

const saveBackupPlanForm=document.querySelector('#saveBackupPlanForm');
function updateSaveBackupInputs(){
  saveBackupPlanForm.elements.saveIntervalMinutes.disabled=!saveBackupPlanForm.elements.autoSaveEnabled.checked;
  saveBackupPlanForm.elements.backupIntervalMinutes.disabled=!saveBackupPlanForm.elements.autoBackupEnabled.checked;
}
function renderSaveBackupPlan(data){
  saveBackupPlan=data;saveBackupPlanForm.elements.autoSaveEnabled.checked=Boolean(data.autoSaveEnabled);saveBackupPlanForm.elements.saveIntervalMinutes.value=data.saveIntervalMinutes||10;saveBackupPlanForm.elements.autoBackupEnabled.checked=Boolean(data.autoBackupEnabled);saveBackupPlanForm.elements.backupIntervalMinutes.value=data.backupIntervalMinutes||60;saveBackupPlanForm.elements.backupCount.value=data.backupCount||3;updateSaveBackupInputs();
  const enabledCount=Number(Boolean(data.autoSaveEnabled))+Number(Boolean(data.autoBackupEnabled)),badge=document.querySelector('#saveBackupPlanBadge');badge.textContent=enabledCount===2?'全部启用':enabledCount===1?'部分启用':'未启用';badge.className=`badge ${enabledCount?'running':'neutral'}`;
  document.querySelector('#saveBackupLatest').textContent=data.latestBackupAt?`${formatDate(data.latestBackupAt)} · ${formatBytes(data.latestBackupBytes)}`:'暂无定时备份';
  document.querySelector('#saveBackupFiles').textContent=`${Number(data.backupFileCount||0)} 份 / 保留 ${Number(data.backupCount||0)} 份`;
  document.querySelector('#saveBackupSize').textContent=formatBytes(data.backupTotalBytes);
  document.querySelector('#saveBackupNext').textContent=data.autoBackupEnabled?(data.nextBackupAt?formatDate(data.nextBackupAt):'等待首次备份'):'未启用';
  document.querySelector('#saveBackupPlanResult').textContent=data.message||`备份目录：${data.backupDirectory}`;
}
async function refreshSaveBackupPlan(){if(!selectedId||saveBackupBusy)return;const serverId=selectedId;try{const data=await api(`/api/maintenance/save-backup?serverId=${encodeURIComponent(serverId)}`);if(serverId===selectedId)renderSaveBackupPlan(data)}catch(error){if(serverId===selectedId)document.querySelector('#saveBackupPlanResult').textContent=error.message}}
[saveBackupPlanForm.elements.autoSaveEnabled,saveBackupPlanForm.elements.autoBackupEnabled].forEach(input=>input.onchange=updateSaveBackupInputs);
saveBackupPlanForm.onsubmit=async event=>{event.preventDefault();if(!selectedId||saveBackupBusy)return;const saveIntervalMinutes=Number(event.currentTarget.elements.saveIntervalMinutes.value),backupIntervalMinutes=Number(event.currentTarget.elements.backupIntervalMinutes.value),backupCount=Number(event.currentTarget.elements.backupCount.value);if(!Number.isInteger(saveIntervalMinutes)||saveIntervalMinutes<1||saveIntervalMinutes>1440){toast('自动保存间隔必须为 1 至 1440 分钟。',true);return}if(!Number.isInteger(backupIntervalMinutes)||backupIntervalMinutes<15||backupIntervalMinutes>1500){toast('自动备份间隔必须为 15 至 1500 分钟。',true);return}if(!Number.isInteger(backupCount)||backupCount<1||backupCount>300){toast('备份保留数量必须为 1 至 300 份。',true);return}saveBackupBusy=true;const submit=event.currentTarget.querySelector('button[type="submit"]');submit.disabled=true;try{const result=await api('/api/maintenance/save-backup',{method:'PUT',body:JSON.stringify({serverId:selectedId,autoSaveEnabled:event.currentTarget.elements.autoSaveEnabled.checked,saveIntervalMinutes,autoBackupEnabled:event.currentTarget.elements.autoBackupEnabled.checked,backupIntervalMinutes,backupCount})});renderSaveBackupPlan(result);toast(result.message);refreshExecutionHistory()}catch(error){toast(error.message,true)}finally{saveBackupBusy=false;submit.disabled=false}};

const maintenanceStatusLabels={never:'尚未执行',checking:'检查中',current:'无需更新','update-required':'发现更新','auto-restart-queued':'自动重启已提交','auto-restart-failed':'自动重启失败','notification-failed':'通知失败',skipped:'已跳过',interrupted:'检查中断',failed:'检查失败','no-result':'结果不明确'};
function renderMaintenanceSchedule(data){
  maintenanceSchedule=data;const form=document.querySelector('#maintenanceScheduleForm');form.elements.enabled.checked=Boolean(data.enabled);form.elements.intervalHours.value=data.intervalHours||3;form.elements.restartStabilizationSeconds.value=data.restartStabilizationSeconds||60;form.elements.autoRestartOnUpdate.checked=Boolean(data.autoRestartOnUpdate);
  const badge=document.querySelector('#maintenanceScheduleBadge');badge.textContent=data.running?'检查中':data.enabled?'已启用':'未启用';badge.className=`badge ${data.running||data.enabled?'running':'neutral'}`;
  const updateHandling=data.autoRestartOnUpdate?(data.lastAutoRestartOperationId?`自动重启已提交 · ${formatDate(data.lastAutoRestartAt)}`:`自动重启 · 60 秒通知 + ${data.restartStabilizationSeconds||60} 秒停服缓冲`):(data.updateNotificationPending?`已通知 · ${formatDate(data.lastNotificationAt)}`:'仅通知，不自动重启');
  document.querySelector('#maintenanceNextRun').textContent=data.enabled?formatDate(data.nextRunAt):'未启用';document.querySelector('#maintenanceLastRun').textContent=formatDate(data.lastRunAt);document.querySelector('#maintenanceLastResult').textContent=maintenanceStatusLabels[data.lastStatus]||data.lastStatus||'尚未执行';document.querySelector('#maintenanceNotification').textContent=updateHandling;document.querySelector('#maintenanceResult').textContent=data.lastMessage||'尚未执行自动 Mod 更新检查。';document.querySelector('#maintenanceCheckNow').disabled=Boolean(data.running)||maintenanceBusy;
}
async function refreshMaintenanceSchedule(){if(!selectedId||maintenanceBusy)return;const serverId=selectedId;try{const data=await api(`/api/maintenance/schedule?serverId=${encodeURIComponent(serverId)}`);if(serverId===selectedId)renderMaintenanceSchedule(data)}catch(error){if(activeView==='maintenance')document.querySelector('#maintenanceResult').textContent=error.message}}
document.querySelector('#maintenanceScheduleForm').onsubmit=async event=>{event.preventDefault();if(!selectedId)return;const data=formData(event.currentTarget),intervalHours=Number(data.intervalHours),restartStabilizationSeconds=Number(data.restartStabilizationSeconds),autoRestartOnUpdate=Boolean(event.currentTarget.elements.autoRestartOnUpdate.checked);if(!Number.isInteger(intervalHours)||intervalHours<1||intervalHours>168){toast('自动检查间隔必须为 1 至 168 小时。',true);return}if(!Number.isInteger(restartStabilizationSeconds)||restartStabilizationSeconds<10||restartStabilizationSeconds>600){toast('停服后启动缓冲必须为 10 至 600 秒。',true);return}if(autoRestartOnUpdate&&!maintenanceSchedule?.autoRestartOnUpdate&&!confirm(`确认启用发现 Mod 更新后自动安全重启？系统会立即发送原生广播和 PZWebNotices 弹窗，60 秒后保存退出，并在旧 Java 完全结束后再缓冲 ${restartStabilizationSeconds} 秒启动。`))return;maintenanceBusy=true;try{const result=await api('/api/maintenance/schedule',{method:'PUT',body:JSON.stringify({serverId:selectedId,enabled:Boolean(event.currentTarget.elements.enabled.checked),intervalHours,autoRestartOnUpdate,restartStabilizationSeconds})});renderMaintenanceSchedule(result);toast(result.message)}catch(error){toast(error.message,true)}finally{maintenanceBusy=false;document.querySelector('#maintenanceCheckNow').disabled=Boolean(maintenanceSchedule?.running)}};
document.querySelector('#maintenanceCheckNow').onclick=async()=>{if(!selectedId||maintenanceBusy)return;maintenanceBusy=true;document.querySelector('#maintenanceCheckNow').disabled=true;try{const result=await api('/api/maintenance/check-now',{method:'POST',body:JSON.stringify({serverId:selectedId})});renderMaintenanceSchedule(result);toast(result.message)}catch(error){toast(error.message,true)}finally{maintenanceBusy=false;document.querySelector('#maintenanceCheckNow').disabled=Boolean(maintenanceSchedule?.running);setTimeout(refreshMaintenanceSchedule,1000)}};

function renderProgramUpdateStatus(data={}){
  programUpdateStatus=data;const section=document.querySelector('.program-update'),badge=document.querySelector('#programUpdateBadge');
  document.querySelector('#programLocalVersion').textContent=data.localVersion||'未识别';document.querySelector('#programLocalBuild').textContent=data.localBuildId||'无本地清单';document.querySelector('#programRemoteBuild').textContent=data.remoteBuildId||'尚未检查';document.querySelector('#programSteamCmd').textContent=data.steamCmdAvailable?'已找到':'未找到';
  const state=data.error?'error':data.updateAvailable?'available':data.current?'current':'idle';section.dataset.state=state;
  badge.className=`badge ${state==='current'?'running':state==='available'||state==='error'?'stopped':'neutral'}`;badge.textContent=data.error?'检查失败':data.updateAvailable?'有可用更新':data.current?'已是最新':'尚未检查';
  if(data.message)document.querySelector('#programUpdateResult').textContent=data.message;else if(!data.steamCmdAvailable)document.querySelector('#programUpdateResult').textContent='未找到 SteamCMD，检查和更新按钮不可用。';else document.querySelector('#programUpdateResult').textContent='这里检查的是游戏服务器本体，不是 Mod。检查不会停服；更新会通知玩家，然后保存、退出、更新并重新启动。';
  document.querySelector('#checkProgramUpdate').disabled=programUpdateBusy||!data.steamCmdAvailable;document.querySelector('#applyProgramUpdate').disabled=programUpdateBusy||!data.steamCmdAvailable;
}
async function refreshProgramUpdateStatus(){if(!selectedId||programUpdateBusy)return;const serverId=selectedId;try{const data=await api(`/api/server/program-update?serverId=${encodeURIComponent(serverId)}`);if(serverId===selectedId)renderProgramUpdateStatus(data)}catch(error){if(serverId===selectedId)renderProgramUpdateStatus({error:error.message,message:error.message})}}
document.querySelector('#checkProgramUpdate').onclick=async()=>{if(!selectedId||programUpdateBusy)return;const serverId=selectedId;programUpdateBusy=true;document.querySelector('#checkProgramUpdate').disabled=true;document.querySelector('#applyProgramUpdate').disabled=true;document.querySelector('#programUpdateResult').textContent='正在通过 SteamCMD 查询 public 分支 BuildID...';try{const result=await api('/api/server/program-update/check',{method:'POST',body:JSON.stringify({serverId}),timeoutMs:120000});if(serverId!==selectedId)return;renderProgramUpdateStatus(result);toast(result.message);refreshExecutionHistory()}catch(error){if(serverId===selectedId)renderProgramUpdateStatus({...programUpdateStatus,error:error.message,message:error.message});toast(error.message,true)}finally{programUpdateBusy=false;if(serverId===selectedId)renderProgramUpdateStatus(programUpdateStatus||{})}};
document.querySelector('#applyProgramUpdate').onclick=async()=>{const server=currentServer(),serverId=selectedId,warningSeconds=Number(document.querySelector('#programUpdateWarningSeconds').value);if(!server||programUpdateBusy)return;if(!Number.isInteger(warningSeconds)||warningSeconds<10||warningSeconds>600){toast('更新通知倒计时必须为 10 至 600 秒。',true);return}const state=server.alive?`将先通知玩家，等待 ${warningSeconds} 秒后保存并停服`:'服务器当前已停止，将直接更新';if(!confirm(`确认更新 ${server.name} 的服务器程序？${state}，随后更新 public 分支并启动服务器。升级存档后不要直接回退旧版本。`))return;programUpdateBusy=true;document.querySelector('#checkProgramUpdate').disabled=true;document.querySelector('#applyProgramUpdate').disabled=true;try{const result=await api('/api/server/program-update/apply',{method:'POST',body:JSON.stringify({serverId,warningSeconds,confirm:'SAVE_QUIT_UPDATE_RESTART'}),timeoutMs:120000});toast(result.message);showView('maintenance');const serial=++lifecycleSerial;followLifecycleOperation(serverId,result.operationId,serial)}catch(error){toast(error.message,true)}finally{programUpdateBusy=false;setTimeout(refreshProgramUpdateStatus,700)}};

const profileForm=document.querySelector('#profileForm');
const profileValue=(profile,key)=>profile?.[key]??'';
function updateQueueField(){document.querySelectorAll('.queue-field').forEach(field=>field.hidden=profileForm.elements.commandChannel.value!=='queue')}
function fillProfileForm(profile=null){
  editingProfileId=profile?.id||'';
  profileForm.reset();
  profileForm.elements.mode.value=profile?'update':'create';
  profileForm.elements.id.disabled=Boolean(profile);
  profileForm.elements.id.value=profileValue(profile,'id');
  profileForm.elements.name.value=profileValue(profile,'name');
  profileForm.elements.kind.value=profileValue(profile,'kind')||'custom';
  profileForm.elements.serverName.value=profileValue(profile,'serverName');
  profileForm.elements.runtimeRoot.value=profileValue(profile,'runtimeRoot');
  profileForm.elements.dataRoot.value=profileValue(profile,'dataRoot');
  profileForm.elements.javaPath.value=profileValue(profile,'javaPath');
  profileForm.elements.sourceStartScript.value=profileValue(profile,'sourceStartScript');
  profileForm.elements.streamingStabilityOptions.value=profileValue(profile,'streamingStabilityOptions');
  profileForm.elements.consoleLog.value=profileValue(profile,'consoleLog');
  profileForm.elements.ports.value=(profile?.ports||[]).join(',');
  profileForm.elements.maxPlayers.value=profileValue(profile,'maxPlayers')||32;
  profileForm.elements.lanAddress.value=profileValue(profile,'lanAddress');
  profileForm.elements.passwordRequired.value=String(Boolean(profile?.passwordRequired));
  profileForm.elements.commandChannel.value=profileValue(profile,'commandChannel')||'readonly';
  profileForm.elements.showConsole.value=String(Boolean(profile?.showConsole));
  document.querySelector('#profileFormTitle').textContent=profile?`编辑 ${profile.name}`:'添加服务器';
  document.querySelector('#profileModeBadge').textContent=profile?'编辑':'新配置';
  document.querySelector('#setDefaultProfile').disabled=!profile||profileConfig?.defaultServer===profile.id;
  document.querySelector('#deleteProfile').disabled=!profile;
  updateQueueField();
}
function renderProfiles(){
  const list=document.querySelector('#profileList');
  list.innerHTML=profileConfig.profiles.map(profile=>{
    const live=lastStatus?.servers?.find(server=>server.id===profile.id);
    return `<button type="button" class="profile-list-item ${profile.id===editingProfileId?'selected':''}" data-profile-id="${escapeHtml(profile.id)}"><span class="server-icon ${profile.kind==='production'?'prod':'test'}"><i data-lucide="${profile.kind==='production'?'server':'server-cog'}"></i></span><span><strong>${escapeHtml(profile.name)}</strong><small>${escapeHtml(profile.serverName)} · ${(profile.ports||[]).join(' / ')}</small></span>${profileConfig.defaultServer===profile.id?'<b class="badge neutral">默认</b>':''}<b class="badge ${live?.alive?'running':'stopped'}">${live?.alive?'运行中':'已停止'}</b></button>`;
  }).join('');
  list.querySelectorAll('[data-profile-id]').forEach(button=>button.onclick=()=>{const profile=profileConfig.profiles.find(item=>item.id===button.dataset.profileId);fillProfileForm(profile);renderProfiles()});
  lucide.createIcons();
}
async function refreshProfiles(){
  try{
    profileConfig=await api('/api/profiles');
    const profile=profileConfig.profiles.find(item=>item.id===editingProfileId);
    if(profile)fillProfileForm(profile);
    renderProfiles();
  }catch(error){document.querySelector('#profileList').innerHTML=`<p class="empty-state error-text">${escapeHtml(error.message)}</p>`}
}
document.querySelector('#newProfile').onclick=()=>{fillProfileForm();renderProfiles()};
document.querySelector('#scanProfiles').onclick=async()=>{
  const button=document.querySelector('#scanProfiles');button.disabled=true;
  try{const result=await api('/api/profiles/scan',{method:'POST'});toast(result.message);await refreshStatus();await refreshProfiles()}catch(error){toast(error.message,true)}finally{button.disabled=false}
};
document.querySelector('#profileChannel').onchange=updateQueueField;
profileForm.onsubmit=async event=>{
  event.preventDefault();
  const values=formData(profileForm),id=editingProfileId||values.id.trim().toLowerCase();
  const ports=values.ports.split(/[;,\s]+/).filter(Boolean).map(Number);
  const profile={...values,id,ports,maxPlayers:+values.maxPlayers,passwordRequired:values.passwordRequired==='true',showConsole:values.showConsole==='true'};
  delete profile.mode;
  try{
    const result=await api('/api/profiles/save',{method:'POST',body:JSON.stringify({mode:values.mode,profile})});
    editingProfileId=result.profile.id;toast(result.message);await refreshStatus();await refreshProfiles();
  }catch(error){toast(error.message,true)}
};
document.querySelector('#setDefaultProfile').onclick=async()=>{
  if(!editingProfileId)return;
  try{const result=await api('/api/profiles/default',{method:'POST',body:JSON.stringify({serverId:editingProfileId})});toast(result.message);await refreshStatus();await refreshProfiles()}catch(error){toast(error.message,true)}
};
document.querySelector('#deleteProfile').onclick=async()=>{
  const profile=profileConfig?.profiles.find(item=>item.id===editingProfileId);if(!profile||!confirm(`确认删除配置“${profile.name}”？不会删除游戏文件或存档。`))return;
  try{const result=await api('/api/profiles/delete',{method:'POST',body:JSON.stringify({serverId:profile.id,confirm:'DELETE_PROFILE'})});toast(result.message);editingProfileId='';await refreshStatus();await refreshProfiles();fillProfileForm()}catch(error){toast(error.message,true)}
};

const authScreen=document.querySelector('#authScreen');
const authError=document.querySelector('#authError');
function showAuth(sessionInfo={}){
  if(statusTimer)clearInterval(statusTimer);if(logTimer)clearInterval(logTimer);if(systemTimer)clearInterval(systemTimer);
  statusTimer=null;logTimer=null;systemTimer=null;appStarted=false;authSession=null;csrfToken='';
  authScreen.hidden=false;
  const setup=Boolean(sessionInfo.setupRequired);
  document.querySelector('#loginForm').hidden=setup;
  document.querySelector('#setupForm').hidden=!setup||sessionInfo.local===false;
  document.querySelector('#authModeText').textContent=setup?'首次初始化':'账号登录';
  authError.textContent=setup&&sessionInfo.local===false?'请先远程到服务器桌面，在本机 http://127.0.0.1:8790/ 创建第一个管理员。':'';
}
function enterApp(session){
  authSession=session;csrfToken=session.csrf||'';authScreen.hidden=true;authError.textContent='';
  document.querySelectorAll('.local-only').forEach(item=>item.hidden=!session.local);
  document.querySelector('#signedUser').textContent=session.user?.displayName||session.user?.username||'';
  updatePlayerAdminAccess();
  if(!appStarted){appStarted=true;showView(initialView);refreshStatus().then(()=>{pollLog();pollChat();refreshItemStatus();refreshNoticeStatus(true)});statusTimer=setInterval(refreshStatus,5000);logTimer=setInterval(()=>{pollLog();pollChat();if(activeView==='chat')refreshNoticeStatus()},1500);systemTimer=setInterval(pollSystem,5000)}
  else refreshStatus();
  lucide.createIcons();
}
async function initializeAuth(){
  try{const session=await api('/api/auth/session');if(session.authenticated)enterApp(session);else showAuth(session)}catch(error){showAuth();authError.textContent=error.message}
}
document.querySelector('#loginForm').onsubmit=async event=>{
  event.preventDefault();authError.textContent='';
  try{const result=await api('/api/auth/login',{method:'POST',body:JSON.stringify(formData(event.target))});enterApp({...result,authenticated:true})}catch(error){authError.textContent=error.message}
};
document.querySelector('#setupForm').onsubmit=async event=>{
  event.preventDefault();const data=formData(event.target);authError.textContent='';
  if(data.password!==data.confirmPassword){authError.textContent='两次输入的密码不一致。';return}
  try{const result=await api('/api/auth/setup',{method:'POST',body:JSON.stringify({username:data.username,displayName:data.displayName,password:data.password})});enterApp({...result,authenticated:true,local:true})}catch(error){authError.textContent=error.message}
};
document.querySelector('#logoutBtn').onclick=async()=>{try{await api('/api/auth/logout',{method:'POST'})}catch{}showAuth({setupRequired:false,local:authSession?.local})};

const userForm=document.querySelector('#userForm');
function fillUserForm(user=null){
  userForm.reset();userForm.elements.id.value=user?.id||'';userForm.elements.username.value=user?.username||'';userForm.elements.displayName.value=user?.displayName||'';userForm.elements.enabled.value=String(user?.enabled!==false);userForm.elements.canManagePlayerData.value=String(user?.canManagePlayerData===true);
  const protectedAdmin=user?.username?.toLowerCase()==='admin';userForm.elements.username.readOnly=protectedAdmin;userForm.elements.enabled.disabled=protectedAdmin;userForm.elements.canManagePlayerData.disabled=protectedAdmin;
  userForm.elements.password.required=!user;document.querySelector('#userFormTitle').textContent=user?`编辑 ${user.username}`:'添加用户';document.querySelector('#userModeBadge').textContent=protectedAdmin?'受保护':user?'编辑':'新用户';document.querySelector('#deleteUser').disabled=!user||protectedAdmin;
}
function renderUsers(){
  const list=document.querySelector('#userList');
  list.innerHTML=userDirectory.map(user=>`<button type="button" class="user-list-item ${userForm.elements.id.value===user.id?'selected':''}" data-user-id="${escapeHtml(user.id)}"><span class="server-icon test"><i data-lucide="user-round"></i></span><span><strong>${escapeHtml(user.displayName)}</strong><small>${escapeHtml(user.username)} · ${user.canManagePlayerData?'允许玩家档案管理':'基础控制'}</small></span><b class="badge ${user.enabled?'running':'stopped'}">${user.enabled?'启用':'禁用'}</b></button>`).join('')||'<p class="empty-state">暂无用户。</p>';
  list.querySelectorAll('[data-user-id]').forEach(button=>button.onclick=()=>{fillUserForm(userDirectory.find(user=>user.id===button.dataset.userId));renderUsers()});lucide.createIcons();
}
async function refreshUsers(){try{const result=await api('/api/users');userDirectory=result.users;const selected=userDirectory.find(user=>user.id===userForm.elements.id.value);if(selected)fillUserForm(selected);renderUsers()}catch(error){document.querySelector('#userList').innerHTML=`<p class="empty-state error-text">${escapeHtml(error.message)}</p>`}}
document.querySelector('#newUser').onclick=()=>{fillUserForm();renderUsers()};
userForm.onsubmit=async event=>{
  event.preventDefault();const data=formData(userForm),editing=Boolean(data.id),protectedAdmin=data.username?.toLowerCase()==='admin',payload={id:data.id,username:data.username,displayName:data.displayName,password:data.password,enabled:protectedAdmin||data.enabled==='true',canManagePlayerData:protectedAdmin||data.canManagePlayerData==='true'};
  try{const result=await api('/api/users',{method:editing?'PUT':'POST',body:JSON.stringify(payload)});toast(result.message);fillUserForm(result.user);await refreshUsers()}catch(error){toast(error.message,true)}
};
document.querySelector('#deleteUser').onclick=async()=>{
  const id=userForm.elements.id.value,user=userDirectory.find(item=>item.id===id);if(!user||!confirm(`确认删除 Web 用户“${user.username}”？`))return;
  try{const result=await api('/api/users',{method:'DELETE',body:JSON.stringify({id,confirm:'DELETE_USER'})});toast(result.message);fillUserForm();await refreshUsers()}catch(error){toast(error.message,true)}
};

const aiForm=document.querySelector('#aiConfigForm');
function renderAIConfig(config){
  aiConfig=config;
  for(const name of ['enabled','provider','authMode','apiUrl','model','reasoningEffort','disableResponseStorage','temperature','maxTokens','maxReplyCharacters','requestTimeoutSeconds','maximumAttempts','retryBaseDelaySeconds','globalRequestCooldownSeconds','memoryTurns','memoryMinutes','noticeDurationSeconds','stockNewsEnabled','stockNewsRealCooldownMinutes','stockNewsMaxTokens','stockNewsMaxCharacters','stockNewsMaximumAttempts']){
    if(aiForm.elements[name])aiForm.elements[name].value=String(config[name]??'');
  }
  aiForm.elements.apiKey.value='';
  aiForm.elements.apiKey.placeholder=config.apiKeyConfigured?'密钥已保存，留空表示不修改':'输入 API Key 或中转站令牌';
  const badge=document.querySelector('#aiKeyBadge');badge.textContent=config.apiKeyConfigured?'密钥已配置':'未配置密钥';badge.className=`badge ${config.apiKeyConfigured?'running':'neutral'}`;
  document.querySelector('#aiServerPicker').innerHTML=(config.allServers||[]).map(server=>`<label><input type="checkbox" name="serverIds" value="${escapeHtml(server.id)}" ${server.enabled?'checked':''}><span>${escapeHtml(server.name)} <small>${escapeHtml(server.id)}</small></span></label>`).join('')||'<span class="empty-state compact">面板中没有服务器配置。</span>';
  const buildServer=document.querySelector('#aiKnowledgeBuildServer'),previous=buildServer.value;
  buildServer.innerHTML=(config.allServers||[]).map(server=>`<option value="${escapeHtml(server.id)}">${escapeHtml(server.name)} · ${escapeHtml(server.id)}</option>`).join('')||'<option value="">没有服务器配置</option>';
  const preferred=(config.allServers||[]).some(server=>server.id===previous)?previous:(config.allServers||[]).some(server=>server.id===selectedId)?selectedId:(config.serverIds||[])[0]||(config.allServers||[])[0]?.id||'';
  buildServer.value=preferred;
  const buildModel=document.querySelector('#aiKnowledgeBuildModel');if(!buildModel.value)buildModel.value=config.model||'';
}
function renderAIStatus(status){
  const state=status.running?(status.processing?'正在处理':'运行中'):status.enabled?'配置不完整':'已关闭';
  document.querySelector('#aiRuntimeState').textContent=state;
  document.querySelector('#aiRuntimeDetail').textContent=`Bridge ${status.version||'--'} · ${status.requestProtocol||'协议未知'} · ${status.readOnly?'只读':'可执行'}`;
  document.querySelector('#aiProviderState').textContent=status.provider==='anthropic-messages'?'Anthropic Messages':status.provider==='openai-responses'?'OpenAI Responses':'OpenAI Chat';
  document.querySelector('#aiModelState').textContent=status.model||'尚未配置模型';
  const monitored=status.monitoredServers||[],listening=monitored.filter(server=>server.listening).length;
  document.querySelector('#aiServerCount').textContent=`${listening} / ${monitored.length}`;
  document.querySelector('#aiServerState').textContent=monitored.length?'已发现活动会话 / 监听配置数':'尚未选择服务器';
  document.querySelector('#aiPendingCount').textContent=String(status.pendingCount||0);
  const stockNews=status.stockNews||{};
  document.querySelector('#aiLastReply').textContent=`最近回复 ${formatDate(status.lastReplyAt)} | 股票新闻 ${stockNews.enabled?'开启':'关闭'}，待处理 ${Number(stockNews.pendingCount||0)}`;
  const knowledge=status.knowledgeBase||{};document.querySelector('#aiKnowledgeStatus').textContent=`服务器信息库：${Number(knowledge.fileCount||0)} 个可检索文件 · ${knowledge.directory||'服务器信息库'}`;
  document.querySelector('#aiMonitoredServers').innerHTML=`<div class="ai-server-list">${monitored.map(server=>`<div class="ai-server-row"><strong>${escapeHtml(server.name)}</strong><span class="${server.listening&&server.managedResponseQueue?'':'offline'}">${server.listening?(server.managedResponseQueue?'受管队列就绪':'正在监听，协议能力未确认'):server.sessionAvailable?'等待首次轮询':'没有活动会话'}</span><small>${escapeHtml(server.id)} · Mod ${escapeHtml(server.modVersion||'--')} · 游戏 ${escapeHtml(server.gameVersion||'--')} · slot ${server.slot??'--'} · 最近读取 ${formatDate(server.lastSeenAt)}</small></div>`).join('')||'<p class="empty-state compact">没有启用的监听服务器。</p>'}</div>`;
  const errorPanel=document.querySelector('#aiErrorPanel');errorPanel.hidden=!status.lastError;document.querySelector('#aiLastError').textContent=status.lastError||'';
}
function renderAIKnowledgeBuild(data={}){
  aiKnowledgeBuild=data;clearTimeout(aiKnowledgeTimer);
  const active=Boolean(data.active),status=data.status||'idle',total=Number(data.totalChunks||0),completed=Number(data.completedChunks||0),labels={idle:'未运行',scanning:'本机解析',generating:'模型生成',finalizing:'正在发布',completed:'已完成',failed:'失败',cancelled:'已取消'};
  const panel=document.querySelector('#aiKnowledgeBuilder'),badge=document.querySelector('#aiKnowledgeBuildBadge'),form=document.querySelector('#aiKnowledgeBuildForm');panel.dataset.state=status;
  badge.textContent=labels[status]||status;badge.className=`badge ${status==='completed'?'running':status==='failed'?'stopped':'neutral'}`;
  const effort=data.reasoningEffort&&data.reasoningEffort!=='auto'?` · ${String(data.reasoningEffort).toUpperCase()}`:'';
  const buildServerName=data.serverName||data.serverId||'',buildModel=data.model?` · ${data.model}`:'',buildProvider=data.provider?` · ${data.provider==='openai-chat'?'Chat':data.provider==='openai-responses'?'Responses':data.provider}`:'';
  document.querySelector('#aiKnowledgeBuildState').textContent=buildServerName?`${labels[status]||status} · ${buildServerName}${buildModel}${buildProvider}${effort}`:labels[status]||'尚未构建';
  document.querySelector('#aiKnowledgeBuildMessage').textContent=data.error||data.message||'自动知识库与外部手工资料会在玩家问答时共同检索。';
  const progress=status==='completed'?100:status==='scanning'?8:status==='finalizing'?97:total?Math.min(94,10+Math.round(completed/total*84)):0;
  document.querySelector('#aiKnowledgeBuildProgress').value=progress;
  document.querySelector('#aiKnowledgeBuildChunks').textContent=`${completed} / ${total}`;
  document.querySelector('#aiKnowledgeBuildFields').textContent=data.sandboxFields?Number(data.sandboxFields).toLocaleString('zh-CN'):'--';
  document.querySelector('#aiKnowledgeBuildMods').textContent=data.enabledMods?`${Number(data.enabledMods).toLocaleString('zh-CN')} / Workshop ${Number(data.workshopItems||0).toLocaleString('zh-CN')}`:'--';
  document.querySelector('#aiKnowledgeBuildTime').textContent=formatDate(data.completedAt);
  form.querySelector('button[type="submit"]').disabled=active||authSession?.user?.username!=='admin';
  document.querySelector('#cancelAIKnowledgeBuild').disabled=!active||authSession?.user?.username!=='admin';
  form.elements.serverId.disabled=active;form.elements.model.disabled=active;form.elements.reasoningEffort.disabled=active;
  if(active&&activeView==='ai')aiKnowledgeTimer=setTimeout(refreshAIKnowledgeBuild,1500);
}
async function refreshAIKnowledgeBuild(){try{renderAIKnowledgeBuild(await api('/api/ai/knowledge/build'))}catch(error){document.querySelector('#aiKnowledgeBuildMessage').textContent=error.message}}
function renderAIRequests(requests){
  const labels={queued:'排队',processing:'模型处理中',retrying:'等待重试','queue-written':'等待服务端校验',answered:'服务端已派发','terminal-failure':'处理终止','response-rejected':'服务端拒绝','moderation-warning':'审查警告','moderation-kicked':'自动踢出','moderation-action-failed':'处置失败'};
  const failed=new Set(['terminal-failure','response-rejected','moderation-action-failed']);
  document.querySelector('#aiRequestList').innerHTML=requests.length?requests.map(item=>{const status=item.status||'queued',detail=item.answer||item.error||labels[status]||status,channel=item.responseChannel?` · ${item.responseChannel}`:'',requestId=item.requestId?` · ${item.requestId.slice(-18)}`:'';return`<div class="ai-request-row" data-status="${escapeHtml(status)}"><time>${formatDate(item.updatedAt||item.completedAt||item.receivedAt)}</time><strong>${escapeHtml(item.serverName||item.serverId)} · ${escapeHtml(item.username)}${escapeHtml(requestId)}</strong><p class="ai-question" title="${escapeHtml(item.question||'')}">${escapeHtml(item.question||'')}</p><p class="ai-answer" title="${escapeHtml(detail)}">${escapeHtml(detail)}</p><b class="${failed.has(status)?'failed':status==='answered'?'answered':''}">${escapeHtml(labels[status]||status)}</b><small>${Number(item.attempts||0)} 次 · ${Number(item.durationMs||0).toLocaleString('zh-CN')} ms${escapeHtml(channel)}</small></div>`}).join(''):'<p class="empty-state compact">尚无 AI 请求。玩家明确唤醒 AI 后才会进入这里，普通 T 聊天不会上传。</p>';
}
function renderAIModeration(payload){
  const summary=payload.summary||{};aiModerationEvents=payload.events||[];
  document.querySelector('#aiModerationTotal').textContent=Number(summary.total||0).toLocaleString('zh-CN');
  document.querySelector('#aiModerationWarned').textContent=Number(summary.warned||0).toLocaleString('zh-CN');
  document.querySelector('#aiModerationKicked').textContent=Number(summary.kicked||0).toLocaleString('zh-CN');
  document.querySelector('#aiModerationFailed').textContent=Number(summary.actionFailed||0).toLocaleString('zh-CN');
  const decisionLabels={warned:'已警告',kick:'自动处置'},actionLabels={'warning-recorded':'警告已记录','kick-queued':'踢出已提交','kick-failed':'踢出提交失败','identity-unverified':'身份未验证','player-offline':'玩家已离线','exempt-no-action':'管理员豁免'};
  const reviewLabels={pending:'待复核',reviewed:'已复核','false-positive':'误判'};
  const list=document.querySelector('#aiModerationList');
  list.innerHTML=aiModerationEvents.length?aiModerationEvents.map(item=>{
    const warnings=(item.warnings||[]).map(value=>`<li>${escapeHtml(value)}</li>`).join('');
    const conversation=(item.conversation||[]).map(message=>`<li><b>${message.role==='assistant'?'AI':'玩家'}</b><span>${escapeHtml(message.content||'')}</span></li>`).join('');
    const channels=(item.notificationChannels||[]).join('、')||'无';
    const countText=item.ruleId==='high-frequency'?`${Number(item.requestCount||0)} / ${Number(item.threshold||11)} 次`:`${Number(item.bypassCount||0)} / ${Number(item.threshold||3)} 次`;
    return`<details class="ai-moderation-event" data-decision="${escapeHtml(item.decision||'warned')}">
      <summary><time>${formatDate(item.createdAt)}</time><strong>${escapeHtml(item.username||'未知玩家')}</strong><span>${escapeHtml(item.serverName||item.serverId||'未知服务器')}</span><b>${escapeHtml(item.ruleLabel||item.ruleId||'审查规则')}</b><em>${escapeHtml(actionLabels[item.actionStatus]||decisionLabels[item.decision]||item.actionStatus||'已记录')}</em></summary>
      <div class="ai-moderation-detail">
        <dl><div><dt>SteamID</dt><dd><code>${escapeHtml(item.steamId||'未提供')}</code></dd></div><div><dt>命中计数</dt><dd>${escapeHtml(countText)}</dd></div><div><dt>复核状态</dt><dd>${escapeHtml(reviewLabels[item.reviewStatus]||item.reviewStatus||'待复核')}</dd></div><div><dt>通知通道</dt><dd>${escapeHtml(channels)}</dd></div><div><dt>踢出回执 ID</dt><dd><code>${escapeHtml(item.kickRequestId||'无')}</code></dd></div></dl>
        <div class="ai-moderation-evidence"><h3>原始问题</h3><p>${escapeHtml(item.question||'')}</p><h3>本地拒绝回复</h3><p>${escapeHtml(item.answer||'')}</p></div>
        ${conversation?`<div class="ai-moderation-conversation"><h3>相关会话</h3><ol>${conversation}</ol></div>`:''}
        ${warnings?`<div class="ai-moderation-warnings"><h3>处置告警</h3><ul>${warnings}</ul></div>`:''}
        <div class="ai-moderation-actions"><button class="secondary-button" type="button" data-ai-review="reviewed" data-event-id="${escapeHtml(item.id)}"><i data-lucide="check"></i>已复核</button><button class="secondary-button" type="button" data-ai-review="false-positive" data-event-id="${escapeHtml(item.id)}"><i data-lucide="flag"></i>标记误判</button></div>
      </div>
    </details>`}).join(''):'<p class="empty-state compact">尚无 AI 审查事件。</p>';
  list.querySelectorAll('[data-ai-review]').forEach(button=>button.onclick=()=>updateAIModerationReview(button.dataset.eventId,button.dataset.aiReview));
}
async function refreshAIModeration(){try{renderAIModeration(await api('/api/ai/moderation'));lucide.createIcons()}catch(error){document.querySelector('#aiModerationList').innerHTML=`<p class="empty-state error-text">${escapeHtml(error.message)}</p>`}}
async function updateAIModerationReview(id,status){
  const event=aiModerationEvents.find(item=>item.id===id);if(!event)return;
  if(status==='false-positive'&&!confirm(`确认将 ${event.username} 的这条 AI 审查记录标记为误判？此操作不会自动撤销已经执行的踢出。`))return;
  try{const result=await api('/api/ai/moderation',{method:'PUT',body:JSON.stringify({id,status,note:''})});renderAIModeration(result);lucide.createIcons();toast(result.message)}catch(error){toast(error.message,true)}
}
async function refreshAILog(){try{const result=await api('/api/ai/log?tail=200');document.querySelector('#aiBridgeLog').textContent=(result.lines||[]).join('\n')||'暂无 Bridge 日志。'}catch(error){document.querySelector('#aiBridgeLog').textContent=error.message}}
const aiPolicyForm=document.querySelector('#aiPolicyForm');
function fillAIPolicy(policy=null){
  aiPolicyForm.reset();aiPolicyForm.elements.id.value=policy?.id||'';aiPolicyForm.elements.serverId.innerHTML=(lastStatus?.servers||[]).map(server=>`<option value="${escapeHtml(server.id)}">${escapeHtml(server.name)} · ${escapeHtml(server.id)}</option>`).join('');aiPolicyForm.elements.serverId.value=policy?.serverId||selectedId;aiPolicyForm.elements.enabled.value=String(policy?.enabled??true);aiPolicyForm.elements.username.value=policy?.username||'';aiPolicyForm.elements.steamId.value=policy?.steamId||'';aiPolicyForm.elements.trustedAll.value=String(policy?.trustedAll??false);
  const allowed=new Set(policy?.allowedOperations||[]);document.querySelector('#aiOperationPicker').innerHTML=aiOperations.map(operation=>`<label data-risk="${escapeHtml(operation.risk)}"><input type="checkbox" name="allowedOperations" value="${escapeHtml(operation.id)}" ${allowed.has(operation.id)?'checked':''}><span>${escapeHtml(operation.label)}</span><small>${escapeHtml(operation.id)}</small></label>`).join('')||'<span class="empty-state compact">没有可用的操作目录。</span>';
  document.querySelector('#aiPolicyFormTitle').textContent=policy?'编辑玩家授权':'添加玩家授权';document.querySelector('#aiPolicyMode').textContent=policy?'编辑':'新授权';document.querySelector('#aiPolicyMode').className=`badge ${policy?.enabled?'running':'neutral'}`;document.querySelector('#deleteAIPolicy').disabled=!policy;updateAIPolicyTrust();refreshAIPolicyPlayers(aiPolicyForm.elements.serverId.value);
}
function updateAIPolicyTrust(){const trusted=aiPolicyForm.elements.trustedAll.value==='true';document.querySelectorAll('#aiOperationPicker input').forEach(input=>input.disabled=trusted);document.querySelector('#aiOperationPicker').classList.toggle('trusted',trusted)}
function renderAIPolicies(){
  const list=document.querySelector('#aiPolicyList');list.innerHTML=aiPolicies.length?aiPolicies.map(item=>`<button class="ai-policy-row${item.id===aiPolicyForm.elements.id.value?' selected':''}" type="button" data-ai-policy="${escapeHtml(item.id)}"><span><strong>${escapeHtml(item.username)}</strong><code>${escapeHtml(item.steamId)}</code><small>${escapeHtml(item.serverId)}</small></span><b class="badge ${item.enabled?'running':'neutral'}">${item.enabled?'启用':'停用'}</b><em>${item.trustedAll?'完全信任':`${(item.allowedOperations||[]).length} 项操作`}</em></button>`).join(''):'<p class="empty-state compact">尚未配置 AI 玩家授权。</p>';list.querySelectorAll('[data-ai-policy]').forEach(row=>row.onclick=()=>{fillAIPolicy(aiPolicies.find(item=>item.id===row.dataset.aiPolicy));renderAIPolicies()});
}
async function refreshAIPolicyPlayers(serverId){if(!serverId)return;try{const data=await api(`/api/players?serverId=${encodeURIComponent(serverId)}`);if(aiPolicyForm.elements.serverId.value!==serverId)return;aiPolicyPlayers=data.players||[];document.querySelector('#aiPolicyPlayerOptions').innerHTML=aiPolicyPlayers.map(player=>`<option value="${escapeHtml(player.username)}">${escapeHtml(player.steamId||'未记录 SteamID')}</option>`).join('')}catch{aiPolicyPlayers=[];document.querySelector('#aiPolicyPlayerOptions').innerHTML=''}}
function renderAIPoliciesPayload(payload){aiPolicies=payload.policies||[];aiOperations=payload.operations||[];document.querySelector('#aiExecutorWarning span').textContent=payload.message||'执行器尚未接入。';const selected=aiPolicies.find(item=>item.id===aiPolicyForm.elements.id.value);fillAIPolicy(selected||null);renderAIPolicies()}
async function refreshAIPolicies(){const payload=await api('/api/ai/policies');renderAIPoliciesPayload(payload)}
async function refreshAIPage(){
  if(aiBusy||!authSession)return;aiBusy=true;
  try{
    const [config,status,records,policies,moderation,bridgeLog]=await Promise.all([api('/api/ai/config'),api('/api/ai/status'),api('/api/ai/requests'),api('/api/ai/policies'),api('/api/ai/moderation'),api('/api/ai/log?tail=200')]);
    renderAIConfig(config);renderAIStatus(status);renderAIKnowledgeBuild(status.knowledgeBuild||{});renderAIRequests(records.requests||[]);renderAIPoliciesPayload(policies);renderAIModeration(moderation);lucide.createIcons();
    document.querySelector('#aiBridgeLog').textContent=(bridgeLog.lines||[]).join('\n')||'暂无 Bridge 日志。';
  }catch(error){toast(error.message,true)}finally{aiBusy=false}
}
aiForm.elements.provider.onchange=()=>{aiForm.elements.apiUrl.placeholder=aiForm.elements.provider.value==='anthropic-messages'?'https://api.anthropic.com 或兼容中转地址':'https://api.openai.com/v1 或兼容中转地址'};
document.querySelector('#fetchAIModels').onclick=async event=>{
  const button=event.currentTarget,values=formData(aiForm),hint=document.querySelector('#aiModelHint');
  button.disabled=true;hint.textContent='正在从 Provider 拉取模型列表...';
  try{
    const result=await api('/api/ai/models',{method:'POST',body:JSON.stringify({provider:values.provider,apiUrl:values.apiUrl,authMode:values.authMode,apiKey:values.apiKey}),timeoutMs:70000});
    document.querySelector('#aiModelOptions').innerHTML=(result.models||[]).map(model=>`<option value="${escapeHtml(model.id)}">${escapeHtml(model.name&&model.name!==model.id?model.name:model.ownedBy||'')}</option>`).join('');
    hint.textContent=`已拉取 ${result.count||0} 个模型，点击输入框选择，也可以继续手动输入。`;
    toast(result.message);
  }catch(error){hint.textContent=`拉取失败：${error.message}。仍可手动填写模型 ID。`;toast(error.message,true)}finally{button.disabled=false}
};
aiForm.onsubmit=async event=>{
  event.preventDefault();const values=formData(aiForm),serverIds=[...aiForm.querySelectorAll('input[name="serverIds"]:checked')].map(input=>input.value);
  if(values.enabled==='true'&&!serverIds.length){toast('启用 AI 助手前至少选择一台监听服务器。',true);return}
  const payload={enabled:values.enabled==='true',provider:values.provider,apiUrl:values.apiUrl,authMode:values.authMode,model:values.model,apiKey:values.apiKey,serverIds,reasoningEffort:values.reasoningEffort,disableResponseStorage:values.disableResponseStorage==='true',temperature:Number(values.temperature),maxTokens:Number(values.maxTokens),maxReplyCharacters:Number(values.maxReplyCharacters),requestTimeoutSeconds:Number(values.requestTimeoutSeconds),maximumAttempts:Number(values.maximumAttempts),retryBaseDelaySeconds:Number(values.retryBaseDelaySeconds),globalRequestCooldownSeconds:Number(values.globalRequestCooldownSeconds),memoryTurns:Number(values.memoryTurns),memoryMinutes:Number(values.memoryMinutes),noticeDurationSeconds:Number(values.noticeDurationSeconds),stockNewsEnabled:values.stockNewsEnabled==='true',stockNewsRealCooldownMinutes:Number(values.stockNewsRealCooldownMinutes),stockNewsMaxTokens:Number(values.stockNewsMaxTokens),stockNewsMaxCharacters:Number(values.stockNewsMaxCharacters),stockNewsMaximumAttempts:Number(values.stockNewsMaximumAttempts)};
  try{const result=await api('/api/ai/config',{method:'PUT',body:JSON.stringify(payload)});toast(result.message);renderAIConfig(result);await refreshAIPage()}catch(error){toast(error.message,true)}
};
document.querySelector('#refreshAI').onclick=refreshAIPage;
document.querySelector('#openAIKnowledge').onclick=async event=>{
  const button=event.currentTarget;
  button.disabled=true;
  try{
    const result=await api('/api/ai/knowledge/open',{method:'POST'});
    toast(result.message||'已在面板主机打开服务器信息库。');
  }catch(error){toast(error.message,true)}
  finally{button.disabled=false}
};
document.querySelector('#aiKnowledgeBuildForm').onsubmit=async event=>{
  event.preventDefault();const form=event.currentTarget,values=formData(form),serverLabel=form.elements.serverId.selectedOptions[0]?.textContent||values.serverId,model=values.model.trim()||aiConfig?.model||'',reasoningEffort=values.reasoningEffort||'auto';
  if(!model){toast('请先填写知识库构建模型。',true);return}
  if(!confirm(`确认读取并脱敏“${serverLabel}”的服务器配置和 Mod 清单，并临时调用模型“${model}”构建知识库？推理强度：${reasoningEffort}。此操作可能产生多次 API 费用。`))return;
  form.querySelector('button[type="submit"]').disabled=true;
  try{const result=await api('/api/ai/knowledge/build',{method:'POST',body:JSON.stringify({serverId:values.serverId,model,reasoningEffort,confirm:'BUILD_AI_KNOWLEDGE'}),timeoutMs:180000});renderAIKnowledgeBuild(result);toast(result.message||'知识库构建已开始。')}catch(error){toast(error.message,true);await refreshAIKnowledgeBuild()}finally{if(!aiKnowledgeBuild?.active)form.querySelector('button[type="submit"]').disabled=false}
};
document.querySelector('#aiKnowledgeBuildModel').addEventListener('change',event=>{if(/^deepseek/i.test(event.target.value.trim()))document.querySelector('#aiKnowledgeBuildReasoning').value='auto'});
document.querySelector('#cancelAIKnowledgeBuild').onclick=async()=>{
  if(!aiKnowledgeBuild?.active||!confirm('确认取消当前知识库构建？已经上线的知识库不会被修改。'))return;
  try{const result=await api('/api/ai/knowledge/build',{method:'DELETE',body:JSON.stringify({confirm:'CANCEL_AI_KNOWLEDGE'}),timeoutMs:30000});renderAIKnowledgeBuild(result);toast(result.message)}catch(error){toast(error.message,true)}
};
document.querySelector('#refreshAILog').onclick=refreshAILog;
document.querySelector('#refreshAIModeration').onclick=refreshAIModeration;
async function controlAIRuntime(action){const buttons=['startAI','stopAI','restartAI'].map(id=>document.querySelector(`#${id}`));buttons.forEach(button=>button.disabled=true);try{const result=await api('/api/ai/runtime',{method:'POST',body:JSON.stringify({action})});toast(result.message);renderAIStatus(result);await refreshAIPage()}catch(error){toast(error.message,true)}finally{buttons.forEach(button=>button.disabled=false)}}
document.querySelector('#startAI').onclick=()=>controlAIRuntime('start');document.querySelector('#stopAI').onclick=()=>controlAIRuntime('stop');document.querySelector('#restartAI').onclick=()=>controlAIRuntime('restart');
document.querySelector('#testAI').onclick=async event=>{const button=event.currentTarget;button.disabled=true;try{const result=await api('/api/ai/test',{method:'POST',timeoutMs:190000});toast(result.message);document.querySelector('#aiRuntimeDetail').textContent=`测试回复：${result.response}`}catch(error){toast(error.message,true)}finally{button.disabled=false}};
document.querySelector('#clearAIHistory').onclick=async()=>{if(!confirm('确认清空所有玩家的 AI 对话记忆？请求记录不会删除。'))return;try{const result=await api('/api/ai/clear-history',{method:'POST'});toast(result.message)}catch(error){toast(error.message,true)}};
document.querySelector('#newAIPolicy').onclick=()=>{fillAIPolicy();renderAIPolicies();aiPolicyForm.elements.username.focus()};aiPolicyForm.elements.serverId.onchange=event=>refreshAIPolicyPlayers(event.target.value);aiPolicyForm.elements.trustedAll.onchange=updateAIPolicyTrust;aiPolicyForm.elements.username.onchange=()=>{const match=aiPolicyPlayers.find(player=>player.username.toLocaleLowerCase()===aiPolicyForm.elements.username.value.trim().toLocaleLowerCase());if(match?.steamId)aiPolicyForm.elements.steamId.value=match.steamId};
aiPolicyForm.onsubmit=async event=>{event.preventDefault();const values=formData(event.currentTarget),editing=Boolean(values.id),allowedOperations=[...event.currentTarget.querySelectorAll('input[name="allowedOperations"]:checked')].map(input=>input.value),payload={id:values.id,serverId:values.serverId,username:values.username,steamId:values.steamId,enabled:values.enabled==='true',trustedAll:values.trustedAll==='true',allowedOperations};if(!payload.trustedAll&&!allowedOperations.length){toast('请选择至少一项允许操作，或启用完全信任。',true);return}try{const result=await api('/api/ai/policies',{method:editing?'PUT':'POST',body:JSON.stringify(payload)});renderAIPoliciesPayload(result);const saved=aiPolicies.find(item=>item.serverId===payload.serverId&&item.username.toLocaleLowerCase()===payload.username.trim().toLocaleLowerCase()&&item.steamId===payload.steamId.trim());if(saved){fillAIPolicy(saved);renderAIPolicies()}toast(result.message)}catch(error){toast(error.message,true)}};
document.querySelector('#deleteAIPolicy').onclick=async()=>{const id=aiPolicyForm.elements.id.value,policy=aiPolicies.find(item=>item.id===id);if(!policy||!confirm(`确认删除 ${policy.username} 的 AI 操作授权？`))return;try{const result=await api('/api/ai/policies',{method:'DELETE',body:JSON.stringify({id,confirm:'DELETE_AI_POLICY'})});renderAIPoliciesPayload(result);toast(result.message)}catch(error){toast(error.message,true)}};

const mapResetForm=document.querySelector('#mapResetConfigForm'),mapResetAreaTable=document.querySelector('#mapResetAreaTable'),mapResetConfirmation=document.querySelector('#mapResetConfirmation');
function formatMapResetBytes(value){const bytes=Number(value)||0;if(!bytes)return'0 B';const units=['B','KiB','MiB','GiB','TiB'];const index=Math.min(units.length-1,Math.floor(Math.log(bytes)/Math.log(1024)));return`${(bytes/Math.pow(1024,index)).toFixed(index<2?0:2)} ${units[index]}`}
function renderMapResetAreas(areas=[],disabled=false){
  if(!areas.length){mapResetAreaTable.innerHTML='<p class="empty-state compact">没有手动保护区域。</p>';return}
  mapResetAreaTable.innerHTML='<div class="map-reset-area-columns"><span>名称</span><span>X</span><span>Y</span><span>宽</span><span>高</span><span>边距</span><span></span></div>'+areas.map((area,index)=>`<div class="map-reset-area-row" data-area-index="${index}"><input data-field="name" maxlength="64" value="${escapeHtml(area.name||'')}" aria-label="区域名称" placeholder="区域名称" ${disabled?'disabled':''}><input data-field="x" type="number" min="-1000000" max="1000000" step="1" value="${Number(area.x)||0}" aria-label="X 坐标" placeholder="X" ${disabled?'disabled':''}><input data-field="y" type="number" min="-1000000" max="1000000" step="1" value="${Number(area.y)||0}" aria-label="Y 坐标" placeholder="Y" ${disabled?'disabled':''}><input data-field="w" type="number" min="1" max="100000" step="1" value="${Number(area.w)||1}" aria-label="宽度" placeholder="宽" ${disabled?'disabled':''}><input data-field="h" type="number" min="1" max="100000" step="1" value="${Number(area.h)||1}" aria-label="高度" placeholder="高" ${disabled?'disabled':''}><input data-field="marginChunks" type="number" min="0" max="64" step="1" value="${Number(area.marginChunks)||0}" aria-label="边距区块" placeholder="边距" ${disabled?'disabled':''}><button class="icon-button" type="button" data-remove-map-area="${index}" title="删除保护区域" ${disabled?'disabled':''}><i data-lucide="trash-2"></i></button></div>`).join('');
  mapResetAreaTable.querySelectorAll('[data-remove-map-area]').forEach(button=>button.onclick=()=>button.closest('.map-reset-area-row').remove());lucide.createIcons();
}
function readMapResetAreas(){
  return[...mapResetAreaTable.querySelectorAll('.map-reset-area-row')].map((row,index)=>{const value=field=>row.querySelector(`[data-field="${field}"]`).value.trim(),integer=field=>Number(value(field));const area={name:value('name'),x:integer('x'),y:integer('y'),w:integer('w'),h:integer('h'),marginChunks:integer('marginChunks')};if(!area.name)throw new Error(`第 ${index+1} 个保护区域缺少名称。`);if(![area.x,area.y,area.w,area.h,area.marginChunks].every(Number.isInteger))throw new Error(`第 ${index+1} 个保护区域必须填写整数。`);return area})
}
function updateMapResetApplyState(){
  const data=mapResetSnapshot,button=document.querySelector('#applyMapReset');if(!data){button.disabled=true;return}
  const operationBusy=['running','finalizing'].includes(data.status?.state),confirmationOk=mapResetConfirmation.value===data.serverName;
  button.disabled=mapResetBusy||!data.authorized||data.serverAlive||data.lifecycleBusy||operationBusy||!data.auditMatchesConfig||!confirmationOk;
  button.title=!data.authorized?'仅 Web admin 可执行':data.serverAlive?'必须先保存并停止游戏服务器':data.lifecycleBusy?'服务器生命周期操作仍在执行':operationBusy?'已有地图刷新任务正在执行':!data.auditMatchesConfig?'当前配置需要先完成一次只读审计':!confirmationOk?`请输入 ${data.serverName}`:'已满足执行条件';
}
function renderMapReset(data,hydrateConfig=false){
  mapResetSnapshot=data;const status=data.status||{},operationBusy=['running','finalizing'].includes(status.state),summary=(status.state==='completed'?status.summary:null)||data.lastAuditSummary||null;
  if(hydrateConfig||mapResetServerId!==data.serverId){mapResetServerId=data.serverId;mapResetForm.elements.safehouseMarginChunks.value=data.config.safehouseMarginChunks;mapResetForm.elements.playerMarginChunks.value=data.config.playerMarginChunks;renderMapResetAreas(data.config.manualAreas||[],!data.authorized||operationBusy);mapResetConfirmation.value='';mapResetConfirmation.placeholder=data.serverName}
  const badge=document.querySelector('#mapResetStateBadge'),alert=document.querySelector('#mapResetAlert'),alertTitle=document.querySelector('#mapResetAlertTitle'),alertText=document.querySelector('#mapResetAlertText'),error=document.querySelector('#mapResetError');
  error.hidden=status.state!=='failed';error.textContent=status.error||'';
  if(operationBusy){badge.textContent=status.mode==='apply'?'正在执行':'正在审计';badge.className='badge running';alert.dataset.state='running';alertTitle.textContent=status.mode==='apply'?'正在隔离未保护区块':'正在扫描存档区块';alertText.textContent='后台任务运行中，页面可以正常切换；请勿关闭控制台进程。'}
  else if(status.state==='failed'){badge.textContent='执行失败';badge.className='badge stopped';alert.dataset.state='error';alertTitle.textContent='地图刷新任务失败';alertText.textContent='存档不会自动重启，请检查下方错误详情和报告目录。'}
  else if(status.state==='completed'){badge.textContent=status.mode==='apply'?'刷新完成':'审计完成';badge.className='badge running';alert.dataset.state='neutral';alertTitle.textContent=status.mode==='apply'?'区块已移入隔离目录':'只读审计已完成';alertText.textContent=status.mode==='apply'?'服务器保持停止状态；确认结果后再手动启动。':'审计没有修改存档。当前配置未变化时可在停服后正式执行。'}
  else{badge.textContent=data.auditMatchesConfig?'审计有效':'尚未审计';badge.className=`badge ${data.auditMatchesConfig?'running':'neutral'}`;alert.dataset.state=data.authorized?'neutral':'running';alertTitle.textContent=data.authorized?'只读工具已就绪':'当前账号只有查看权限';alertText.textContent=data.authorized?'审计不会修改存档。正式执行只会移动未保护区块到隔离目录。':'只有 Web 保留管理员 admin 可以保存配置、运行审计或正式执行。'}
  document.querySelector('#mapResetSafehouses').textContent=summary?Number(summary.safehouseCount).toLocaleString('zh-CN'):'--';
  document.querySelector('#mapResetPlayers').textContent=summary?Number(summary.livingPlayerProtectionCount).toLocaleString('zh-CN'):'--';
  document.querySelector('#mapResetProtected').textContent=summary?Number(summary.protectedChunkCount).toLocaleString('zh-CN'):'--';
  document.querySelector('#mapResetChunks').textContent=summary?Number(summary.resetMapChunkCount).toLocaleString('zh-CN'):'--';
  document.querySelector('#mapResetBytes').textContent=summary?formatMapResetBytes(summary.resetMapBytes):'--';
  document.querySelector('#mapResetVehicles').textContent=summary?`${Number(summary.vehicleCountPreservedInDatabase).toLocaleString('zh-CN')} · ${Number(summary.vehicleChunksAmongResetChunks).toLocaleString('zh-CN')}区块`:'--';
  document.querySelector('#mapResetSaveRoot').textContent=data.saveRoot||'--';document.querySelector('#mapResetReportPath').textContent=status.reportPath||data.lastAudit?.reportPath||'--';document.querySelector('#mapResetQuarantinePath').textContent=summary?.quarantinePath||'尚未执行';
  mapResetForm.querySelectorAll('input').forEach(input=>input.disabled=!data.authorized||operationBusy);mapResetAreaTable.querySelectorAll('button').forEach(button=>button.disabled=!data.authorized||operationBusy);document.querySelectorAll('.map-reset-admin').forEach(control=>control.disabled=!data.authorized||operationBusy||mapResetBusy);mapResetConfirmation.disabled=!data.authorized||operationBusy;
  updateMapResetApplyState();lucide.createIcons();clearTimeout(mapResetPollTimer);if(operationBusy&&activeView==='map-reset')mapResetPollTimer=setTimeout(()=>refreshMapReset(false),1500);
}
async function refreshMapReset(force=false){
  if(!selectedId||mapResetBusy&&!force)return;const serverId=selectedId,serial=++mapResetSerial;
  try{const data=await api(`/api/map-reset/status?serverId=${encodeURIComponent(serverId)}`,{timeoutMs:30000});if(serial!==mapResetSerial||serverId!==selectedId)return;renderMapReset(data,force||mapResetServerId!==serverId)}catch(error){if(activeView==='map-reset'){document.querySelector('#mapResetStateBadge').textContent='读取失败';document.querySelector('#mapResetAlert').dataset.state='error';document.querySelector('#mapResetAlertTitle').textContent='无法读取地图刷新状态';document.querySelector('#mapResetAlertText').textContent=error.message}}
}
async function saveMapResetConfig(showMessage=true){
  if(!selectedId)return null;const safehouseMarginChunks=Number(mapResetForm.elements.safehouseMarginChunks.value),playerMarginChunks=Number(mapResetForm.elements.playerMarginChunks.value);if(!Number.isInteger(safehouseMarginChunks)||!Number.isInteger(playerMarginChunks))throw new Error('自动保护边距必须填写整数。');const manualAreas=readMapResetAreas();const result=await api('/api/map-reset/config',{method:'PUT',body:JSON.stringify({serverId:selectedId,safehouseMarginChunks,playerMarginChunks,manualAreas}),timeoutMs:30000});renderMapReset(result,true);if(showMessage)toast(result.message);return result
}
mapResetForm.onsubmit=async event=>{event.preventDefault();if(mapResetBusy)return;mapResetBusy=true;try{await saveMapResetConfig(true)}catch(error){toast(error.message,true)}finally{mapResetBusy=false;if(mapResetSnapshot)renderMapReset(mapResetSnapshot,false)}};
document.querySelector('#addMapResetArea').onclick=()=>{const areas=readMapResetAreas();areas.push({name:`保护区域 ${areas.length+1}`,x:0,y:0,w:8,h:8,marginChunks:1});renderMapResetAreas(areas,false);mapResetAreaTable.querySelector('.map-reset-area-row:last-child input')?.focus()};
document.querySelector('#runMapResetAudit').onclick=async()=>{if(mapResetBusy)return;mapResetBusy=true;try{await saveMapResetConfig(false);const result=await api('/api/map-reset/audit',{method:'POST',body:JSON.stringify({serverId:selectedId}),timeoutMs:30000});renderMapReset(result,false);toast(result.message)}catch(error){toast(error.message,true)}finally{mapResetBusy=false;if(mapResetSnapshot)renderMapReset(mapResetSnapshot,false)}};
mapResetConfirmation.oninput=updateMapResetApplyState;
document.querySelector('#applyMapReset').onclick=async()=>{const data=mapResetSnapshot;if(!data||mapResetBusy||mapResetConfirmation.value!==data.serverName)return;if(!confirm(`最终确认：对 ${data.serverName} 执行选择性区块刷新？未保护区块会移动到隔离目录，服务器不会自动启动。`))return;mapResetBusy=true;try{const result=await api('/api/map-reset/apply',{method:'POST',body:JSON.stringify({serverId:selectedId,confirmation:mapResetConfirmation.value}),timeoutMs:30000});renderMapReset(result,false);toast(result.message)}catch(error){toast(error.message,true)}finally{mapResetBusy=false;if(mapResetSnapshot)renderMapReset(mapResetSnapshot,false)}};

const catalog=[
  ['additem','发放物品','available'],['addkey','发放钥匙','available'],['addsteamid','SteamID 允许列表','available'],['addtosafehouse','加入安全屋','available'],['adduser','新增白名单账号','available'],['addvehicle','生成车辆','available'],['addxp','发放经验','available'],['alarm','当前位置警报','client'],['banid','封禁 SteamID','available'],['banip','封禁 IP','available'],['banuser','封禁用户','available'],['changeoption','修改服务器选项','available'],['checkModsNeedUpdate','检查 Mod 更新','available'],['chopper','直升机事件','available'],['createhorde','生成尸群','available'],['createhorde2','帮助文本不完整','limited'],['godmod','自身无敌','client'],['godmodplayer','玩家无敌','available'],['gunshot','远处枪声','available'],['help','命令帮助','available'],['invisible','自身隐身','client'],['invisibleplayer','玩家隐身','available'],['kick','踢出用户','available'],['kickfromsafehouse','移出安全屋','available'],['lightning','玩家处闪电','available'],['list','连接列表','available'],['log','日志级别','available'],['noclip','玩家穿墙','available'],['players','在线玩家','available'],['quit','保存并退出','available'],['releasesafehouse','释放安全屋','available'],['reloadalllua','重载 Lua','available'],['reloadlua','重载 Lua 文件','available'],['reloadoptions','重载选项','available'],['remove','帮助文本不完整','limited'],['removeitem','移除自身物品','client'],['removemapsymbolsforuser','移除共享地图标记','available'],['removesteamid','移出 SteamID','available'],['removeuserfromwhitelist','移出白名单','available'],['removezombies','帮助文本不完整','limited'],['save','保存世界','available'],['servermsg','全服广播','available'],['setTimeSpeed','设置时间速度','available'],['setaccesslevel','访问级别','available'],['setpassword','修改账号密码','available'],['showoptions','显示服务器选项','available'],['startrain','开始降雨','available'],['startstorm','开始风暴','available'],['stats','服务器统计','available'],['stoprain','停止降雨','available'],['stopweather','停止天气','available'],['teleport','传送玩家','available'],['teleportplayer','玩家间传送','available'],['teleportto','自身传送坐标','client'],['thunder','玩家处雷声','available'],['unbanid','解封 SteamID','available'],['unbanip','解封 IP','available'],['unbanuser','解封用户','available'],['voiceban','禁用玩家语音','available'],['worldgen','世界生成控制','available']
];
const catalogDirect={players:'players',list:'connections',stats:'stats',save:'save',showoptions:'showoptions',reloadoptions:'reloadoptions',checkModsNeedUpdate:'check-mod-updates',stoprain:'stoprain',stopweather:{action:'event',event:'stopweather'},chopper:{action:'event',event:'chopper'},gunshot:{action:'event',event:'gunshot'},help:'help'};
const catalogForms={additem:['players','grantForm'],addkey:['commands','keyForm'],addsteamid:['commands','steamForm'],removesteamid:['commands','steamForm'],banid:['commands','steamForm'],unbanid:['commands','steamForm'],addtosafehouse:['commands','safehouseForm'],kickfromsafehouse:['commands','safehouseForm'],releasesafehouse:['commands','safehouseForm'],adduser:['commands','accountForm'],setpassword:['commands','accountForm'],removeuserfromwhitelist:['commands','accountForm'],addvehicle:['commands','vehicleForm'],addxp:['commands','xpForm'],banip:['commands','ipForm'],unbanip:['commands','ipForm'],banuser:['players','moderationForm'],kick:['players','moderationForm'],changeoption:['commands','optionForm'],createhorde:['world','hordeForm'],godmodplayer:['players','stateForm'],invisibleplayer:['players','stateForm'],noclip:['players','stateForm'],voiceban:['players','stateForm'],lightning:['world','localWeatherForm'],thunder:['world','localWeatherForm'],log:['commands','logLevelForm'],reloadalllua:['commands','luaForm'],reloadlua:['commands','luaForm'],removemapsymbolsforuser:['commands','userRepairForm'],servermsg:['console','broadcastForm'],setTimeSpeed:['commands','timeForm'],setaccesslevel:['players','accessForm'],startrain:['world','rainForm'],startstorm:['world','stormForm'],teleport:['players','teleportForm'],teleportplayer:['players','teleportForm'],unbanuser:['commands','userRepairForm'],worldgen:['commands','worldgenForm'],quit:['maintenance','restartServer']};
function openCatalogTarget(name){const target=catalogForms[name];if(!target)return;showView(target[0]);setTimeout(()=>{const element=document.querySelector(`#${target[1]}`);element?.scrollIntoView({behavior:'smooth',block:'center'});element?.classList.add('focus-flash');setTimeout(()=>element?.classList.remove('focus-flash'),1200);element?.querySelector('input,select,button')?.focus()},80)}
function renderCatalog(query=''){
  const needle=query.trim().toLowerCase(),items=catalog.filter(item=>!needle||item.slice(0,2).join(' ').toLowerCase().includes(needle));
  document.querySelector('#commandCatalog').innerHTML=items.map(([name,description,state])=>{const direct=catalogDirect[name],target=catalogForms[name],action=direct?`<button class="catalog-action" type="button" data-catalog-run="${escapeHtml(name)}"><i data-lucide="play"></i><span>执行</span></button>`:target?`<button class="catalog-action" type="button" data-catalog-open="${escapeHtml(name)}"><i data-lucide="arrow-up-right"></i><span>打开</span></button>`:`<button class="catalog-action" type="button" data-always-disabled="true" disabled title="该命令不能从 Web 安全执行"><i data-lucide="minus"></i><span>不可用</span></button>`;return`<div class="command-item"><code>${escapeHtml(name)}</code><span>${escapeHtml(description)}</span><b class="capability ${state}">${state==='available'?'服务端':state==='client'?'游戏内':'受限'}</b>${action}</div>`}).join('')||'<p class="empty-state">没有匹配的命令。</p>';lucide.createIcons();renderCurrentServer();
}
document.querySelector('#commandCatalog').addEventListener('click',event=>{const run=event.target.closest('[data-catalog-run]'),open=event.target.closest('[data-catalog-open]');if(run){const value=catalogDirect[run.dataset.catalogRun];command(typeof value==='string'?{action:value}:value)}else if(open)openCatalogTarget(open.dataset.catalogOpen)});
document.querySelector('#commandSearch').oninput=event=>renderCatalog(event.target.value);renderCatalog();

const helpTopics={
  time:{title:'服务器时间倍率',topic:'setTimeSpeed',body:'设置服务器时间推进倍率。当前服务器帮助格式为 /setTimeSpeed period，例如 /setTimeSpeed 10。数值越大，游戏时间推进越快；会影响昼夜和依赖游戏时间的系统，调整前应先确认在线玩家。'},
  lua:{title:'Lua 热重载',topic:'reloadlua',body:'在服务器运行中重新加载指定 Lua 脚本，格式为 /reloadlua "filename"。reloadalllua 在当前 B42.20 的内置帮助中也显示相同参数格式。脚本有语法错误或依赖顺序不正确时可能影响当前会话，只建议用于明确知道路径和依赖的维护操作。'},
  worldgen:{title:'完整世界生成器',topic:'worldgen',body:'status 查询状态。start 启动生成，stop 请求停止生成。当前 B42.20 服务器的 recheck 不是普通扫描：它会立即全量检查并生成全部缺失地图块，可能使用全部逻辑处理器并阻塞主线程，导致玩家无法连接、广播和 stop 命令无法及时执行。只能在所有玩家离线且已做好维护准备时使用。地图黑边通常还与客户端网络、服务器负载或 Mod 地图有关，worldgen 不能保证解决网络导致的黑边。'},
  key:{title:'发放钥匙',topic:'addkey',body:'向玩家发放指定钥匙，服务器格式为 /addkey "username" "keyId" "name"。原生命令允许省略用户名或名称，但 Web 表单要求明确玩家和名称，避免远程执行时把钥匙发给不确定目标。keyId 必须是数字，并需要与目标门锁使用的钥匙 ID 对应。'}
};
const helpDialog=document.querySelector('#helpDialog');let currentHelp=null;
function openHelp(key){const help=helpTopics[key];if(!help)return;currentHelp=help;document.querySelector('#helpTitle').textContent=help.title;document.querySelector('#helpBody').innerHTML=`<p>${escapeHtml(help.body)}</p><code>help ${escapeHtml(help.topic)}</code>`;helpDialog.showModal();lucide.createIcons()}
document.querySelectorAll('[data-help]').forEach(button=>button.onclick=()=>openHelp(button.dataset.help));document.querySelector('#closeHelp').onclick=()=>helpDialog.close();helpDialog.addEventListener('click',event=>{if(event.target===helpDialog)helpDialog.close()});document.querySelector('#queryHelp').onclick=()=>{if(currentHelp){command({action:'help-topic',topic:currentHelp.topic});helpDialog.close();showView('console')}};

const mobileUrl=`${window.location.protocol}//${window.location.host}/`;
document.querySelector('#mobileUrl').textContent=mobileUrl;
if(window.QRCode)new QRCode(document.querySelector('#qrcode'),{text:mobileUrl,width:128,height:128,colorDark:'#0d1013',colorLight:'#ffffff',correctLevel:QRCode.CorrectLevel.M});
lucide.createIcons();initializeAuth();
