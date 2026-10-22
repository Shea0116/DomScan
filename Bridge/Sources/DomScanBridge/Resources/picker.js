(() => {
  'use strict';
  if (globalThis.__desktopSelector) return;
  const OWNER = 'data-desktop-selector-overlay';
  const nodes = new Map();
  const ids = new WeakMap();
  const listeners = [];
  let active = false, hovered = null, selected = [], raf = 0, leaseUntil = 0;
  let root, label, hoverBox, selectedLayer;
  const emit = data => {
    try { globalThis.__desktopSelectorEmit(JSON.stringify(data)); } catch (_) {}
  };
  const owned = node => !!(node?.nodeType === 1 && node.closest?.(`[${OWNER}]`));
  const uuid = () => globalThis.crypto?.randomUUID?.() || `${Date.now()}-${Math.random()}`;
  function tokenFor(el) {
    if (!ids.has(el)) { const id = uuid(); ids.set(el, id); nodes.set(id, el); }
    return ids.get(el);
  }
  function ensureOverlay() {
    if (root?.isConnected) return;
    root = document.createElement('div');
    root.setAttribute(OWNER, '');
    root.setAttribute('aria-hidden', 'true');
    root.style.cssText = 'all:initial!important;position:fixed!important;inset:0!important;z-index:2147483647!important;pointer-events:none!important;contain:strict!important;';
    const shadow = root.attachShadow({mode:'open'});
    hoverBox = document.createElement('div');
    hoverBox.style.cssText = 'position:absolute;box-sizing:border-box;border:2px solid #8b5cf6;background:rgba(139,92,246,.12);pointer-events:none;display:none;border-radius:3px;';
    label = document.createElement('div');
    label.style.cssText = 'position:absolute;display:none;padding:5px 9px;border-radius:6px;background:#211632;color:white;font:11px -apple-system,BlinkMacSystemFont,sans-serif;max-width:320px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;pointer-events:none;';
    selectedLayer = document.createElement('div');
    shadow.append(selectedLayer, hoverBox, label);
    (document.documentElement || document).append(root);
  }
  function place(box, rect) {
    Object.assign(box.style, {left:rect.x+'px',top:rect.y+'px',width:rect.width+'px',height:rect.height+'px'});
  }
  function tick() {
    raf = 0;
    if (!active && !selected.length) { root?.remove(); root = null; return; }
    ensureOverlay();
    if (active && hovered?.isConnected) {
      const r = hovered.getBoundingClientRect();
      place(hoverBox,r); hoverBox.style.display = 'block';
      label.textContent = `${hovered.localName} · ${Math.round(r.width)} × ${Math.round(r.height)}  ⇧ 多选 · Esc 退出`;
      Object.assign(label.style,{display:'block',left:Math.max(0,Math.min(r.x,innerWidth-250))+'px',top:Math.max(0,r.y>30?r.y-28:r.bottom+4)+'px'});
    } else { hoverBox.style.display='none'; label.style.display='none'; }
    selectedLayer.replaceChildren();
    const live=[];
    for (const id of selected) {
      const el=nodes.get(id);
      if (!el?.isConnected) {emit({kind:'stale',token:id});continue;}
      live.push(id);
      const box=document.createElement('div');
      box.style.cssText='position:absolute;box-sizing:border-box;border:2px solid #14b8a6;background:rgba(20,184,166,.06);pointer-events:none;border-radius:3px;';
      place(box,el.getBoundingClientRect()); selectedLayer.append(box);
    }
    selected=live;
    if (!active && !selected.length) {root.remove();root=null;}
  }
  function update() { if (!raf) raf=requestAnimationFrame(tick); }
  function targetOf(e) {
    return (e.composedPath?.() || [e.target]).find(n => n?.nodeType===1 && !owned(n));
  }
  function onMove(e) { const el=targetOf(e); if (!el || /^(iframe|frame)$/i.test(el.localName)) { hovered=null; } else hovered=el; update(); }
  function onLeave() { hovered=null; update(); }
  function onClick(e) {
    const el=targetOf(e);
    if (!el || /^(iframe|frame)$/i.test(el.localName)) return;
    e.preventDefault(); e.stopImmediatePropagation();
    emit({kind:'selection',additive:e.shiftKey,frameURL:location.href,frameTitle:document.title,item:snapshot(el)});
  }
  function blockPointer(e) {
    const el=targetOf(e);
    if (!el || /^(iframe|frame)$/i.test(el.localName)) return;
    e.preventDefault(); e.stopImmediatePropagation();
  }
  function onKey(e) {
    if (e.key==='Escape') { e.preventDefault(); e.stopImmediatePropagation(); setActive(false); emit({kind:'stop'}); }
  }
  function listen(target,type,fn,options) { target.addEventListener(type,fn,options); listeners.push(()=>target.removeEventListener(type,fn,options)); }
  function setActive(value) {
    active=!!value;
    leaseUntil=Date.now()+6500;
    for (const remove of listeners.splice(0)) remove();
    if(active) {
      listen(window,'mousemove',onMove,true);
      listen(window,'mouseleave',onLeave,true);
      listen(window,'click',onClick,true);
      for(const type of ['pointerdown','pointerup','mousedown','mouseup','dblclick','contextmenu'])listen(window,type,blockPointer,true);
      listen(window,'keydown',onKey,true);
    } else { hovered=null; }
    update();
  }
  function selectorWithin(el,scope) {
    const esc=CSS.escape;
    for(const attr of ['data-testid','data-test','data-qa','id']) {
      const value=el.getAttribute(attr);
      if(value) { const q=`[${attr}="${esc(value)}"]`; try {if(scope.querySelectorAll(q).length===1)return q;}catch(_){} }
    }
    const parts=[];
    for(let n=el;n?.nodeType===1;n=n.parentElement) {
      let s=esc(n.localName);
      if(n.id) {s='#'+esc(n.id); parts.unshift(s); break;}
      const same=n.parentElement?Array.from(n.parentElement.children).filter(c=>c.localName===n.localName):[];
      if(same.length>1)s+=`:nth-of-type(${same.indexOf(n)+1})`;
      parts.unshift(s);
      try {if(scope.querySelectorAll(parts.join(' > ')).length===1)break;}catch(_){}
    }
    return parts.join(' > ');
  }
  function locator(el) {
    const parts=[];
    let n=el;
    while(n) {
      const scope=n.getRootNode(); parts.unshift(selectorWithin(n,scope));
      n=scope instanceof ShadowRoot?scope.host:null;
    }
    return parts;
  }
  function cleanHTML(el) {
    const clone=el.cloneNode(true);
    clone.querySelectorAll?.(`script,noscript,[${OWNER}]`).forEach(n=>n.remove());
    for(const n of [clone,...(clone.querySelectorAll?.('*') || [])]) {
      if(!n.attributes)continue;
      for(const a of [...n.attributes]) if(/^on/i.test(a.name) || /^(srcdoc|nonce)$/i.test(a.name))n.removeAttribute(a.name);
      if(n.matches?.('input,textarea')) {n.removeAttribute('value'); if(n.localName==='textarea')n.textContent='';}
    }
    return (clone.outerHTML || '').slice(0,16000);
  }
  function snapshot(el) {
    const r=el.getBoundingClientRect(), cs=getComputedStyle(el), styles={};
    for(const k of ['display','position','width','height','color','background-color','font-family','font-size','font-weight','line-height','padding','margin','gap','border','border-radius','box-shadow','align-items','justify-content','grid-template-columns','flex-direction','transform'])styles[k]=cs.getPropertyValue(k);
    const shadowPath=locator(el);
    const password=el.matches('input[type="password"]');
    const text=password?'':(el.innerText || el.textContent || '').trim().slice(0,2400);
    const ancestry=[];
    for(let n=el.parentElement;n&&ancestry.length<5;n=n.parentElement)ancestry.push({tag:n.localName,role:n.getAttribute('role'),id:n.id || undefined});
    return {token:tokenFor(el),tag:el.localName,name:(el.getAttribute('aria-label') || el.getAttribute('alt') || text || el.localName).slice(0,120),role:el.getAttribute('role') || '',selector:shadowPath.join(' >>> '),shadowPath,text,html:cleanHTML(el),bounds:{x:r.x,y:r.y,width:r.width,height:r.height},styles,ancestry};
  }
  function navigate(id,direction) {
    const el=nodes.get(id);
    if(!el?.isConnected) {emit({kind:'stale',token:id});return;}
    const target=direction==='parent'?(el.parentElement || el.getRootNode()?.host):direction==='child'?el.firstElementChild:direction==='previous'?el.previousElementSibling:el.nextElementSibling;
    if(!target || owned(target))return;
    emit({kind:'selection',additive:false,frameURL:location.href,frameTitle:document.title,item:snapshot(target)});
  }
  function refresh(tokens) {
    for(const id of tokens) {
      const el=nodes.get(id);
      if(el?.isConnected)emit({kind:'refresh',frameURL:location.href,frameTitle:document.title,item:snapshot(el)});
      else emit({kind:'stale',token:id});
    }
  }
  const observer=new MutationObserver(records=>{
    if(records.some(r=>!owned(r.target) && !owned(r.target?.getRootNode?.()?.host)))update();
  });
  observer.observe(document,{subtree:true,childList:true,attributes:true});
  const onScroll=()=>update();
  window.addEventListener('scroll',onScroll,true);window.addEventListener('resize',onScroll);
  // Release page input even if the native process crashes or loses its socket.
  const watchdog=setInterval(()=>{if(active && Date.now()>leaseUntil){setActive(false);emit({kind:'stop'});}},1000);
  globalThis.__desktopSelector={setActive,renewLease(){leaseUntil=Date.now()+6500;update();},setSelected(tokens){selected=tokens.filter(t=>nodes.has(t));update();},navigate,refresh,
    destroy(){setActive(false);selected=[];observer.disconnect();clearInterval(watchdog);window.removeEventListener('scroll',onScroll,true);window.removeEventListener('resize',onScroll);if(raf)cancelAnimationFrame(raf);root?.remove();nodes.clear();delete globalThis.__desktopSelector;}};
  emit({kind:'ready',frameURL:location.href,frameTitle:document.title});
})();
