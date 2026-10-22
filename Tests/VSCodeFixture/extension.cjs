const vscode = require('vscode');
exports.activate = function (context) {
  const panel = vscode.window.createWebviewPanel('desktopSelectorFixture', 'Selector Desktop Fixture', vscode.ViewColumn.One, {enableScripts:true});
  panel.webview.html = `<!doctype html><meta charset="utf-8"><style>html,body{height:100%;margin:0;background:#101624}iframe{width:100%;height:100%;border:0}</style><iframe title="Selector Fixture" src="http://127.0.0.1:9471/"></iframe>`;
  context.subscriptions.push(panel);
};
