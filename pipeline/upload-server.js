// tiny upload sink for the VM self-test: POST /u?name=file -> uploads/<file>
const http = require('http');
const fs = require('fs');
const path = require('path');

const OUT = '/home/marocos/win11-vm/uploads';
fs.mkdirSync(OUT, { recursive: true });

http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  if (req.method !== 'POST' || url.pathname !== '/u') {
    res.writeHead(404).end('nope');
    return;
  }
  const name = path.basename(url.searchParams.get('name') || `upload-${Date.now()}`);
  const chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    fs.writeFileSync(path.join(OUT, name), body);
    console.log(`${new Date().toISOString()}  ${name}  ${body.length} bytes`);
    res.writeHead(200, { 'Content-Type': 'text/plain' }).end('ok');
  });
}).listen(8001, '0.0.0.0', () => console.log('upload sink on :8001 -> ' + OUT));
