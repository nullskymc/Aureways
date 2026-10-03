function d(){const t=Date.now(),i={locale:"en",appearance:"system",selectedSessionId:location.hash.includes("landing")?null:"s1",selectedAgentId:"codex",workspacePath:"/Users/demo/Aureways",workspaceName:"Aureways",branch:"proto/web-shell",homePath:"/Users/demo",error:null,chrome:{trafficLights:{x:13,y:12,w:54,h:16},fullscreen:!1,titlebarHeight:46},workspaces:[{path:"/Users/demo/Aureways",name:"Aureways"},{path:"/Users/demo/site",name:"site"}],agents:[{id:"grok-build",title:"Grok Build",subtitle:"",available:!0},{id:"codex",title:"Codex",subtitle:"",available:!0},{id:"claude",title:"Claude Code",subtitle:"",available:!0},{id:"cursor",title:"Cursor",subtitle:"",available:!1}],sessions:[{id:"s1",title:"Rearchitect window as web shell",agentId:"codex",agentTitle:"Codex",cwd:"/Users/demo/Aureways",ws:"/Users/demo/Aureways",phase:"ready",streaming:!0,attention:!1,createdAt:t-36e5},{id:"s2",title:"Fix layout loop crash",agentId:"claude",agentTitle:"Claude Code",cwd:"/Users/demo/Aureways",ws:"/Users/demo/Aureways",phase:"idle",streaming:!1,attention:!0,createdAt:t-864e5},{id:"s3",title:"Landing page copy",agentId:"grok-build",agentTitle:"Grok Build",cwd:"/Users/demo/site",ws:"/Users/demo/site",phase:"idle",streaming:!1,attention:!1,createdAt:t-5*864e5}],composer:{sessionId:"s1",attachments:[],model:{configId:"model",current:"gpt-5",options:[{id:"gpt-5",name:"GPT-5",group:null,description:null}]},effort:{configId:"effort",current:"high",options:[{id:"high",name:"High",group:null,description:null}]}},usage:{used:42e3,size:2e5}};location.hash.includes("perm")&&(i.permission={title:"Run npm test",options:[{id:"a",name:"Allow once",kind:"allow_once",allow:!0},{id:"b",name:"Always allow",kind:"allow_always",allow:!0},{id:"c",name:"Reject",kind:"reject_once",allow:!1}],tool:{callId:"x",title:"npm test",fullTitle:"npm test",toolKind:"execute",status:"pending",layout:"command",progress:!1,command:"npm test -- --watch=false"}});const e=[];for(let s=0;s<Number(new URLSearchParams(location.search).get("turns")??3);s++)e.push({kind:"user",id:`u${s}`,text:"Make the main window a single WKWebView and keep SwiftUI as a thin shell.",attachments:[]}),e.push({kind:"thought",id:`t${s}`,text:"Need to look at RootView and the split view…",run:{s:t-5e4,e:t-46e3}}),e.push({kind:"tool",id:`x${s}`,callId:"c",title:"rg NavigationSplitView",fullTitle:"rg",toolKind:"execute",status:"completed",layout:"command",progress:!1,command:"rg -n NavigationSplitView Aureways",output:"Aureways/Views/RootView.swift:9:        NavigationSplitView {",run:{s:t-46e3,e:t-4e4}}),e.push({kind:"tool",id:`e${s}`,callId:"d",title:"Edited AurewaysApp.swift",fullTitle:"",toolKind:"edit",status:"completed",layout:"edit",progress:!1,diffs:[{path:"/Users/demo/Aureways/Aureways/AurewaysApp.swift",added:2,removed:1,truncated:!1,isNew:!1,hunks:[{header:"@@ -60,3 +60,4 @@",oldStart:60,newStart:60,lines:[' Window("Aureways") {',"-    RootView()","+    WebShellRoot(model: model)","+        .ignoresSafeArea()"," }"]}]}]}),e.push({kind:"agent",id:`a${s}`,text:`## Done

The window now hosts **one** \`WKWebView\`.

| Layer | Owner |
|---|---|
| Chrome | AppKit |
| UI | Preact |

\`\`\`swift
WebShellRoot(model: model)
    .ignoresSafeArea()
\`\`\`

- sidebar
- transcript (virtualized)
- composer
`});window.__aw.receive({type:"state",state:i}),window.__aw.receive({type:"transcript",sessionId:"s1",items:e});const o="live";window.__aw.receive({type:"patch",sessionId:"s1",ops:[{op:"upsert",index:e.length,item:{kind:"user",id:"ulive",text:"Now stream something long.",attachments:[]}},{op:"upsert",index:e.length+1,item:{kind:"agent",id:o,text:""}}]});const n=`Streaming a reply with \`code\`, **bold** and a list:

1. first
2. second

\`\`\`ts
const x = 1
\`\`\`

All good.`;let a=0;const l=()=>{a>=n.length||(window.__aw.receive({type:"patch",sessionId:"s1",ops:[{op:"append",id:o,delta:n.slice(a,a+5)}]}),a+=5,setTimeout(l,30))};l()}export{d as loadDemo};
