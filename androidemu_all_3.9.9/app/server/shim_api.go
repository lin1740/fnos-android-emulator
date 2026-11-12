package main

// API_PREFIX_JS：把面板前端写死的绝对路径请求（fetch "/api/..."、XHR、WebSocket、
//   3.9.4：原实现要求 location.pathname 以 /app/androidemu 开头才生效，经飞牛门户
//   根路径打开面板时该条件不成立 → fetch("/api/version") 打到门户根路径返回 HTML
//   → 前端解析失败后回落硬编码兜底版本（显示 v0.4.0，与容器真实版本不一致）。
//   现改为无条件生效：本脚本只注入到网关返回的页面，8443 直连不经过网关注入，安全。
// EventSource）改写到 /app/androidemu 前缀下。
//
// 背景（2026-10-31 实测）：穿云投屏面板的 JS 里用的是 fetch("/api/...")、绝对路径；
// 直连 8443 时同源，正常。经飞牛应用门户（/app/androidemu/）访问时，这些绝对路径
// 会打到飞牛 www 的根路径（不是本应用网关），拿不到任何数据 —— 用户看到的就是
// 「8443 能看到设备，从应用入口进去设备列表是空的」。
//
// 约束：
//   · 只在页面确实位于 /app/androidemu 下时生效，直连 8443 完全不受影响；
//   · 只改写「以 / 开头且尚未带前缀」的地址，重复注入或本身已带前缀不会二次拼接；
//   · 用拦截 fetch/XHR/WS 的方式，不改上游 JS 文件本体（避免误改字符串/正则）。
const API_PREFIX_JS = `(function(){try{
var P="/app/androidemu";
function fx(u){try{if(typeof u!=="string"||u.charAt(0)!=="/")return u;if(u===P||u.indexOf(P+"/")===0)return u;return P+u}catch(e){return u}}
try{if(window.fetch){var of=window.fetch;window.fetch=function(i,o){try{if(typeof i==="string"){i=fx(i)}else if(i&&i.url&&i.url.charAt(0)==="/"){i=new Request(fx(i.url),i)}}catch(e){}return of.call(this,i,o)}}}catch(e){}
try{var xo=XMLHttpRequest.prototype.open;XMLHttpRequest.prototype.open=function(){try{if(arguments.length>1)arguments[1]=fx(arguments[1])}catch(e){}return xo.apply(this,arguments)}}catch(e){}
try{var OW=window.WebSocket;function NW(u,p){try{if(typeof u==="string"){if(u.charAt(0)==="/"){u=(location.protocol==="https:"?"wss://":"ws://")+location.host+fx(u)}else if(/^wss?:\/\//i.test(u)){var U=new URL(u);if(U.host===location.host){U.pathname=fx(U.pathname);u=U.toString()}}}}catch(e){}return (p===undefined)?new OW(u):new OW(u,p)}
NW.prototype=OW.prototype;NW.CONNECTING=0;NW.OPEN=1;NW.CLOSING=2;NW.CLOSED=3;window.WebSocket=NW}catch(e){}
try{if(window.EventSource){var OE=window.EventSource;window.EventSource=function(u,c){return new OE(fx(u),c)};window.EventSource.prototype=OE.prototype}}catch(e){}
}catch(e){}})();
`

// DECODE_SOFT_JS：面板解码设置钉回上游默认值（renderEngine=video、previewDecoder=wasm），
// 并在 Firefox 上禁用 WebCodecs VideoDecoder（强制 WASM 软解）。
//
// 根因定位（2026-11-09 晚，真机实证，取代此前两轮误诊）：
//  1. 分辨率非 16 对齐（504x1088/1080x2340）会让编码器写 frame_cropping，硬解按
//     未裁剪尺寸取 stride 也会花屏 —— 该问题真实存在，已在 _parse_res /
//     switch_resolution.sh 强制向下对齐到 16 的倍数（默认 576x1280 实测 crop=0）。
//     但对齐后用户 Firefox 仍花屏，证明这只是共病之一，不是全部。
//  2. 同一台电脑、同一局域网、同一时刻：Chrome 全路径（<video>/WebCodecs）画面正常，
//     inbound 丢包=0、NACK=0；Firefox 的 WebSocket 投屏与 WebRTC 两档都花屏，
//     且叠加层 RX/DEC 计数正常推进（帧在收、解码器自称成功），about:webrtc 无
//     PeerConnection（WS 模式不走路由层）；本机 Firefox 播放标准 H.264 参考视频正常。
//     => 码流本身没问题、传输没问题，是 Firefox 的 WebCodecs VideoDecoder
//     （configure 硬编码 prefer-hardware）对该码流输出错乱帧（彩色条带/重影）。
//  3. WASM 软解对同一码流始终正常（左侧预览一直是 WASM）。
//
// 因此本注入做两件事（只对经网关访问的页面生效，8443 直连不注入）：
//   a) Firefox UA：删掉 window.VideoDecoder —— WebSocket 投屏路径 isWebCodecsActive
//      与 WebCodecsRenderer.isSupported() 随之为 false，一律回落 WASM 软解；
//      renderEngine=webcodecs 的 insertable streams 分支也被 isSupported() 关掉。
//      只限 Firefox：Chromium 系（Chrome/Edge）硬解实测正常，不受影响、不损失硬解。
//   b) 所有浏览器：清洗 localStorage（含按设备键）里的 webcodecs 值回上游默认，
//      防止手动切换留下的旧值反复把客户端推进已知有问题的路径。
const DECODE_SOFT_JS = `(function(){try{
var G="cloudphone_settings";
try{
  if(/Firefox\//i.test(navigator.userAgent)&&typeof window.VideoDecoder!=="undefined"){
    try{delete window.VideoDecoder}catch(e){}
    try{Object.defineProperty(window,"VideoDecoder",{configurable:true,get:function(){return undefined}})}catch(e){}
  }
}catch(e){}
function fixObj(o){try{
  if(!o||typeof o!=="object")return o;
  if(o.renderEngine==="webcodecs")o.renderEngine="video";
  if(o.previewDecoder==="webcodecs")o.previewDecoder="wasm";
}catch(e){}return o}
function isTarget(k){return typeof k==="string"&&(k===G||k.indexOf(G+"_")===0)}
try{
  var P=Storage.prototype,ps=P.setItem;
  P.setItem=function(k,v){try{
    if(isTarget(k)&&typeof v==="string"){
      var o=JSON.parse(v);
      if(o&&typeof o==="object"){
        var before=o.renderEngine+"|"+o.previewDecoder;
        fixObj(o);
        if((o.renderEngine+"|"+o.previewDecoder)!==before)v=JSON.stringify(o);
      }
    }
  }catch(e){}return ps.call(this,k,v)};
}catch(e){}
try{
  var keys=[],i;
  for(i=0;i<localStorage.length;i++){var k=localStorage.key(i);if(isTarget(k))keys.push(k)}
  for(i=0;i<keys.length;i++){
    try{
      var o=JSON.parse(localStorage.getItem(keys[i])||"{}");
      var b=o.renderEngine+"|"+o.previewDecoder;
      fixObj(o);
      if((o.renderEngine+"|"+o.previewDecoder)!==b)localStorage.setItem(keys[i],JSON.stringify(o));
    }catch(e){}
  }
}catch(e){}
}catch(e){}})();
`
