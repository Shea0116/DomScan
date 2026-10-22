const { app, BrowserWindow } = require('electron');
const path = require('node:path');

// Test-only profile and public local fixture; never use a user's app profile.
app.setPath('userData', process.env.SELECTOR_TEST_PROFILE || path.join(__dirname, '.electron-test-profile'));
app.commandLine.appendSwitch('remote-debugging-port', '9445');
app.commandLine.appendSwitch('site-per-process');
app.whenReady().then(() => {
  const window = new BrowserWindow({
    width: 1100, height: 900, title: 'Selector Desktop Fixture',
    webPreferences: { nodeIntegration: false, contextIsolation: true, sandbox: true },
  });
  window.loadURL('http://127.0.0.1:9471/');
});
app.on('window-all-closed', () => app.quit());
